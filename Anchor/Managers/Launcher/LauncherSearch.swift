import Foundation

/// Local app retrieval and ranking. Tiers protect explicit intent from popularity;
/// frecency only reorders comparably relevant results. See docs/SPOTLIGHT-SEARCH.md.
enum LauncherSearch {
    struct Document {
        let name: String
        let aliases: [String]
        let context: [String]
    }

    struct Match {
        let tier: Int
        let quality: Int
        let indices: [Int]
        let usage: Double

        var score: Double { Double(tier * 1_000 + quality + 100) + usage }

        func outranks(_ other: Match) -> Bool {
            if tier != other.tier { return tier > other.tier }
            return Double(quality) + usage > Double(other.quality) + other.usage
        }
    }

    /// Launchpad favors apps within the same relevance tier. An exact command
    /// still beats a partial app name; explicit URL/quicklink scores remain highest.
    static func precedes(score lhs: Double, isApp lhsApp: Bool, id lhsID: String, lhsSearchOnly lhsUtility: Bool = false,
                         score rhs: Double, isApp rhsApp: Bool, id rhsID: String, rhsSearchOnly rhsUtility: Bool = false) -> Bool {
        let leftTier = Int(lhs / 1_000), rightTier = Int(rhs / 1_000)
        if leftTier != rightTier { return leftTier > rightTier }
        if lhsApp != rhsApp { return lhsApp }
        if lhsUtility != rhsUtility { return !lhsUtility }
        if lhs != rhs { return lhs > rhs }
        return lhsID < rhsID
    }

    /// Folding each original grapheme separately preserves display indices even
    /// when a character expands (ß → ss) or loses a combining accent.
    struct Text {
        let value: String
        let origins: [Int]
        let wordStarts: Set<Int>
        init(_ source: String) {
            var folded = ""
            var offsets: [Int] = []
            var boundaries = Set<Int>()
            let original = Array(source)
            for (index, character) in original.enumerated() {
                let previous = index > 0 ? original[index - 1] : nil
                let next = index + 1 < original.count ? original[index + 1] : nil
                if index == 0 || previous.map({ !$0.isLetter && !$0.isNumber }) == true
                    || (character.isUppercase && (previous?.isLowercase == true || previous?.isNumber == true))
                    || (character.isUppercase && previous?.isUppercase == true && next?.isLowercase == true) {
                    boundaries.insert(offsets.count)
                }
                let part = String(character).folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: Locale(identifier: "en_US_POSIX"))
                folded += part
                offsets += Array(repeating: index, count: part.count)
            }
            value = folded
            origins = offsets
            wordStarts = boundaries
        }
    }

    static func normalizedQuery(_ query: String) -> String {
        Text(query).value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    static func match(query: String, document: Document, frecency: Double = 0) -> Match? {
        let query = normalizedQuery(query)
        // Avoid unbounded DP allocations for pasted text; installed app names are short.
        guard !query.isEmpty, query.count <= 128 else { return nil }
        let usage = frecency.isFinite ? min(24, log2(1 + max(0, frecency)) * 4) : 0
        var best: Match?
        func consider(_ value: String, metadata: Bool, context: Bool = false) {
            let text = Text(value)
            guard let hit = lexical(query, text.value, wordStarts: text.wordStarts, allowFuzzy: !context) else { return }
            let tier = context ? 1 : (metadata ? min(hit.tier, 5) : hit.tier)
            let indices = metadata || context ? [] : Array(Set(hit.indices.map { text.origins[$0] })).sorted()
            let candidate = Match(tier: tier, quality: hit.quality, indices: indices, usage: usage)
            if best == nil || candidate.outranks(best!) { best = candidate }
        }
        consider(document.name, metadata: false)
        for alias in document.aliases where !alias.isEmpty { consider(alias, metadata: true) }
        for field in document.context where !field.isEmpty { consider(field, metadata: true, context: true) }
        return best
    }

    private static func lexical(_ query: String, _ candidate: String, wordStarts: Set<Int>, allowFuzzy: Bool)
        -> (tier: Int, quality: Int, indices: [Int])? {
        let chars = Array(candidate)
        let tokens = query.split(separator: " ").map(String.init)
        // Token prefixes can occur in any order, but each consumes a distinct word.
        var words: [(text: String, start: Int)] = []
        var start: Int?
        for index in 0...chars.count {
            if index < chars.count && (chars[index].isLetter || chars[index].isNumber) {
                if wordStarts.contains(index), let begin = start {
                    words.append((String(chars[begin..<index]), begin))
                    start = nil
                }
                if start == nil { start = index }
            } else if let begin = start {
                words.append((String(chars[begin..<index]), begin))
                start = nil
            }
        }
        if candidate == query { return (7, 100, Array(chars.indices)) }
        if candidate.hasPrefix(query) { return (6, 100 - min(80, chars.count - query.count), Array(0..<query.count)) }
        if tokens.count > 1 {
            // Long tokens first prevent "s system" from consuming System twice.
            var used = Set<Int>()
            var indices: [Int] = []
            for token in tokens.sorted(by: { $0.count > $1.count }) {
                guard let index = words.indices.first(where: { !used.contains($0) && words[$0].text.hasPrefix(token) }) else {
                    return nil // Every term must match; never silently drop a term.
                }
                used.insert(index)
                indices += Array(words[index].start..<(words[index].start + token.count))
            }
            return (5, 90 - min(60, chars.count - query.count), indices.sorted())
        }
        if let word = words.first(where: { $0.text.hasPrefix(query) }) {
            return (5, 90 - min(60, chars.count - query.count), Array(word.start..<(word.start + query.count)))
        }
        guard allowFuzzy else { return nil }
        if let fuzzy = FuzzyMatcher.match(query: query, candidate: candidate) {
            let acronym = query.count > 1 && fuzzy.matchedIndices.allSatisfy { offset in
                wordStarts.contains(offset)
            }
            let contiguous = zip(fuzzy.matchedIndices, fuzzy.matchedIndices.dropFirst()).allSatisfy { $1 == $0 + 1 }
            // Reject very scattered accidental subsequences while retaining pht → Photos.
            guard acronym || contiguous || fuzzy.score >= 0 else { return nil }
            return (acronym ? 5 : (contiguous ? 4 : 3), min(100, max(-100, fuzzy.score)), fuzzy.matchedIndices)
        }
        // A single insertion, deletion, substitution or adjacent transposition.
        // Only full words of >=4 characters qualify; two-letter queries stay precise.
        if query.count >= 4, query.count <= 64,
           words.contains(where: { oneEditApart(Array(query), Array($0.text)) }) {
            return (2, 0, [])
        }
        return nil
    }

    private static func oneEditApart(_ lhs: [Character], _ rhs: [Character]) -> Bool {
        guard abs(lhs.count - rhs.count) <= 1 else { return false }
        var i = 0
        while i < min(lhs.count, rhs.count), lhs[i] == rhs[i] { i += 1 }
        if i == min(lhs.count, rhs.count) { return true }
        if lhs.count == rhs.count {
            if lhs.dropFirst(i + 1).elementsEqual(rhs.dropFirst(i + 1)) { return true }
            return i + 1 < lhs.count && lhs[i] == rhs[i + 1] && lhs[i + 1] == rhs[i]
                && lhs.dropFirst(i + 2).elementsEqual(rhs.dropFirst(i + 2))
        }
        return lhs.count > rhs.count
            ? lhs.dropFirst(i + 1).elementsEqual(rhs.dropFirst(i))
            : lhs.dropFirst(i).elementsEqual(rhs.dropFirst(i + 1))
    }

    /// Explicit compatibility aliases, keyed by identity rather than display name.
    static func aliases(for bundleIdentifier: String?) -> [String] {
        switch bundleIdentifier {
        case "com.apple.systempreferences": return ["System Preferences", "Settings"]
        case "com.apple.ActivityMonitor": return ["Task Manager", "Process Monitor"]
        case "com.microsoft.VSCode": return ["VS Code", "VSCode", "Code Editor"]
        case "com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox", "com.microsoft.edgemac":
            return ["Web Browser", "Browser"]
        case "com.apple.mail": return ["Email", "Email Client"]
        case "com.apple.DiskUtility": return ["Disk Manager"]
        default: return []
        }
    }
}
