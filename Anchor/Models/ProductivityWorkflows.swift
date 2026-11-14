import Foundation

enum DailyCommitCountPolicy {
    static func bounds(_ first: Int, _ second: Int) -> ClosedRange<Int> {
        let lower = max(0, min(Int.max - 1, min(first, second)))
        let upper = max(lower, min(Int.max - 1, max(first, second)))
        return lower...upper
    }

    /// SplitMix64 gives a stable draw for an installation and local day;
    /// Swift's Hasher is intentionally randomized on every process launch.
    static func draw(day: Date, seed: UInt64, minimum: Int, maximum: Int,
                     calendar: Calendar = .current) -> Int {
        let limits = bounds(minimum, maximum)
        let value = stableValue(day: day, seed: seed, salt: 0, calendar: calendar)
        let width = UInt64(limits.upperBound - limits.lowerBound) + 1
        return limits.lowerBound + Int(value % width)
    }

    static func respectingSpacing(_ candidate: Date, lastRun: Date?, calendar: Calendar = .current) -> Date {
        guard let lastRun, calendar.isDate(candidate, inSameDayAs: lastRun) else { return candidate }
        return max(candidate, lastRun.addingTimeInterval(60))
    }

    static func stableValue(day: Date, seed: UInt64, salt: UInt64,
                            calendar: Calendar = .current) -> UInt64 {
        let components = calendar.dateComponents([.era, .year, .month, .day], from: day)
        // Use the local calendar date, not midnight's absolute timestamp, so
        // traveling between time zones on the same date does not redraw it.
        let dayNumber = Int64(components.era ?? 0) &* 1_000_000_000
            &+ Int64(components.year ?? 0) &* 512
            &+ Int64(components.month ?? 0) &* 32
            &+ Int64(components.day ?? 0)
        var value = UInt64(bitPattern: dayNumber) ^ seed ^ salt
        value &+= 0x9E3779B97F4A7C15
        value = (value ^ (value >> 30)) &* 0xBF58476D1CE4E5B9
        value = (value ^ (value >> 27)) &* 0x94D049BB133111EB
        value ^= value >> 31
        return value
    }
}

final class DailyCommitRunGate {
    private let lock = NSLock()
    private var active = false

    func begin() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { return false }
        active = true
        return true
    }

    func end() {
        lock.lock(); defer { lock.unlock() }
        active = false
    }

    var isActive: Bool {
        lock.lock(); defer { lock.unlock() }
        return active
    }
}

final class AppleNotesSyncGeneration {
    private let lock = NSLock()
    private var current = UUID()

    func capture() -> UUID {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        current = UUID()
    }

    func accepts(_ ticket: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return current == ticket
    }
}

enum AppleNotesSnapshotReconciliation {
    /// Apply a sync result only where the local record still matches the
    /// snapshot it started with. Keep edits and deletions made during sync.
    static func merge<Item: Identifiable & Equatable>(baseline: [Item], result: [Item], current: [Item]) -> [Item] where Item.ID: Hashable {
        let baselineByID = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let resultByID = Dictionary(result.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let currentIDs = Set(current.map(\.id))
        var merged: [Item] = []
        for item in current {
            guard let old = baselineByID[item.id] else { merged.append(item); continue }
            if item != old { merged.append(item); continue }
            if let updated = resultByID[item.id] { merged.append(updated) }
        }
        for item in result where baselineByID[item.id] == nil && !currentIDs.contains(item.id) {
            merged.append(item)
        }
        return merged
    }
}

enum AppleNotesSyncPolicy {
    static func permitsNewWork(notesEnabled: Bool, syncEnabled: Bool) -> Bool {
        notesEnabled && syncEnabled
    }
}

/// Value types shared by the native controls and standalone regression harness.
struct AnchorQuicklink: Identifiable, Codable, Equatable {
    var id = UUID()
    var title: String
    var keyword: String
    var target: String
    var isEnabled = true

    var needsQuery: Bool { target.contains("{query}") }

    var validationError: String? {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Give this quicklink a name." }
        if keyword.range(of: "^[A-Za-z][A-Za-z0-9_-]{0,23}$", options: .regularExpression) == nil {
            return "Use a keyword starting with a letter, with no spaces (up to 24 characters)."
        }
        if resolvedURL(query: "test") == nil { return "Choose a file or use an http or https URL. Put {query} where a search term belongs." }
        return nil
    }

    func resolvedURL(query: String) -> URL? {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed),
              let url = URL(string: target.replacingOccurrences(of: "{query}", with: encoded)) else { return nil }
        if url.isFileURL { return needsQuery ? nil : url }
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }

    /// A keyword consumes a whole first word, so `g` never steals `garage`.
    func argument(in input: String) -> String? {
        let words = input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard let first = words.first, first.lowercased() == keyword.lowercased() else { return nil }
        return words.count > 1 ? String(words[1]).trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }

    static func directWebURL(_ input: String) -> URL? {
        let raw = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.contains(where: { $0.isWhitespace }) else { return nil }
        let candidate: String
        if raw.lowercased().hasPrefix("https://") || raw.lowercased().hasPrefix("http://") {
            candidate = raw
        } else {
            // Bare domains are convenient; paths, app names and other schemes are not URLs here.
            guard !raw.contains(":"), !raw.hasPrefix("/"), !raw.hasPrefix("."),
                  let first = raw.split(separator: "/").first, first.contains(".") else { return nil }
            candidate = "https://" + raw
        }
        let link = AnchorQuicklink(title: "Open URL", keyword: "open", target: candidate)
        return link.resolvedURL(query: "")
    }

    static let starters: [AnchorQuicklink] = [
        .init(title: "Google", keyword: "g", target: "https://www.google.com/search?q={query}"),
        .init(title: "DuckDuckGo", keyword: "ddg", target: "https://duckduckgo.com/?q={query}"),
        .init(title: "GitHub", keyword: "gh", target: "https://github.com/search?q={query}"),
        .init(title: "YouTube", keyword: "yt", target: "https://www.youtube.com/results?search_query={query}")
    ]
}

enum ClipboardCapturePolicy {
    /// A delayed clear belongs to the copy that armed it. A newer copy gets
    /// its own delay when the watcher observes it; sleep/lock clears are
    /// intentionally unconditional.
    static func shouldClear(expectedChangeCount: Int?, currentChangeCount: Int) -> Bool {
        expectedChangeCount == nil || expectedChangeCount == currentChangeCount
    }

    static func needsWatcher(history: Bool, cleanURLs: Bool, autoClear: Bool) -> Bool {
        history || cleanURLs || autoClear
    }

    static func shouldPoll(isMonitoring: Bool, isPaused: Bool, isSuspended: Bool) -> Bool {
        isMonitoring && !isPaused && !isSuspended
    }

    static let sensitiveTypes: Set<String> = [
        "org.nspasteboard.TransientType", "org.nspasteboard.ConcealedType",
        "org.nspasteboard.AutoGeneratedType", "com.agilebits.onepassword",
        "net.antelle.keeweb", "de.petermaurer.TransientPasteboardType"
    ]

    static func permits(types: Set<String>, source: String?, ignoredApps: [String], skipSensitive: Bool) -> Bool {
        if skipSensitive && !types.isDisjoint(with: sensitiveTypes) { return false }
        return source.map { !ignoredApps.contains($0) } ?? true
    }

    static func isExpired(timestamp: Date, retentionDays: Int, now: Date) -> Bool {
        retentionDays > 0 && now.timeIntervalSince(timestamp) >= Double(retentionDays) * 86_400
    }

    static func safeImageName(_ name: String) -> Bool {
        !name.isEmpty && name == (name as NSString).lastPathComponent && !name.contains("\\") && name != "." && name != ".."
    }
}

struct ClipboardSearchDocument {
    let type: String
    let text: String
    let source: String
    let collection: String

    func matches(_ query: String) -> Bool {
        query.split(whereSeparator: { $0.isWhitespace }).allSatisfy { token in
            let term = String(token)
            let lower = term.lowercased()
            if lower.hasPrefix("@app:") { return source.localizedCaseInsensitiveContains(String(term.dropFirst(5))) }
            if lower.hasPrefix("@board:") { return collection.localizedCaseInsensitiveContains(String(term.dropFirst(7))) }
            switch lower {
            case "@image", "@images": return type == "image"
            case "@file", "@files": return type == "file"
            case "@url", "@link", "@links": return type == "url"
            case "@text": return ["text", "rtf", "unknown"].contains(type)
            case "@rich": return type == "rtf"
            default:
                if lower.hasPrefix("@") { return source.localizedCaseInsensitiveContains(String(term.dropFirst())) }
                return [text, source, collection, type].contains { $0.localizedCaseInsensitiveContains(term) }
            }
        }
    }
}

enum ClipboardTextTransform: String, CaseIterable, Identifiable {
    case trim = "Trim whitespace"
    case uppercase = "UPPERCASE"
    case lowercase = "lowercase"
    case titleCase = "Title Case"
    case joinLines = "Join lines"
    case removeEmptyLines = "Remove empty lines"
    case uniqueLines = "Remove duplicate lines"
    case sortLines = "Sort lines"
    var id: String { rawValue }

    func apply(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        switch self {
        case .trim: return text.trimmingCharacters(in: .whitespacesAndNewlines)
        case .uppercase: return text.uppercased()
        case .lowercase: return text.lowercased()
        case .titleCase: return text.capitalized
        case .joinLines: return lines.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
        case .removeEmptyLines: return lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: "\n")
        case .uniqueLines:
            var seen = Set<String>()
            return lines.filter { seen.insert($0).inserted }.joined(separator: "\n")
        case .sortLines: return lines.sorted { $0.localizedStandardCompare($1) == .orderedAscending }.joined(separator: "\n")
        }
    }
}

struct FocusCycleConfiguration: Codable, Equatable {
    var focusMinutes = 25
    var shortBreakMinutes = 5
    var longBreakMinutes = 15
    var roundsBeforeLongBreak = 4
    var automaticallyContinue = false

    func duration(for phase: FocusCycleState.Phase) -> TimeInterval {
        switch phase {
        case .focus: return Double(min(180, max(1, focusMinutes))) * 60
        case .shortBreak: return Double(min(60, max(1, shortBreakMinutes))) * 60
        case .longBreak: return Double(min(120, max(1, longBreakMinutes))) * 60
        }
    }
}

struct FocusCycleState: Codable, Equatable {
    enum Phase: String, Codable {
        case focus, shortBreak, longBreak
        var title: String {
            switch self { case .focus: return "Focus"; case .shortBreak: return "Short break"; case .longBreak: return "Long break" }
        }
    }
    var phase: Phase = .focus
    var completedRounds = 0
    var intention = ""
    var deadline: Date?
    var pausedRemaining: TimeInterval?
    var phaseDuration: TimeInterval = 25 * 60
    var awaitingNext = false
    var phaseID = UUID()

    var hasSession: Bool { deadline != nil || pausedRemaining != nil || awaitingNext }

    func remaining(at now: Date) -> TimeInterval {
        if let pausedRemaining { return max(0, pausedRemaining) }
        return deadline.map { max(0, $0.timeIntervalSince(now)) } ?? 0
    }

    mutating func completePhase(configuration: FocusCycleConfiguration) -> Bool {
        // Finishing twice (wake, relaunch, stale callback) must not count a round twice.
        guard !awaitingNext, deadline != nil || pausedRemaining != nil else { return false }
        let wasFocus = phase == .focus
        if wasFocus {
            completedRounds += 1
            phase = completedRounds % min(12, max(1, configuration.roundsBeforeLongBreak)) == 0 ? .longBreak : .shortBreak
        } else {
            phase = .focus
        }
        deadline = nil
        pausedRemaining = nil
        awaitingNext = true
        return wasFocus
    }
}
