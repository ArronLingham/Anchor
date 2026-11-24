import Foundation

enum DefaultsKey { static let finderCutPasteEnabled = "finderCutPasteEnabled" }

final class FinderFixture {
    struct Mark { let url: URL }
    struct MoveResult: Equatable { let moved: Int; let failed: Int }
    final class Pasteboard {
        var changeCount = 3
        func clearContents() { changeCount += 1 }
    }

    static var wanted = true
    static func shortcutWanted(_ key: String) -> Bool { wanted }
    let pasteboard = Pasteboard()
    var operationGeneration = 21
    var discardMarksAfterMove = false
    var cutPasteEnabled = true
    var moveInProgress = true
    var moveProgress: Int? = 1
    var markedChangeCount = 3
    var resultDismiss: DispatchWorkItem?
    var lastResult: MoveResult?
    var marked: [Mark] = []
    var scheduledDismiss = 0
    var imagePasteInProgress = false
    var beepCount = 0
    var normalPasteTargets: [pid_t] = []
    func refreshPanel() {}
    func scheduleResultDismiss() { scheduledDismiss += 1 }
    func postNormalPaste(ifStillFrontmost targetPID: pid_t) { normalPasteTargets.append(targetPID) }

    func beginMove(_ urls: [URL]) {
        marked = urls.map { Mark(url: $0) }
        markedChangeCount = pasteboard.changeCount
        moveInProgress = true
        moveProgress = 1
    }
}

@main
enum FinderCutPasteDisableLifecycleTests {
    static func main() throws {
        let first = URL(fileURLWithPath: "/tmp/anchor-first")
        let second = URL(fileURLWithPath: "/tmp/anchor-second")
        let fixture = FinderFixture()
        fixture.beginMove([first, second])
        fixture.cutPasteEnabled = false
        fixture.resetCutState(clearOwnedPasteboard: false)
        precondition(fixture.operationGeneration == 21 && fixture.moveInProgress && fixture.moveProgress == 1)
        precondition(fixture.marked.count == 2 && fixture.discardMarksAfterMove)
        fixture.cutPasteEnabled = true
        fixture.finishPaste(generation: 21, moved: 1, failed: 1, stillCut: [second])
        precondition(fixture.operationGeneration == 22 && !fixture.moveInProgress && fixture.moveProgress == nil)
        precondition(fixture.marked.isEmpty && fixture.pasteboard.changeCount == 3)
        precondition(fixture.lastResult == .init(moved: 1, failed: 1) && fixture.scheduledDismiss == 1)

        fixture.beginMove([first, second])
        fixture.finishPaste(generation: 22, moved: 1, failed: 1, stillCut: [second])
        precondition(fixture.marked.map(\.url) == [second])
        fixture.beginMove([first, second])
        fixture.pasteboard.changeCount += 1
        fixture.finishPaste(generation: 23, moved: 1, failed: 1, stillCut: [second])
        precondition(fixture.marked.isEmpty && fixture.pasteboard.changeCount == 4)

        fixture.imagePasteInProgress = true
        fixture.finishImagePaste(targetPID: 10, expectedChangeCount: 4, result: .notImage, accepts: { false })
        precondition(!fixture.imagePasteInProgress && fixture.normalPasteTargets.isEmpty)
        fixture.finishImagePaste(targetPID: 10, expectedChangeCount: 4, result: .failed, accepts: { false })
        precondition(fixture.beepCount == 0)
        fixture.finishImagePaste(targetPID: 10, expectedChangeCount: 3, result: .notImage, accepts: { true })
        precondition(fixture.normalPasteTargets.isEmpty)
        fixture.finishImagePaste(targetPID: 10, expectedChangeCount: 4, result: .notImage, accepts: { true })
        precondition(fixture.normalPasteTargets == [10])

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("picture.png")
        let data = Data([1, 2, 3])
        var checks = 0
        let cancelled = try FinderFixture.publishImage(data, to: destination) {
            checks += 1
            return checks == 1
        }
        precondition(!cancelled)
        let afterCancellation = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(afterCancellation.isEmpty)

        let concurrent = Data([4, 5, 6])
        do {
            _ = try FinderFixture.publishImage(data, to: destination) {
                if !FileManager.default.fileExists(atPath: destination.path) {
                    // Simulate a different writer creating the final name
                    // after the bytes have been staged.
                    let staged = try! FileManager.default.contentsOfDirectory(atPath: directory.path)
                    if !staged.isEmpty { try! concurrent.write(to: destination) }
                }
                return true
            }
            preconditionFailure("A competing file must be preserved")
        } catch CocoaError.fileWriteFileExists {}
        let preserved = try Data(contentsOf: destination)
        precondition(preserved == concurrent)
        let afterCollision = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        precondition(afterCollision == ["picture.png"])
        try FileManager.default.removeItem(at: destination)
        let published = try FinderFixture.publishImage(data, to: destination, shouldPublish: { true })
        let saved = try Data(contentsOf: destination)
        precondition(published && saved == data)
        print("Finder move tracking, clipboard revisions and image publication checks passed")
    }
}
