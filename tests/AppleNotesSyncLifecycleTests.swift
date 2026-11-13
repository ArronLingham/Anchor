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
    var pendingAppleNotesEdit = false
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
        let queuedSession = AppleNotesSyncManager.shared.captureSession()!
        Defaults[.enableNotes] = false
        Defaults[.enableNotes] = true
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            return NSAppleEventDescriptor(string: "")
        }
        let queuedSync = await AppleNotesSyncManager.shared.sync(localNotes: [note], session: queuedSession)
        let queuedPush = await AppleNotesSyncManager.shared.pushNote(note, session: queuedSession)
        await AppleNotesSyncManager.shared.deleteRemoteNote(appleNotesId: "fixture", session: queuedSession)
        check(queuedSync == nil && queuedPush == nil, "queued work from a prior session is rejected")
        check(scripts.isEmpty, "queued sync, push and delete start no scripts after off and on")

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
            Defaults[.enableNotes] = false
            Defaults[.enableNotes] = true
            return NSAppleEventDescriptor(string: "")
        }
        let staleSession = await AppleNotesSyncManager.shared.sync(localNotes: [note])
        check(staleSession == nil, "off and on during fetch invalidates the earlier session")
        check(scripts.count == 1, "old session starts no write after re-enable")

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
        Defaults[.enableNotes] = true
        var linked = note
        linked.appleNotesId = "rich-note-id"
        Defaults[.savedNotes] = [linked]
        scripts = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            return NSAppleEventDescriptor(string: "")
        }
        let protectedPush = await AppleNotesSyncManager.shared.pushNote(linked)
        check(protectedPush == nil, "linked remote note is not overwritten by a plain-text edit")
        check(scripts.isEmpty, "protecting linked content sends no update script")
        check(Defaults[.savedNotes] == [linked], "blocked remote update preserves local note")
        check(AppleNotesSyncManager.shared.lastError != nil, "blocked remote update reports its limitation")
        scripts = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            let remote = ["rich-note-id", "Remote", "1", "2", "Remote text", ""].joined(separator: "\u{241F}")
            return NSAppleEventDescriptor(string: remote)
        }
        let protectedSync = await AppleNotesSyncManager.shared.sync(localNotes: [linked])
        check(protectedSync == nil, "sync does not overwrite a linked remote body")
        check(scripts.count == 1 && scripts[0].contains("plaintext of n"), "sync only reads the remote note")
        check(Defaults[.savedNotes] == [linked], "blocked sync preserves the local edit and link")
        check(AppleNotesSyncManager.shared.lastError != nil, "blocked sync reports its limitation")

        linked.pendingAppleNotesEdit = true
        linked.content = "unsent local edit"
        Defaults[.savedNotes] = [linked]
        scripts = []
        AppleScriptHelper.handler = { script in
            scripts.append(script)
            let remote = ["rich-note-id", "Remote", "1", "9999999999", "New remote text", ""].joined(separator: "\u{241F}")
            return NSAppleEventDescriptor(string: remote)
        }
        let conflictingSync = await AppleNotesSyncManager.shared.sync(localNotes: [linked])
        check(conflictingSync == nil, "newer remote data cannot replace a pending local edit")
        check(Defaults[.savedNotes] == [linked], "pending local edit and link remain intact")
        check(AppleNotesSyncManager.shared.lastError != nil, "pending local edit reports its protection")

        var creating = note
        creating.id = UUID()
        Defaults[.savedNotes] = [creating]
        AppleScriptHelper.handler = { script in
            if script.contains("make new note at folder") {
                var edited = creating
                edited.content = "edited during creation"
                Defaults[.savedNotes] = [edited]
                return NSAppleEventDescriptor(string: "created-note-id")
            }
            return NSAppleEventDescriptor(string: "")
        }
        _ = await AppleNotesSyncManager.shared.pushNote(creating)
        check(Defaults[.savedNotes].first?.appleNotesId == "created-note-id", "creation remembers the acknowledged remote ID")
        check(Defaults[.savedNotes].first?.pendingAppleNotesEdit == true, "edit during creation stays marked as unsent")
        check(Defaults[.savedNotes].first?.content == "edited during creation", "edit during creation survives")

        Defaults[.savedNotes] = []
        AppleScriptHelper.handler = { _ in NSAppleEventDescriptor(string: "") }
        let completed = await AppleNotesSyncManager.shared.sync(localNotes: [])
        check(completed != nil, "enabled empty sync completes")
        if let completed {
            check(AppleNotesSyncManager.shared.acceptsSession(completed.session), "completed session initially accepted")
            Defaults[.enableAppleNotesSync] = false
            Defaults[.enableAppleNotesSync] = true
            check(!AppleNotesSyncManager.shared.acceptsSession(completed.session), "old result rejected after sync off and on")
        }
        print("Apple Notes lifecycle: \(failures == 0 ? "passed" : "failed")")
        if failures != 0 { exit(1) }
    }
}
