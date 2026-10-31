import XCTest
import Carbon.HIToolbox
@testable import AnchorUtilities

final class LegacySnippetMigrationTests: XCTestCase {
    func testMigrationKeepsConflictsAndIsIdempotent() throws {
        let id = UUID()
        let legacy = LegacyAnchorSnippet(id: id, trigger: ";mail", replacement: "Old {date}", immediate: false)
        var advanced = TextSnippet()
        advanced.trigger = ";mail"
        advanced.replacement = "New {{date}}"
        let merged = LegacySnippetMigration.merge([legacy], into: [advanced], legacyWasActive: false, advancedWasActive: true)
        XCTAssertEqual(merged.count, 2)
        XCTAssertTrue(merged[0].enabled)
        XCTAssertFalse(merged[1].enabled)
        XCTAssertEqual(merged[1].legacySourceID, id)
        XCTAssertTrue(merged[1].legacyBehavior)
        XCTAssertEqual(LegacySnippetMigration.merge([legacy], into: merged, legacyWasActive: false, advancedWasActive: true), merged)
        let decoded = try JSONDecoder().decode([TextSnippet].self, from: XCTUnwrap(TextSnippetSupport.encode(merged)))
        XCTAssertEqual(decoded, merged)

        let classicActive = LegacySnippetMigration.merge([legacy], into: [advanced], legacyWasActive: true, advancedWasActive: false)
        XCTAssertFalse(classicActive[0].enabled)
        XCTAssertTrue(classicActive[1].enabled)

        let duplicate = LegacyAnchorSnippet(id: UUID(), trigger: ";mail", replacement: "Second", immediate: false)
        let classicDuplicates = LegacySnippetMigration.merge([legacy, duplicate], into: [], legacyWasActive: true, advancedWasActive: false)
        XCTAssertTrue(classicDuplicates[0].enabled)
        XCTAssertFalse(classicDuplicates[1].enabled)

        let other = LegacyAnchorSnippet(id: UUID(), trigger: ";other", replacement: "text", immediate: true)
        let formerlyOff = LegacySnippetMigration.merge([other], into: [advanced], legacyWasActive: false, advancedWasActive: true)
        XCTAssertFalse(formerlyOff[1].enabled, "An inactive classic list must not start expanding after import")
        let previouslyPaused = LegacySnippetMigration.merge([other], into: [advanced], legacyWasActive: true, advancedWasActive: true)
        XCTAssertFalse(previouslyPaused[1].enabled, "A classic list paused by the advanced engine stays inactive")

        let unfinished = LegacyAnchorSnippet(id: UUID(), trigger: ";x", replacement: "", immediate: true)
        var incomplete = LegacySnippetMigration.merge([unfinished], into: [], legacyWasActive: true, advancedWasActive: false)[0]
        XCTAssertFalse(incomplete.enabled)
        incomplete.enabled = true
        XCTAssertNil(TextSnippetSupport.match(buffer: ";x", expansion: .immediate, snippets: [incomplete]))
    }

    func testImportedVariablesKeepClassicFormatting() {
        var snippet = TextSnippet()
        snippet.legacyBehavior = true
        snippet.replacement = "{date} / {time} / {clipboard}"
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let locale = Locale(identifier: "en_US")
        let formatter = DateFormatter(); formatter.locale = locale; formatter.dateStyle = .long
        let dateString = formatter.string(from: date)
        formatter.dateStyle = .none; formatter.timeStyle = .short
        let expected = "\(dateString) / \(formatter.string(from: date)) / sample"
        XCTAssertTrue(TextSnippetSupport.needsClipboard(snippet))
        XCTAssertEqual(TextSnippetSupport.expand(snippet, date: date, clipboard: "sample", locale: locale), expected)
        XCTAssertTrue(TextSnippetSupport.legacyDelimiters.contains("."))
        XCTAssertFalse(TextSnippetSupport.delimiters.contains("."))
        snippet.trigger = ";test"
        XCTAssertEqual(TextSnippetSupport.matchAfterDelimiter(buffer: ";test", delimiter: ".", snippets: [snippet])?.id, snippet.id)
        XCTAssertNil(TextSnippetSupport.matchAfterDelimiter(buffer: ";test", delimiter: "\t", snippets: [snippet]))
        snippet.legacyBehavior = false
        XCTAssertNil(TextSnippetSupport.matchAfterDelimiter(buffer: ";test", delimiter: ".", snippets: [snippet]))
        XCTAssertNotNil(TextSnippetSupport.matchAfterDelimiter(buffer: ";test", delimiter: " ", snippets: [snippet]))
        var other = snippet
        other.trigger = ";TEST"
        XCTAssertFalse(TextSnippetSupport.conflicts(snippet, other))
        other.ignoresCase = true
        XCTAssertTrue(TextSnippetSupport.conflicts(snippet, other))
        other.id = UUID()
        other.trigger = ";longer"
        XCTAssertEqual(TextSnippetSupport.longerMatch(snippet, other)?.id, other.id)
        XCTAssertEqual(TextSnippetSupport.longerMatch(nil, snippet)?.id, snippet.id)
    }

    func testMigrationRefusesUnreadableStoreAndOversizedTrigger() {
        let domain = "Anchor.LegacySnippetMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        let key = DefaultsKey.textSnippets
        defer { defaults.removePersistentDomain(forName: domain) }
        let corrupt = Data("not-json".utf8)
        defaults.set(corrupt, forKey: key)
        let normal = LegacyAnchorSnippet(id: UUID(), trigger: ";test", replacement: "text", immediate: false)
        XCTAssertFalse(UtilityWorkspace.migrateLegacySnippets([normal], wasEnabled: false, defaults: defaults, domain: domain))
        XCTAssertEqual(defaults.data(forKey: key), corrupt)

        defaults.removeObject(forKey: key)
        let oversized = LegacyAnchorSnippet(id: UUID(), trigger: String(repeating: "a", count: 65), replacement: "text", immediate: true)
        XCTAssertFalse(UtilityWorkspace.migrateLegacySnippets([oversized], wasEnabled: false, defaults: defaults, domain: domain))
        XCTAssertNil(defaults.data(forKey: key))
    }

    func testMigrationPersistsAndRetriesWithoutDuplicates() throws {
        let domain = "Anchor.LegacySnippetMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var existing = TextSnippet(); existing.trigger = ";same"; existing.replacement = "advanced"
        defaults.set(try JSONEncoder().encode([existing]), forKey: DefaultsKey.textSnippets)
        defaults.set(true, forKey: AppFeature.textSnippets.availabilityKey)
        defaults.set(true, forKey: DefaultsKey.textSnippetsEnabled)
        let legacy = LegacyAnchorSnippet(id: UUID(), trigger: ";same", replacement: "classic", immediate: false)
        XCTAssertTrue(UtilityWorkspace.migrateLegacySnippets([legacy], wasEnabled: true, defaults: defaults, domain: domain))
        XCTAssertTrue(UtilityWorkspace.migrateLegacySnippets([legacy], wasEnabled: true, defaults: defaults, domain: domain))
        let reread = UserDefaults(suiteName: domain)!
        let items = try JSONDecoder().decode([TextSnippet].self, from: XCTUnwrap(reread.data(forKey: DefaultsKey.textSnippets)))
        XCTAssertEqual(items.count, 2)
        XCTAssertTrue(items[0].enabled)
        XCTAssertFalse(items[1].enabled)
        XCTAssertEqual(items[1].replacement, "classic")
        XCTAssertEqual(items[1].legacySourceID, legacy.id)
    }

    func testImportingDisabledClassicSnippetsDoesNotActivateTheFeature() {
        let domain = "Anchor.LegacySnippetMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(false, forKey: AppFeature.textSnippets.availabilityKey)
        defaults.set(false, forKey: DefaultsKey.textSnippetsEnabled)
        let legacy = LegacyAnchorSnippet(id: UUID(), trigger: ";x", replacement: "text", immediate: false)
        UserDefaults.standard.register(defaults: [DefaultsKey.textSnippets: [String]()])
        XCTAssertTrue(UtilityWorkspace.migrateLegacySnippets([legacy], wasEnabled: false, defaults: defaults, domain: domain))
        XCTAssertFalse(defaults.bool(forKey: AppFeature.textSnippets.availabilityKey))
        XCTAssertFalse(defaults.bool(forKey: DefaultsKey.textSnippetsEnabled))
        XCTAssertEqual(TextSnippetSupport.decode(defaults.data(forKey: DefaultsKey.textSnippets)).count, 1)
    }

    func testMigrationRefusesToActivateAnInactiveAdvancedList() throws {
        let domain = "Anchor.LegacySnippetMigrationTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: domain)!
        defer { defaults.removePersistentDomain(forName: domain) }
        var advanced = TextSnippet(); advanced.trigger = ";other"; advanced.replacement = "advanced"
        let oldData = try JSONEncoder().encode([advanced])
        defaults.set(oldData, forKey: DefaultsKey.textSnippets)
        defaults.set(false, forKey: AppFeature.textSnippets.availabilityKey)
        defaults.set(false, forKey: DefaultsKey.textSnippetsEnabled)
        let legacy = LegacyAnchorSnippet(id: UUID(), trigger: ";x", replacement: "classic", immediate: false)
        XCTAssertFalse(UtilityWorkspace.migrateLegacySnippets([legacy], wasEnabled: true, defaults: defaults, domain: domain))
        XCTAssertEqual(defaults.data(forKey: DefaultsKey.textSnippets), oldData)
        XCTAssertFalse(defaults.bool(forKey: AppFeature.textSnippets.availabilityKey))
    }

    func testUndoExpiresAfterInputOrFocusChange() {
        var state = LegacySnippetUndoState()
        _ = state.observeInput()
        let generation = state.generation
        state.arm(trigger: ";x", inserted: "example", generation: generation)
        XCTAssertEqual(state.observeInput()?.trigger, ";x")
        XCTAssertNil(state.observeInput())
        state.arm(trigger: ";x", inserted: "late", generation: generation)
        XCTAssertNil(state.observeInput(), "A delayed paste cannot arm undo after newer input")
        let current = state.generation
        state.arm(trigger: ";x", inserted: "example", generation: current)
        state.reset()
        XCTAssertNil(state.observeInput(), "Focus changes disarm undo")
    }

    #if DEBUG
    func testInputHandlerExpandsAndUndoesImportedSnippet() throws {
        try XCTSkipIf(IsSecureEventInputEnabled(), "Secure input is active")
        var posts: [(Int, String, CGKeyCode?)] = []
        let service = TextSnippetService(testPoster: { count, text, trailing, _, _, _, _, completed in
            posts.append((count, text, trailing))
            completed?()
            return true
        })
        var snippet = TextSnippet()
        snippet.trigger = ";check"; snippet.replacement = "Anchor test"; snippet.legacyBehavior = true
        service.configureForTest([snippet])

        func event(_ text: String, key: CGKeyCode = CGKeyCode(kVK_ANSI_A), flags: CGEventFlags = []) -> CGEvent {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: key, keyDown: true)!
            let units = Array(text.utf16)
            if !units.isEmpty {
                units.withUnsafeBufferPointer { event.keyboardSetUnicodeString(stringLength: units.count, unicodeString: $0.baseAddress) }
            }
            event.flags = flags
            return event
        }
        for character in ";check" {
            let input = event(String(character))
            XCTAssertTrue(service.handle(type: .keyDown, event: input) != nil)
        }
        XCTAssertTrue(service.handle(type: .keyDown, event: event(" ", key: CGKeyCode(kVK_Space))) == nil)
        XCTAssertEqual(posts.count, 1)
        XCTAssertEqual(posts[0].0, ";check".count)
        XCTAssertEqual(posts[0].1, "Anchor test")
        XCTAssertNil(posts[0].2, "Classic delimiters are removed, not reinserted")

        XCTAssertTrue(service.handle(type: .keyDown, event: event("", key: CGKeyCode(kVK_Delete))) == nil)
        XCTAssertEqual(posts.count, 2)
        XCTAssertEqual(posts[1].0, "Anchor test".count)
        XCTAssertEqual(posts[1].1, ";check")

        for character in ";check" {
            _ = service.handle(type: .keyDown, event: event(String(character), flags: .maskAlternate))
        }
        _ = service.handle(type: .keyDown, event: event(" ", key: CGKeyCode(kVK_Space)))
        XCTAssertEqual(posts.count, 2, "Option-modified text must not expand a classic snippet")
    }
    #endif
}
