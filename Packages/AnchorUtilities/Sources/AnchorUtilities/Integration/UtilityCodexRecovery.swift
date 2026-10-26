import AppKit
import Combine
import Foundation

/// Event-driven limit detection plus a single reset deadline. Account requests
/// happen only after a limit failure and at recovery, never on a polling loop.
public final class UtilityCodexRecovery: ObservableObject {
    public static let shared = UtilityCodexRecovery()
    @Published public private(set) var status = "Off"
    @Published public private(set) var resetDate: Date?
    public var onResetDetected: ((Date) -> Void)?
    private let queue = DispatchQueue(label: "com.anchor.codex-recovery", qos: .utility)
    private var watcher: AgentLogWatcher?
    private var timer: DispatchSourceTimer?
    private var wake: NSObjectProtocol?
    private var enabled = false // main only
    private var autoResume = false
    private var generation = UUID()
    private var lifetime = CleanerSupport.ScanCancellation()
    // Queue-confined state.
    private var activeGeneration = UUID()
    private var cancelled = CleanerSupport.ScanCancellation()
    private var sizes: [String: UInt64] = [:]
    private var pending: Pending? {
        didSet {
            let key = "Anchor.codexRecovery.pending"
            guard let item = pending else { UtilityPreferences.standard.removeObject(forKey: key); return }
            // Local recovery metadata only: no prompts or transcript contents.
            UtilityPreferences.standard.set(["path": item.url.path, "size": item.size,
                "device": item.identity.device, "inode": item.identity.inode,
                "session": item.session, "reset": item.reset.timeIntervalSince1970,
                "blocked": item.blocked.timeIntervalSince1970, "dynamic": item.dynamicTools], forKey: key)
        }
    }
    private var worker: AgentCodexConversation?
    private var attempts: [String: Int] = [:]
    private var consumed = Set<String>()
    private struct Pending {
        let url: URL
        let size: UInt64
        let identity: UninstallerSupport.FileIdentity
        let session: String
        let reset: Date
        let blocked: Date
        let dynamicTools: Bool
        var key: String { session + "@" + String(Int(reset.timeIntervalSince1970)) }
    }
    private var sessions: URL {
        let base = ProcessInfo.processInfo.environment["CODEX_HOME"].flatMap { $0.hasPrefix("/") ? URL(fileURLWithPath: $0) : nil }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex")
        return base.appendingPathComponent("sessions")
    }
    private init() {}

    /// Main-thread API. Turning this off cancels watchers, deadlines and a
    /// recovery process, including callbacks already queued from an old run.
    public func configure(enabled: Bool, autoResume: Bool) {
        precondition(Thread.isMainThread)
        let changed = self.enabled != enabled || self.autoResume != autoResume
        guard changed else { return }
        self.enabled = enabled; self.autoResume = autoResume
        lifetime.cancel()
        lifetime = CleanerSupport.ScanCancellation()
        let flag = lifetime
        generation = UUID()
        let token = generation
        if let wake { NSWorkspace.shared.notificationCenter.removeObserver(wake) }; wake = nil
        if enabled {
            wake = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                object: nil, queue: .main) { [weak self] _ in
                self?.queue.async { [weak self] in self?.recoverIfDue() }
            }
        }
        status = enabled ? "Watching for Codex usage-limit stops" : "Off"
        resetDate = nil
        let root = sessions
        let apps = AgentCodexServer.appIdentifiers.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) }
        queue.async { [self] in
            let saved = UtilityPreferences.standard.dictionary(forKey: "Anchor.codexRecovery.pending")
            cancelled.cancel(); worker?.end(); worker = nil
            watcher?.stop(); watcher = nil; timer?.cancel(); timer = nil; pending = nil; sizes = [:]
            activeGeneration = token; cancelled = flag
            consumed = Set(UtilityPreferences.standard.stringArray(forKey: "Anchor.codexRecovery.attemptedKeys") ?? [])
            attempts = UtilityPreferences.standard.dictionary(forKey: "Anchor.codexRecovery.attemptCounts") as? [String: Int] ?? [:]
            guard enabled else { return }
            restore(saved, root: root, apps: apps, autoResume: autoResume)
            let events = AgentLogWatcher(queue: queue) { [weak self] paths, rescan in
                guard let self else { return }
                self.changed(paths: paths, rescan: rescan, root: root, apps: apps, autoResume: autoResume)
            }
            watcher = events
            // Watch the parent too so a first Codex session can create sessions/.
            _ = events.start([root.deletingLastPathComponent().path])
            self.changed(paths: [], rescan: true, root: root, apps: apps, autoResume: autoResume)
        }
    }

    private func restore(_ saved: [String: Any]?, root: URL, apps: [URL], autoResume: Bool) {
        guard let saved, let path = saved["path"] as? String,
              path.hasPrefix(root.path + "/"), let session = saved["session"] as? String,
              UUID(uuidString: session) != nil, let reset = saved["reset"] as? Double,
              let blocked = saved["blocked"] as? Double, reset > blocked,
              Date().timeIntervalSince1970 - reset < 3600,
              reset - Date().timeIntervalSince1970 < 8 * 86400,
              let size = (saved["size"] as? NSNumber)?.uint64Value,
              let device = (saved["device"] as? NSNumber)?.uint64Value,
              let inode = (saved["inode"] as? NSNumber)?.uint64Value else { return }
        let url = URL(fileURLWithPath: path)
        guard url.path == url.resolvingSymlinksInPath().path else { return }
        let item = Pending(url: url, size: size, identity: .init(device: device, inode: inode), session: session,
            reset: Date(timeIntervalSince1970: reset), blocked: Date(timeIntervalSince1970: blocked),
            dynamicTools: saved["dynamic"] as? Bool ?? true)
        guard unchanged(item), !consumed.contains(item.key) else { return }
        pending = item
        publish(token: activeGeneration) {
            $0.resetDate = item.reset
            $0.status = autoResume ? "Codex paused · will continue after usage resets" : "Codex paused · reset notification scheduled"
        }
        arm(at: item.reset.addingTimeInterval(5), apps: apps, autoResume: autoResume)
    }

    private func changed(paths: [String], rescan: Bool, root: URL, apps: [URL], autoResume: Bool) {
        let fm = FileManager.default
        let urls: [URL]
        let relevant = paths.filter { $0 == root.path || $0.hasPrefix(root.path + "/") }
        if !rescan, relevant.isEmpty { return }
        if rescan || relevant.contains(where: { !$0.hasSuffix(".jsonl") }) {
            let keys: [URLResourceKey] = [.contentModificationDateKey, .isDirectoryKey, .isSymbolicLinkKey]
            let walker = fm.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
            var files: [URL] = []
            while !cancelled.isCancelled, let url = walker?.nextObject() as? URL {
                let values = try? url.resourceValues(forKeys: Set(keys))
                if values?.isSymbolicLink == true { walker?.skipDescendants(); continue }
                if url.pathExtension == "jsonl", let modified = values?.contentModificationDate,
                   Date().timeIntervalSince(modified) < 24 * 3600 { files.append(url) }
            }
            urls = files
        } else {
            urls = paths.filter { $0.hasPrefix(root.path + "/") && $0.hasSuffix(".jsonl") }.map { URL(fileURLWithPath: $0) }
        }
        for url in urls {
            guard !cancelled.isCancelled else { return }
            inspect(url, apps: apps, autoResume: autoResume)
        }
    }

    private func inspect(_ url: URL, apps: [URL], autoResume: Bool) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              sizes[url.path] != size, url == url.resolvingSymlinksInPath(),
              let identity = UninstallerSupport.fileIdentity(at: url),
              let handle = try? FileHandle(forReadingFrom: url) else { return }
        let oldSize = sizes[url.path]
        sizes[url.path] = size
        defer { try? handle.close() }
        // Most writes are ordinary work. Inspect only a bounded grown tail for
        // a literal before decoding JSON or looking at the session header.
        let grownStart = oldSize.map { $0 > 1024 ? $0 - 1024 : 0 } ?? 0
        let probeStart = max(grownStart > size ? 0 : grownStart, size > 65_536 ? size - 65_536 : 0)
        try? handle.seek(toOffset: probeStart)
        let probe = (try? handle.read(upToCount: 65_536)) ?? Data()
        guard AgentLogParser.contains(probe, "usage_limit") || AgentLogParser.contains(probe, "usageLimit")
            || AgentLogParser.contains(probe, "hit your usage limit.") else { return }
        try? handle.seek(toOffset: 0)
        let header = (try? handle.read(upToCount: 16_384)) ?? Data()
        let start = size > 131_072 ? size - 131_072 : 0
        try? handle.seek(toOffset: start)
        let tail = (try? handle.read(upToCount: 131_072)) ?? Data()
        var evidence = CodexRecoveryEvidence()
        let now = Date()
        for line in header.split(separator: 10).prefix(1) { evidence.consume(Data(line), now: now) }
        for line in tail.split(separator: 10).dropFirst(start > 0 ? 1 : 0) { evidence.consume(Data(line), now: now) }
        guard UUID(uuidString: evidence.sessionID) != nil, let blocked = evidence.blockedAt,
              now.timeIntervalSince(blocked) >= 0, now.timeIntervalSince(blocked) < 24 * 3600 else { return }
        var reset = CodexRecoveryEvidence.resetDate(evidence.windows, now: now)
        if reset == nil, let executable = AgentCodexServer.executable(apps: apps, home: FileManager.default.homeDirectoryForCurrentUser) {
            let conversation = AgentCodexConversation(executable, environment: AgentCodexServer.environment(for: executable, searchPath: nil), timeout: 20)
            if let conversation {
                defer { conversation.end() }
                if (try? conversation.start().get()) != nil,
                   let result = try? conversation.ask("account/rateLimits/read").get(),
                   let limits = AgentCodexServer.limits(result, observed: now) {
                    reset = CodexRecoveryEvidence.resetDate(limits.windows, now: now)
                }
            }
        }
        guard let reset, reset > blocked, now.timeIntervalSince(reset) < 3600 else { return }
        let item = Pending(url: url, size: size, identity: identity, session: evidence.sessionID,
                           reset: reset, blocked: blocked, dynamicTools: evidence.hasDynamicTools)
        guard !consumed.contains(item.key) else { return }
        if pending?.key == item.key { pending = item; return }
        guard pending == nil || blocked > pending!.blocked else { return }
        pending = item
        let token = activeGeneration
        let notificationKey = "Anchor.codexRecovery.notified"
        let shouldNotify = UtilityPreferences.standard.string(forKey: notificationKey) != item.key
        if shouldNotify { UtilityPreferences.standard.set(item.key, forKey: notificationKey) }
        publish(token: token) { service in
            service.resetDate = reset
            service.status = autoResume ? "Codex paused · will continue after usage resets" : "Codex paused · reset notification scheduled"
            if shouldNotify { service.onResetDetected?(reset) }
        }
        arm(at: reset.addingTimeInterval(5), apps: apps, autoResume: autoResume)
    }

    private var recoveryApps: [URL] = []
    private var recoveryAutoResume = false
    private func arm(at date: Date, apps: [URL], autoResume: Bool) {
        timer?.cancel(); recoveryApps = apps; recoveryAutoResume = autoResume
        let next = DispatchSource.makeTimerSource(queue: queue)
        next.schedule(deadline: .now() + max(0, date.timeIntervalSinceNow), leeway: .seconds(2))
        next.setEventHandler { [weak self] in self?.recoverIfDue() }
        timer = next; next.resume()
    }
    private func recoverIfDue() {
        guard let item = pending, Date() >= item.reset, !cancelled.isCancelled else { return }
        timer?.cancel(); timer = nil
        let token = activeGeneration
        guard recoveryAutoResume else { pending = nil; publish(token: token) { $0.status = "Codex usage reset"; $0.resetDate = nil }; return }
        guard Date().timeIntervalSince(item.reset) < 3600,
              !item.dynamicTools, (attempts[item.session] ?? 0) < 3,
              unchanged(item),
              UtilityPreferences.standard.string(forKey: "Anchor.codexRecovery.attempted") != item.key,
              let executable = AgentCodexServer.executable(apps: recoveryApps, home: FileManager.default.homeDirectoryForCurrentUser),
              let conversation = AgentCodexConversation(executable,
                  environment: AgentCodexServer.environment(for: executable, searchPath: nil), timeout: 6 * 3600, recovery: true, cancellation: cancelled) else {
            pending = nil
            publish(token: token) { $0.status = "Codex reset · open the task to continue (changed task or unsupported tools)"; $0.resetDate = nil }
            return
        }
        worker = conversation
        defer { conversation.end(); worker = nil }
        guard (try? conversation.start().get()) != nil,
              let limits = try? conversation.ask("account/rateLimits/read").get(),
              let reading = AgentCodexServer.limits(limits, observed: Date()) else {
            pending = nil; publish(token: token) { $0.status = "Could not verify Codex usage · open Codex to continue" }; return
        }
        if let reset = CodexRecoveryEvidence.resetDate(reading.windows, now: Date()), reset > Date() {
            // Account state wins over an estimate copied into an old log.
            pending = Pending(url: item.url, size: item.size, identity: item.identity, session: item.session,
                reset: reset, blocked: item.blocked, dynamicTools: item.dynamicTools)
            publish(token: token) { $0.resetDate = reset }
            arm(at: reset.addingTimeInterval(5), apps: recoveryApps, autoResume: recoveryAutoResume)
            return
        }
        guard limits["ordinaryUsageAllowed"] as? Bool != false,
              reading.windows.allSatisfy({ $0.usedPercent < 100 }), unchanged(item),
              let latest = try? conversation.ask("thread/turns/list", ["threadId": item.session, "limit": 1]).get(),
              let turn = (latest["data"] as? [[String: Any]])?.first,
              CodexRecoveryEvidence.latestTurnIsLimited(turn),
              !cancelled.isCancelled,
              (try? conversation.ask("thread/resume", ["threadId": item.session, "excludeTurns": true]).get()) != nil,
              unchanged(item), !cancelled.isCancelled else {
            pending = nil; publish(token: token) { $0.status = "Codex task changed or needs attention · automatic continuation skipped"; $0.resetDate = nil }; return
        }
        // Persist before starting: a crash cannot send the same continuation twice.
        UtilityPreferences.standard.set(item.key, forKey: "Anchor.codexRecovery.attempted")
        consumed.insert(item.key); attempts[item.session, default: 0] += 1; pending = nil
        var keys = UtilityPreferences.standard.stringArray(forKey: "Anchor.codexRecovery.attemptedKeys") ?? []
        keys.append(item.key)
        UtilityPreferences.standard.set(Array(keys.suffix(100)), forKey: "Anchor.codexRecovery.attemptedKeys")
        // Keep only sessions represented by the bounded idempotency ledger.
        let retained = Set(keys.suffix(100).compactMap { $0.split(separator: "@").first.map(String.init) })
        attempts = attempts.filter { retained.contains($0.key) }
        UtilityPreferences.standard.set(attempts, forKey: "Anchor.codexRecovery.attemptCounts")
        guard let response = try? conversation.ask("turn/start", ["threadId": item.session,
            "input": [["type": "text", "text": "Continue the task that stopped at the usage limit. Preserve the existing instructions and scope."]]]).get(),
            let started = response["turn"] as? [String: Any], let turnID = started["id"] as? String else {
            publish(token: token) { $0.status = "Codex could not start · open the task to continue" }; return
        }
        publish(token: token) { $0.status = "Codex continued"; $0.resetDate = nil }
        // Keep this server alive for the turn. Approval/tool requests require
        // the original client: interrupt rather than approve or fabricate output.
        if conversation.serverRequestSeen {
            _ = conversation.ask("turn/interrupt", ["threadId": item.session, "turnId": turnID])
            publish(token: token) { $0.status = "Codex needs approval or an app tool · open the task" }
            return
        }
        while !cancelled.isCancelled, let message = conversation.recoveryNext(cancelled: cancelled) {
            if message["id"] != nil, message["method"] != nil {
                _ = conversation.ask("turn/interrupt", ["threadId": item.session, "turnId": turnID])
                publish(token: token) { $0.status = "Codex needs approval or an app tool · open the task" }
                break
            }
            if message["method"] as? String == "turn/completed" { break }
        }
    }
    private func unchanged(_ item: Pending) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: item.url.path) else { return false }
        return (attributes[.size] as? NSNumber)?.uint64Value == item.size
            && UninstallerSupport.fileIdentity(at: item.url) == item.identity
    }
    private func publish(token: UUID, _ body: @escaping (UtilityCodexRecovery) -> Void) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.generation == token, self.enabled else { return }
            body(self)
        }
    }
}
