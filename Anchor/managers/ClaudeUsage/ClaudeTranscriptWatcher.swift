/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import CoreServices
import Foundation

/// Watches `~/.claude/projects` for a usage-limit banner appended to any Claude
/// Code transcript.
///
/// The transcripts are the hot spot of this whole feature: every tool call in
/// every running Claude session appends to a `.jsonl`, so the FSEvents callback
/// fires constantly while anything is working. The common path therefore has to
/// cost almost nothing — a suffix test, a `stat`, and (only when the file grew)
/// a `memmem` over at most 64 KB of new bytes. JSON parsing happens for the
/// handful of lines that already matched a literal.
///
/// Nothing polls. FSEvents delivers on a dedicated background queue with a 10 s
/// latency so a burst of writes coalesces into one callback; a 10 s detection
/// delay is irrelevant when the reset it reports is hours away.
final class ClaudeTranscriptWatcher: @unchecked Sendable {
    struct Hit: Equatable {
        let limit: ClaudeLimitParser.Limit
        let sessionId: String
        /// Working directory the session was launched in, taken from the `cwd`
        /// field on the transcript line. Empty when the line did not carry one —
        /// the directory name is url-encoded lossily and must not be decoded back.
        let cwd: String
        let transcriptPath: String
        let observedAt: Date
    }

    /// Coalescing window. Long on purpose: bursts of tool-call writes collapse
    /// into a single callback and the reported reset is hours out.
    private static let latency: CFTimeInterval = 10.0

    /// Transcripts reach many megabytes. Only ever read the grown tail, and cap
    /// even that — a session resumed after a long gap can grow by a lot at once.
    private static let maxTailBytes: UInt64 = 64 * 1024

    /// Both capitalisations, because the banner appears mid-sentence
    /// ("Claude usage limit reached") and as a heading ("Session limit reached").
    /// `memmem` has no case-insensitive form and lowercasing 64 KB per event
    /// would cost more than the extra passes.
    private static let bannerLiterals = ["usage limit", "session limit", "Usage limit", "Session limit"]

    /// Enough context around the literal for the parser to find a clock time,
    /// a zone name or a trailing epoch, without handing it a 100 KB tool result.
    private static let windowBefore = 160
    private static let windowAfter = 400

    /// Drop stale entries once the map gets this big; sessions come and go.
    private static let sizeMapPruneThreshold = 400

    /// Prune is an `access()` per entry, so it must not run on every callback —
    /// once the map is over threshold it would otherwise be a 400-syscall sweep
    /// on each of them, and Claude Code never deletes transcripts so it would
    /// stay over threshold indefinitely.
    private static let prunePeriod = 200

    /// How far back a post-drop sweep looks, and how many files it will touch.
    private static let sweepWindow: TimeInterval = 60 * 60
    private static let sweepLimit = 64

    private let root: URL
    private let onHit: (Hit) -> Void
    private let queue = DispatchQueue(label: "com.anchor.claude-transcript-watcher", qos: .utility)
    private static let queueKey = DispatchSpecificKey<ObjectIdentifier>()

    /// Everything below is touched only from `queue`.
    private var stream: FSEventStreamRef?
    private var sizes: [String: UInt64] = [:]
    private var lastEmitted: (sessionId: String, resetDate: Date)?
    private var handlesSincePrune = 0

    /// `onHit` is called on the watcher's own background queue, never on main.
    /// It can also fire for a banner that is already in the past — the first
    /// event for a file the watcher has not seen before scans the existing tail.
    /// Callers filter on `limit.resetDate`.
    init(root: URL, onHit: @escaping (Hit) -> Void) {
        self.root = root
        self.onHit = onHit
        queue.setSpecific(key: Self.queueKey, value: ObjectIdentifier(self))
    }

    deinit {
        stop()
    }

    // MARK: - Lifecycle

    func start() {
        onQueue {
            guard self.stream == nil else { return }

            var context = FSEventStreamContext(
                version: 0,
                info: Unmanaged.passUnretained(self).toOpaque(),
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            // FileEvents gives per-file paths instead of a directory to rescan;
            // NoDefer fires the first event immediately and coalesces after it.
            let flags = UInt32(
                kFSEventStreamCreateFlagFileEvents
                    | kFSEventStreamCreateFlagNoDefer
                    | kFSEventStreamCreateFlagUseCFTypes
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                Self.eventCallback,
                &context,
                [self.root.path] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                Self.latency,
                flags
            ) else {
                Logger.log("FSEventStreamCreate failed for \(self.root.path)", category: .error)
                return
            }

            FSEventStreamSetDispatchQueue(stream, self.queue)
            guard FSEventStreamStart(stream) else {
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
                Logger.log("FSEventStreamStart failed for \(self.root.path)", category: .error)
                return
            }

            self.stream = stream
        }
    }

    /// Torn down on `queue` so it cannot race a callback in flight — the stream
    /// is scheduled on that same serial queue, so no delivery can overlap this.
    func stop() {
        onQueue {
            guard let stream = self.stream else { return }
            self.stream = nil
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    private func onQueue(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: Self.queueKey) == ObjectIdentifier(self) {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    // MARK: - Event handling

    private static let eventCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info, numEvents > 0 else { return }
        let watcher = Unmanaged<ClaudeTranscriptWatcher>.fromOpaque(info).takeUnretainedValue()
        guard let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] else { return }

        // The kernel coalesces or drops events under load, and a drop is silent:
        // the write that carried the banner simply never arrives as a path. The
        // whole feature would then wait for a reset it never learned about, so a
        // drop has to trigger a sweep instead of being ignored.
        let significant = FSEventStreamEventFlags(kFSEventStreamEventFlagKernelDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagUserDropped)
            | FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
        var dropped = false
        for index in 0..<numEvents where eventFlags[index] & significant != 0 {
            dropped = true
            break
        }

        watcher.handle(paths: paths, dropped: dropped)
    }

    private func handle(paths: [String], dropped: Bool = false) {
        let observedAt = Date()

        if dropped {
            Logger.log(
                "Claude usage: FSEvents reported dropped events; sweeping transcripts",
                category: .warning)
            sweepRecentlyModified(observedAt: observedAt)
        }

        for path in paths where path.hasSuffix(".jsonl") {
            guard let info = Self.fileInfo(path) else {
                sizes.removeValue(forKey: path)
                continue
            }

            let recorded = sizes[path] ?? 0
            guard info.size > recorded else {
                // Truncated or replaced — re-anchor rather than scan backwards.
                if info.size != recorded { sizes[path] = info.size }
                continue
            }

            sizes[path] = scan(
                path: path,
                from: recorded,
                upTo: info.size,
                modifiedAt: info.modified,
                observedAt: observedAt
            )
        }

        pruneSizesIfNeeded()
    }

    /// Rescans transcripts touched recently, for when FSEvents admits it lost
    /// events. Bounded by mtime so it stays a sweep of the handful of live
    /// sessions rather than a walk of every transcript ever written.
    private func sweepRecentlyModified(observedAt: Date) {
        let cutoff = observedAt.addingTimeInterval(-Self.sweepWindow)
        guard let walker = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        var swept = 0
        for case let url as URL in walker where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(
                forKeys: [.contentModificationDateKey, .fileSizeKey]),
                let modified = values.contentModificationDate,
                modified >= cutoff,
                let size = values.fileSize.map(UInt64.init)
            else { continue }

            let path = url.path
            let recorded = sizes[path] ?? 0
            guard size > recorded else {
                if size != recorded { sizes[path] = size }
                continue
            }
            sizes[path] = scan(
                path: path, from: recorded, upTo: size,
                modifiedAt: modified, observedAt: observedAt)
            swept += 1

            // A drop storm must not turn into an unbounded walk on the callback
            // queue; anything past this is picked up by the next real event.
            if swept >= Self.sweepLimit { break }
        }
    }

    /// Reads the grown tail and returns the offset to resume from next time.
    private func scan(
        path: String,
        from recorded: UInt64,
        upTo size: UInt64,
        modifiedAt: Date,
        observedAt: Date
    ) -> UInt64 {
        let start = max(recorded, size > Self.maxTailBytes ? size - Self.maxTailBytes : 0)
        guard size > start else { return size }

        guard let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else {
            return size
        }
        defer { try? handle.close() }

        let chunk: Data
        do {
            try handle.seek(toOffset: start)
            guard let data = try handle.read(upToCount: Int(size - start)), !data.isEmpty else {
                return size
            }
            chunk = data
        } catch {
            return size
        }

        // Resume at the last complete line so a banner split across two reads is
        // not lost. If the chunk holds no newline at all (one enormous line, e.g.
        // a large tool result) advance fully rather than rescanning it forever.
        var consumed = size
        if let lastNewline = chunk.lastIndex(of: 0x0A) {
            let trailing = chunk.distance(from: chunk.index(after: lastNewline), to: chunk.endIndex)
            if trailing > 0 { consumed = size - UInt64(trailing) }
        }

        guard Self.containsBanner(chunk) else { return consumed }

        let sessionId = Self.sessionId(forTranscriptAt: path)
        for line in String(decoding: chunk, as: UTF8.self).split(separator: "\n") {
            guard let hit = Self.hit(
                forLine: line,
                path: path,
                sessionId: sessionId,
                modifiedAt: modifiedAt,
                observedAt: observedAt
            ) else { continue }
            emit(hit)
        }

        return consumed
    }

    private func emit(_ hit: Hit) {
        if let last = lastEmitted, last.sessionId == hit.sessionId, last.resetDate == hit.limit.resetDate {
            return
        }
        lastEmitted = (hit.sessionId, hit.limit.resetDate)
        onHit(hit)
    }

    private func pruneSizesIfNeeded() {
        guard sizes.count > Self.sizeMapPruneThreshold else { return }

        // Throttled: this is one `access()` per entry, and the map stays over
        // threshold permanently once a machine has enough transcripts, so an
        // unthrottled prune would add a 400-syscall sweep to every callback on
        // the hottest path in the app.
        handlesSincePrune += 1
        guard handlesSincePrune >= Self.prunePeriod else { return }
        handlesSincePrune = 0

        sizes = sizes.filter { access($0.key, F_OK) == 0 }
        // Still unbounded if that many transcripts genuinely exist; drop the lot
        // and let it re-seed lazily rather than hold the map open forever.
        if sizes.count > Self.sizeMapPruneThreshold * 2 {
            sizes.removeAll(keepingCapacity: false)
        }
    }

    // MARK: - Parsing

    private static func hit(
        forLine line: Substring,
        path: String,
        sessionId: String,
        modifiedAt: Date,
        observedAt: Date
    ) -> Hit? {
        guard let text = bannerWindow(in: line) else { return nil }

        // Only the assistant stream carries the real banner. Anything the user
        // typed, pasted or attached can *quote* one — a plan that documents the
        // format, a pasted log, this feature's own source — and those quotes
        // parse just as well as the genuine article. Measured on this machine:
        // 23 of 89 fully-matching lines came from `user`, `queue-operation` and
        // `attachment` events, every one of them prose rather than a real limit.
        //
        // The decode and the type check are one guard on purpose. Splitting them
        // — treating an undecodable line as merely "no metadata" and carrying on
        // — let a malformed or truncated line skip the type check entirely and
        // reach the parser. A line that is not a decodable event has no
        // provenance to trust, so it is dropped rather than believed.
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              (object["type"] as? String) == "assistant"
        else { return nil }

        var anchor = modifiedAt
        if let stamp = object["timestamp"] as? String, let parsed = date(fromISO8601: stamp) {
            anchor = parsed
        }
        var cwd = ""
        if let field = object["cwd"] as? String, !field.isEmpty {
            cwd = field
        }

        guard let limit = ClaudeLimitParser.parse(text, anchoredAt: anchor) else {
            // The wording is undocumented and can change without notice, which
            // would otherwise make this feature fail completely silently. Kept
            // at debug because the literal prefilter also catches ordinary prose
            // about usage limits, so this fires routinely and is a breadcrumb to
            // go looking for, not an alarm.
            //
            // The text itself is deliberately NOT logged. It is a slice of an
            // assistant message — whatever Claude happened to be discussing —
            // and `Logger.log` emits `%{public}@`, so it would land in the
            // unified log readable by anything on the machine. The path and
            // offset are just as diagnostic and leak nothing.
            Logger.log(
                "Claude usage: banner-like text did not parse in \(path) (\(text.count) chars)",
                category: .debug)
            return nil
        }

        return Hit(
            limit: limit,
            sessionId: sessionId,
            cwd: cwd,
            transcriptPath: path,
            observedAt: observedAt
        )
    }

    /// Cheap literal test over the raw bytes, before any string or JSON work.
    private static func containsBanner(_ data: Data) -> Bool {
        data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress, raw.count > 0 else { return false }
            for literal in bannerLiterals {
                let bytes = Array(literal.utf8)
                let found = bytes.withUnsafeBytes { needle -> Bool in
                    guard let needleBase = needle.baseAddress else { return false }
                    return memmem(base, raw.count, needleBase, needle.count) != nil
                }
                if found { return true }
            }
            return false
        }
    }

    /// Pulls a bounded window around the banner out of the raw line rather than
    /// walking `message.content` — the content schema differs per event type and
    /// has changed before; the literal has not.
    private static func bannerWindow(in line: Substring) -> String? {
        var earliest: Range<Substring.Index>?
        for literal in bannerLiterals {
            guard let found = line.range(of: literal) else { continue }
            if let current = earliest, current.lowerBound <= found.lowerBound { continue }
            earliest = found
        }
        guard let hit = earliest else { return nil }

        let lower = line.index(hit.lowerBound, offsetBy: -windowBefore, limitedBy: line.startIndex)
            ?? line.startIndex
        let upper = line.index(hit.upperBound, offsetBy: windowAfter, limitedBy: line.endIndex)
            ?? line.endIndex
        return unescaped(String(line[lower..<upper]))
    }

    /// The window is a slice of JSON source, so the banner arrives escaped.
    /// Only the two escapes that show up in banner text are undone; this is a
    /// parser input, not a faithful JSON decode.
    private static func unescaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\\"", with: "\"")
    }

    /// Subagent transcripts live at `<sessionId>/subagents/agent-<id>.jsonl`, and
    /// the session a user can actually resume is the parent, not the agent.
    private static func sessionId(forTranscriptAt path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let parent = url.deletingLastPathComponent()
        if parent.lastPathComponent == "subagents" {
            return parent.deletingLastPathComponent().lastPathComponent
        }
        return url.deletingPathExtension().lastPathComponent
    }

    // MARK: - Primitives

    /// `stat` rather than opening the file — this runs for every event.
    private static func fileInfo(_ path: String) -> (size: UInt64, modified: Date)? {
        var status = stat()
        guard stat(path, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { return nil }
        let modified = Date(
            timeIntervalSince1970: Double(status.st_mtimespec.tv_sec)
                + Double(status.st_mtimespec.tv_nsec) / 1_000_000_000
        )
        return (UInt64(status.st_size), modified)
    }

    // ISO8601DateFormatter costs real time to build; both variants exist because
    // fractional seconds are present on most lines but not all.
    private static let fractionalFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let internetFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static func date(fromISO8601 string: String) -> Date? {
        fractionalFormatter.date(from: string) ?? internetFormatter.date(from: string)
    }
}
