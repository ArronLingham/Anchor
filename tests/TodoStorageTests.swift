import Foundation
import Darwin

@main
struct TodoStorageTests {
    static var passed = 0
    static var failed = 0
    static func check(_ name: String, _ condition: @autoclosure () throws -> Bool) {
        do {
            if try condition() { passed += 1 }
            else { failed += 1; print("FAIL: \(name)") }
        } catch { failed += 1; print("FAIL: \(name): \(error)") }
    }
    static func main() throws {
        if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--crash-writer" {
            let store = TodoFileStore(root: URL(fileURLWithPath: CommandLine.arguments[2]))
            _ = try store.load()
            var items: [TodoItem] = []
            for index in 1...1000 {
                items.append(TodoItem(title: "Crash task \(index)"))
                try store.save(items)
                FileHandle.standardOutput.write(Data("\(index)\n".utf8))
            }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = TodoFileStore(root: root)
        check("new installation distinguished from empty", try store.load() == nil)
        let due = Date(timeIntervalSinceReferenceDate: 800_000_000.125)
        let task = TodoItem(title: "Keep \"my\" tasks 🧪", createdAt: due.addingTimeInterval(-400), dueDate: due, priority: 3)
        try store.save([task])
        check("all fields round trip including date precision", try TodoFileStore(root: root).load() == [task])
        check("journal is durable and decodable", try TodoFileStore.decode(Data(contentsOf: store.journalURL)).items == [task])
        var edited = task
        edited.title = "Edited"
        try store.save([edited])
        check("previous revision backed up", try TodoFileStore.decode(Data(contentsOf: store.backupURL)).items == [task])
        check("daily snapshot records pre-edit state", try TodoFileStore.decode(Data(contentsOf: store.availableSnapshots()[0])).items == [task])
        edited.isDone = true
        edited.completedAt = due
        try store.save([edited])
        check("completion survives restart", try TodoFileStore(root: root).load() == [edited])
        check("daily snapshot not overwritten by later edits", try TodoFileStore.decode(Data(contentsOf: store.availableSnapshots()[0])).items == [task])
        try store.save([])
        check("empty list not replaced by older backup", try TodoFileStore(root: root).load() == [])
        try Data("broken primary".utf8).write(to: store.primaryURL)
        check("empty journal is valid recovery", try TodoFileStore(root: root).load() == [])
        try Data("broken journal".utf8).write(to: store.journalURL)
        check("corrupt primary and journal fall back to valid backup", try TodoFileStore(root: root).load() == [edited])
        try Data("broken backup".utf8).write(to: store.backupURL)
        check("rolling snapshot is final recovery layer", try TodoFileStore(root: root).load() == [task])
        for url in store.availableSnapshots() { try Data("broken snapshot".utf8).write(to: url) }
        do { _ = try TodoFileStore(root: root).load(); check("all corrupt must throw", false) }
        catch { check("all corrupt must throw", true) }
        check("corrupt evidence preserved", try String(contentsOf: store.primaryURL, encoding: .utf8) == "broken primary")

        let automaticRoot = root.appendingPathComponent("automatic-recovery")
        let automatic = TodoFileStore(root: automaticRoot)
        try automatic.save([task])
        try Data("damaged source evidence".utf8).write(to: automatic.primaryURL)
        let automaticRestart = TodoFileStore(root: automaticRoot)
        _ = try automaticRestart.load()
        try automaticRestart.save([edited])
        let recoveryFolders = try FileManager.default.contentsOfDirectory(at: automaticRoot, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("TodoRecovery-") }
        check("normal save after automatic fallback retains corrupt original", try recoveryFolders.contains {
            try String(contentsOf: $0.appendingPathComponent("todos.json"), encoding: .utf8) == "damaged source evidence"
        })

        let crashRoot = root.appendingPathComponent("crash-process")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--crash-writer", crashRoot.path]
        let output = Pipe()
        child.standardOutput = output
        try child.run()
        let acknowledged = String(data: output.fileHandleForReading.availableData, encoding: .utf8)!
            .split(separator: "\n").compactMap { Int($0) }.max() ?? 0
        usleep(1000)
        kill(child.processIdentifier, SIGKILL)
        child.waitUntilExit()
        let afterKill = try TodoFileStore(root: crashRoot).load() ?? []
        check("SIGKILL retains every acknowledged task", acknowledged > 0 && afterKill.count >= acknowledged)
        check("SIGKILL recovery contains a complete generation", afterKill.enumerated().allSatisfy { $0.element.title == "Crash task \($0.offset + 1)" })

        let legacyRoot = root.appendingPathComponent("legacy")
        try FileManager.default.createDirectory(at: legacyRoot, withIntermediateDirectories: true)
        let legacy = TodoFileStore(root: legacyRoot)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var wholeSecondTask = task
        wholeSecondTask.dueDate = Date(timeIntervalSinceReferenceDate: 800_000_000)
        wholeSecondTask.createdAt = Date(timeIntervalSinceReferenceDate: 799_999_000)
        try encoder.encode([wholeSecondTask]).write(to: legacy.primaryURL)
        check("Gemini ISO-8601 files preserve dates", try legacy.load() == [wholeSecondTask])
        check("Defaults numeric dates supported", try JSONDecoder().decode(TodoItem.self, from: JSONEncoder().encode(task)) == task)
        try Data("[]".utf8).write(to: legacy.primaryURL)
        try encoder.encode([task]).write(to: legacy.backupURL)
        check("legacy empty primary wins over populated backup", try TodoFileStore(root: legacyRoot).load() == [])
        try Data("{\"version\":99,\"revision\":1,\"items\":[]}".utf8).write(to: legacy.primaryURL)
        do { _ = try legacy.load(); check("future version protected", false) }
        catch { check("future version protected", true) }
        let badDate = Data("[{\"title\":\"test\",\"dueDate\":\"nonsense\"}]".utf8)
        do { _ = try TodoFileStore.decode(badDate); check("bad date cannot silently disappear", false) }
        catch { check("bad date cannot silently disappear", true) }
        let malformed = Data("[{\"title\":\"survivor\"},42,{},null]".utf8)
        check("explicit salvage recovers records individually", TodoItem.safeDecodeList(from: malformed).map(\.title) == ["survivor"])
        let duplicates = try JSONEncoder().encode([task, task])
        do { _ = try TodoFileStore.decode(duplicates); check("duplicate IDs rejected", false) }
        catch { check("duplicate IDs rejected", true) }

        let interruptedRoot = root.appendingPathComponent("interrupted")
        let interrupted = TodoFileStore(root: interruptedRoot)
        try interrupted.save([task])
        // Simulate termination after the newer journal reached disk, before the
        // primary replacement (the old primary is still intact).
        let newer = TodoFileStore.Snapshot(version: 1, revision: 2, items: [edited])
        try JSONEncoder().encode(newer).write(to: interrupted.journalURL, options: .atomic)
        check("journal recovers write interrupted before primary replacement", try TodoFileStore(root: interruptedRoot).load() == [edited])
        let restarted = TodoFileStore(root: interruptedRoot)
        _ = try restarted.load()
        try restarted.save([edited])
        check("revision advances after journal recovery", try TodoFileStore.decode(Data(contentsOf: restarted.primaryURL)).revision == 3)
        let stale = TodoFileStore(root: interruptedRoot)
        _ = try stale.load()
        try restarted.save([])
        do { try stale.save([task]); check("stale second process cannot overwrite edits", false) }
        catch { check("stale second process cannot overwrite edits", true) }
        check("second writer failure preserves latest data", try TodoFileStore(root: interruptedRoot).load() == [])
        let impossible = root.appendingPathComponent("not-a-directory")
        try Data().write(to: impossible)
        do { try TodoFileStore(root: impossible).save([task]); check("disk error reported", false) }
        catch { check("disk error reported", true) }

        var phone = task
        phone.isDone = true; phone.completedAt = due
        phone.dueDate = due.addingTimeInterval(100)
        var mac = task
        mac.priority = 1
        let merged = TodoSyncMerge.merge(local: mac, remote: phone, baseline: task)
        check("phone completion imported", merged.isDone && merged.completedAt == due)
        check("independent Mac priority retained", merged.priority == 1)
        check("phone date imported", merged.dueDate == phone.dueDate)
        check("merge preserves local identity and creation date", merged.id == mac.id && merged.createdAt == mac.createdAt)
        mac.title = "Mac edit"; phone.title = "Phone edit"
        check("same-field conflict keeps local edit", TodoSyncMerge.merge(local: mac, remote: phone, baseline: task).title == "Mac edit")
        check("missing baseline cannot overwrite local data", TodoSyncMerge.merge(local: mac, remote: phone, baseline: nil) == mac)
        var doneBase = task; doneBase.isDone = true; doneBase.completedAt = due
        check("phone uncompletion imported", !TodoSyncMerge.merge(local: doneBase, remote: task, baseline: doneBase).isDone)

        let key = task.id.uuidString
        let checkpoint = TodoSyncMerge.Checkpoint(calendarID: "list", baseline: [key: task], remoteIDs: [key: "remote-1"])
        let emptyCheckpoint = TodoSyncMerge.Checkpoint(calendarID: "list")
        let remoteRecord = TodoSyncMerge.Remote(id: "remote-1", item: task)
        let imported = try TodoSyncMerge.plan(local: [], remote: [remoteRecord], checkpoint: emptyCheckpoint)
        check("phone addition imported once", imported.items == [task] && imported.writes.isEmpty)
        let exported = try TodoSyncMerge.plan(local: [task], remote: [], checkpoint: emptyCheckpoint)
        check("Mac addition exported once", exported.writes == [task] && exported.items == [task])
        let stable = try TodoSyncMerge.plan(local: [task], remote: [remoteRecord], checkpoint: checkpoint)
        check("unchanged sync produces no outbound writes", stable.writes.isEmpty && stable.deletes.isEmpty)
        let missingRemote = try TodoSyncMerge.plan(local: [task], remote: [], checkpoint: checkpoint)
        check("missing iCloud record cannot delete local task", missingRemote.items == [task] && missingRemote.writes.isEmpty)
        check("missing record retains merge baseline", missingRemote.checkpoint.baseline[key] == task)
        let deletion = try TodoSyncMerge.plan(local: [], remote: [remoteRecord], checkpoint: checkpoint)
        check("explicit local deletion propagated", deletion.items.isEmpty && deletion.deletes == ["remote-1"])
        let phoneEdited = TodoSyncMerge.Remote(id: "remote-1", item: phone)
        let deletionConflict = try TodoSyncMerge.plan(local: [], remote: [phoneEdited], checkpoint: checkpoint)
        check("phone edits survive conflicting local deletion", deletionConflict.items == [phone] && deletionConflict.deletes.isEmpty)
        let missingDeleted = try TodoSyncMerge.plan(local: [], remote: [], checkpoint: checkpoint)
        check("local deletion knowledge survives missing remote record", missingDeleted.checkpoint.baseline[key] == task)
        let restoredRemote = try TodoSyncMerge.plan(local: [], remote: [remoteRecord], checkpoint: missingDeleted.checkpoint)
        check("returning deleted record is not resurrected", restoredRemote.items.isEmpty && restoredRemote.deletes == ["remote-1"])
        let completedFromPhone = try TodoSyncMerge.plan(local: [task], remote: [phoneEdited], checkpoint: checkpoint)
        check("phone completion updates saved local list", completedFromPhone.items.first?.isDone == true)
        do {
            _ = try TodoSyncMerge.plan(local: [task], remote: [remoteRecord, remoteRecord], checkpoint: checkpoint)
            check("duplicate remote task links rejected", false)
        } catch { check("duplicate remote task links rejected", true) }
        try store.restore([task])
        check("explicit restore replaces corrupt files", try TodoFileStore(root: root).load() == [task])
        check("explicit restore preserves damaged originals", try FileManager.default.contentsOfDirectory(atPath: root.path).contains(where: { $0.hasPrefix("TodoRecovery-") }))

        for size in [CGSize(width: 680, height: 300), CGSize(width: 1260, height: 700),
                     CGSize(width: 2300, height: 1300), CGSize(width: 700, height: 1800),
                     CGSize(width: 3000, height: 500)] {
            let layout = LauncherGridLayout.calculate(for: size)
            check("positive grid at \(size)", layout.columns > 0 && layout.rows > 0)
            check("cells fit width at \(size)", CGFloat(layout.columns) * 115 <= size.width - 40)
            check("cells fit height at \(size)", CGFloat(layout.rows) * 114 <= size.height - 68)
        }
        let small = LauncherGridLayout.calculate(for: CGSize(width: 180, height: 170))
        check("small containers do not use unrelated screen dimensions", small.columns == 1 && small.rows == 1)
        print("\(passed)/\(passed + failed) persistence, sync merge and adaptive-layout checks passed")
        if failed > 0 { exit(1) }
    }
}
