import Foundation

@main
struct LauncherSearchTests {
    static func main() {
        var count = 0
        func expect(_ condition: Bool, _ label: String) {
            count += 1
            guard condition else { fatalError("FAIL: \(label)") }
        }
        func hit(_ query: String, _ name: String, aliases: [String] = [], context: [String] = [], usage: Double = 0) -> LauncherSearch.Match? {
            LauncherSearch.match(query: query, document: .init(name: name, aliases: aliases, context: context), frecency: usage)
        }
        expect(LauncherSearch.customOrderRanks(["a", "b", "a", "c"]) == ["a": 0, "b": 1, "c": 3], "duplicate saved placements keep their first position without crashing")
        expect(hit("mail", "Mail")!.outranks(hit("mail", "Mailbox", usage: 1e100)!), "exact name beats extreme popularity")
        expect(hit("saf", "Safari")!.outranks(hit("saf", "Unsafari", usage: 1e100)!), "prefix beats substring")
        expect(hit("ss", "System Settings")!.outranks(hit("ss", "Chess", usage: 1e100)!), "initials beat substring")
        expect(hit("monitor activity", "Activity Monitor") != nil, "reordered words")
        expect(hit("act mon", "Activity Monitor") != nil, "multiple word prefixes")
        expect(hit("monitor nonsense", "Activity Monitor") == nil, "all query terms required")
        expect(hit("sys system", "System Settings") == nil, "distinct words required")
        expect(hit("  activity\n\tmon  ", "Activity Monitor") != nil, "whitespace normalization")
        expect(hit("safrai", "Safari") != nil, "adjacent transposition")
        expect(hit("safaro", "Safari") != nil, "one substitution")
        expect(hit("safaari", "Safari") != nil, "one insertion")
        expect(hit("safri", "Safari") != nil, "one deletion")
        expect(hit("sxxari", "Safari") == nil, "multiple errors rejected")
        expect(hit("sx", "Safari") == nil, "short typo rejected")
        expect(hit("pht", "Photos") != nil, "existing useful subsequence")
        expect(hit("task manager", "Activity Monitor", aliases: LauncherSearch.aliases(for: "com.apple.ActivityMonitor")) != nil, "identity-based task alias")
        expect(hit("system preferences", "System Settings", aliases: LauncherSearch.aliases(for: "com.apple.systempreferences")) != nil, "legacy name")
        expect(hit("vscode", "Visual Studio Code", aliases: LauncherSearch.aliases(for: "com.microsoft.VSCode")) != nil, "common abbreviation")
        expect(hit("work", "Safari", context: ["Work"]) != nil, "folder retrieval")
        expect(hit("wrk", "Safari", context: ["Work"]) == nil, "context doesn't flood fuzzy results")
        expect(hit("work", "WorkFlow")!.outranks(hit("work", "Safari", context: ["Work"], usage: 1e100)!), "name outranks context")
        let accent = hit("cafe", "Café")!
        expect(accent.indices == [0,1,2,3], "accent folding preserves highlights")
        let expansion = hit("strasse", "Straße")!
        expect(expansion.indices == [0,1,2,3,4,5], "expanding case fold preserves highlights")
        expect(hit("😀 cafe", "😀 Café")!.indices.allSatisfy { $0 < "😀 Café".count }, "emoji display offsets")
        expect(hit("ＳＡＦ", "Safari") != nil, "fullwidth normalization")
        expect(hit("", "Safari") == nil, "empty query delegated to existing home order")
        expect(hit(String(repeating: "x", count: 129), "Safari") == nil, "pasted query bound")
        expect(hit("mail", "Mail", usage: .infinity)!.usage.isFinite, "nonfinite usage")
        expect(hit("mail", "Mail", usage: -10)!.usage == 0, "negative usage")
        expect(hit("saf", "Safari", usage: 10)!.outranks(hit("saf", "Safari")!), "usage adapts equal relevance")
        expect(hit("task", "Activity Monitor", aliases: ["Task Manager"])!.indices.isEmpty, "alias doesn't mis-highlight title")
        expect(hit("work", "Safari", context: ["Work"])!.indices.isEmpty, "folder doesn't mis-highlight title")
        expect(hit("gc", "GoogleChrome")!.tier == 5, "camel-case initials")
        expect(hit("session", "URLSession")!.tier == 5, "acronym-to-word boundary")
        expect(hit("chrome google", "GoogleChrome") != nil, "camel-case multiword search")
        expect(hit("browser", "Safari", aliases: LauncherSearch.aliases(for: "com.apple.Safari")) != nil, "browser task synonym")
        expect(LauncherSearch.aliases(for: "unknown.vendor.app").isEmpty, "unknown app doesn't inherit task keywords")
        expect(hit("code", "Cloud Desktop", aliases: ["Code Editor"])!.tier == 5, "strong alias survives weak name match")
        let folderA = hit("work", "Safari", context: ["Networking", "Work"])!
        let folderB = hit("work", "Safari", context: ["Work", "Networking"])!
        expect(!folderA.outranks(folderB) && !folderB.outranks(folderA), "metadata field order doesn't affect rank")
        expect(hit("cafe", "Cafe\u{301}")!.indices == [0, 1, 2, 3], "decomposed accent display offsets")
        expect(LauncherSearch.precedes(score: hit("ss", "System Settings")!.score, isApp: true, id: "settings",
                                       score: hit("ss", "Show Screenshots")!.score, isApp: false, id: "screenshots"), "app initials outrank equally relevant Shortcuts")
        expect(LauncherSearch.precedes(score: hit("lock", "Lock")!.score, isApp: false, id: "lock-command",
                                       score: hit("lock", "Locksmith")!.score, isApp: true, id: "locksmith"), "exact command beats partial app")
        expect(LauncherSearch.precedes(score: 10_000, isApp: false, id: "quicklink",
                                       score: hit("mail", "Mail")!.score, isApp: true, id: "mail"), "explicit quicklink retains priority")
        expect(LauncherSearch.precedes(score: 5_200, isApp: true, id: "a", score: 5_200, isApp: true, id: "b"), "stable merge tie breaker")
        expect(LauncherSearch.precedes(score: hit("ss", "System Settings")!.score, isApp: true, id: "settings",
                                       score: hit("ss", "Screen Sharing")!.score, isApp: true, id: "screen", rhsSearchOnly: true), "regular app initials beat search-only utility initials")
        expect(LauncherSearch.precedes(score: hit("disk utility", "Disk Utility")!.score, isApp: true, id: "disk", lhsSearchOnly: true,
                                       score: hit("disk utility", "Disk Utility Pro")!.score, isApp: true, id: "pro"), "exact utility still wins over partial regular app")
        let names = ["Safari", "System Settings", "Activity Monitor", "Mail", "Visual Studio Code", "Photos", "Terminal", "Chess"]
        let queries = ["s", "saf", "ss", "act mon", "mail", "pht", "term", "safrai"]
        let fixtures: [(name: String, id: String)] = [
            ("Safari", "com.apple.Safari"), ("System Settings", "com.apple.systempreferences"),
            ("Activity Monitor", "com.apple.ActivityMonitor"), ("Visual Studio Code", "com.microsoft.VSCode"),
            ("Disk Utility", "com.apple.DiskUtility"), ("Mail", "com.apple.mail"),
            ("Photos", "com.apple.Photos"), ("Terminal", "com.apple.Terminal"), ("Chess", "com.apple.Chess")
        ]
        let judgments: [(query: String, name: String)] = [
            ("safari", "Safari"), ("saf", "Safari"), ("safrai", "Safari"),
            ("system preferences", "System Settings"), ("ss", "System Settings"),
            ("monitor activity", "Activity Monitor"), ("act mon", "Activity Monitor"),
            ("task manager", "Activity Monitor"), ("vscode", "Visual Studio Code"),
            ("code editor", "Visual Studio Code"), ("disk manager", "Disk Utility"),
            ("email", "Mail"), ("pht", "Photos"), ("term", "Terminal"), ("chess", "Chess")
        ]
        var oldTopHits = 0
        var newTopHits = 0
        for judgment in judgments {
            let old = fixtures.compactMap { item -> (String, Int)? in
                guard let match = FuzzyMatcher.match(query: judgment.query, candidate: item.name) else { return nil }
                return (item.name, match.score)
            }.sorted { $0.1 > $1.1 }.first?.0
            let new = fixtures.compactMap { item -> (String, LauncherSearch.Match)? in
                guard let match = hit(judgment.query, item.name, aliases: LauncherSearch.aliases(for: item.id)) else { return nil }
                return (item.name, match)
            }.sorted { $0.1.outranks($1.1) }.first?.0
            if old == judgment.name { oldTopHits += 1 }
            if new == judgment.name { newTopHits += 1 }
            expect(new == judgment.name, "curated top result: \(judgment.query)")
        }
        print("Curated 15-query / 9-app top-result evaluation, no usage: previous matcher \(oldTopHits)/15, new ranker \(newTopHits)/15")
        let begin = Date()
        for _ in 0..<40 {
            for query in queries {
                for index in 0..<250 {
                    _ = hit(query, names[index % names.count])
                }
            }
        }
        print("\(count) search checks passed; 250-app query mean \(Date().timeIntervalSince(begin) * 1000 / 320) ms")
    }
}
