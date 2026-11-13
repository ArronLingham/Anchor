import AppKit
import Defaults
import Foundation

struct NoteItem: Identifiable, Equatable {
    var id = UUID()
    var title: String
    var content: String
    var creationDate: Date
    var modificationDate: Date
    var colorIndex: Int
    var isPinned = false
    var appleNotesId: String?
}

extension Defaults.Key where Value == [NoteItem] {
    static var savedNotes: Self { .init("savedNotes", default: []) }
}
extension Defaults.Key where Value == Date? {
    static var appleNotesLastSyncDate: Self { .init("lastSync", default: nil) }
}

@MainActor
enum AppleScriptHelper {
    static var handler: ((String) async throws -> NSAppleEventDescriptor?)!
    static func execute(_ script: String) async throws -> NSAppleEventDescriptor? {
        try await handler(script)
    }
}

@main
struct AppleNotesSyncLifecycleTests {
    @MainActor static func main() async {
        var failures = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) {
            if !value() { failures += 1; print("FAIL: \(label)") }
        }
        Defaults[.enableNotes] = true
        Defaults[.enableAppleNotesSync] = true
        let note = NoteItem(title: "Fixture", content: "local", creationDate: Date(), modificationDate: Date(), colorIndex: 0)
        Defaults[.savedNotes] = [note]
        var scripts: [String] = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            Defaults[.enableNotes] = false
            return NSAppleEventDescriptor(string: "")
        }
        let stoppedAfterFetch = await AppleNotesSyncManager.shared.sync(localNotes: [note])
        check(stoppedAfterFetch == nil, "off during fetch returns no snapshot")
        check(scripts.count == 1, "off during fetch starts no later remote operation")
        check(Defaults[.savedNotes] == [note], "off during fetch preserves local data")

        Defaults[.enableNotes] = true
        scripts = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            var edited = note
            edited.content = "new local edit"
            Defaults[.savedNotes] = [edited]
            return NSAppleEventDescriptor(string: "")
        }
        _ = await AppleNotesSyncManager.shared.sync(localNotes: [note])
        check(!scripts.contains(where: { $0.contains("make new note at folder") }), "a stale local snapshot is not pushed")
        check(Defaults[.savedNotes].first?.content == "new local edit", "a local edit during fetch survives")

        Defaults[.savedNotes] = [note]
        Defaults[.enableNotes] = true
        scripts = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            if script.contains("set _folder to folder") { Defaults[.enableNotes] = false }
            return NSAppleEventDescriptor(string: "")
        }
        let stoppedAfterFolder = await AppleNotesSyncManager.shared.sync(localNotes: [note])
        check(stoppedAfterFolder == nil, "off during folder setup returns no snapshot")
        check(!scripts.contains(where: { $0.contains("make new note at folder") }), "off during folder setup starts no note creation")

        Defaults[.enableNotes] = true
        scripts = []
        var second = note
        second.id = UUID()
        second.content = "second local"
        Defaults[.savedNotes] = [note, second]
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            if script.contains("make new note at folder") {
                Defaults[.enableNotes] = false
                return NSAppleEventDescriptor(string: "remote-fixture-id")
            }
            return NSAppleEventDescriptor(string: "")
        }
        let stoppedAfterCreate = await AppleNotesSyncManager.shared.sync(localNotes: [note, second])
        check(stoppedAfterCreate == nil, "off after creation returns no stale snapshot")
        check(Defaults[.savedNotes].first?.appleNotesId == "remote-fixture-id", "completed creation retains its remote ID")
        check(Defaults[.savedNotes].first?.content == "local", "acknowledging creation preserves local content")
        check(scripts.filter { $0.contains("make new note at folder") }.count == 1, "off after first creation prevents a second creation")
        check(Defaults[.savedNotes].last?.appleNotesId == nil, "unstarted creation leaves the second note unlinked")
        print("Apple Notes lifecycle: \(failures == 0 ? "passed" : "failed")")
        if failures != 0 { exit(1) }
    }
}
