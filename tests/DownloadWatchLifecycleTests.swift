import Combine
import Foundation

enum Defaults {
    enum Key { case enableDownloadListener }
    struct Change { let newValue: Bool }
    private static let changes = PassthroughSubject<Change, Never>()
    private static var enabled = false

    static subscript(key: Key) -> Bool {
        get { enabled }
        set {
            enabled = newValue
            changes.send(Change(newValue: newValue))
        }
    }

    static func publisher(_ key: Key, options: [String]) -> AnyPublisher<Change, Never> {
        changes.eraseToAnyPublisher()
    }
}

struct ExpandedItem {
    enum Kind { case battery, download }
    var show = false
    var type: Kind = .battery
}

@MainActor
final class AnchorViewCoordinator {
    static let shared = AnchorViewCoordinator()
    var expandingView = ExpandedItem()
}

@main
enum DownloadWatchLifecycleTests {
    @MainActor static let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("anchor-download-lifecycle-" + UUID().uuidString)

    @MainActor
    static func main() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = DownloadManager()
        let coordinator = AnchorViewCoordinator.shared
        await settle()
        precondition(watcher.sessionForTest == nil && !watcher.didScanForTest)

        try write("existing.crdownload")
        Defaults[.enableDownloadListener] = true
        await until { watcher.didScanForTest }
        let previous = watcher.sessionForTest!
        precondition(!watcher.isDownloading)

        try write("video.mp4.crdownload")
        await until { watcher.isDownloading }
        precondition(coordinator.expandingView.show && coordinator.expandingView.type == .download)
        try FileManager.default.moveItem(at: directory.appendingPathComponent("video.mp4.crdownload"),
                                         to: directory.appendingPathComponent("video.mp4"))
        await until { watcher.isDownloadCompleted }
        let completion = watcher.timerForTest!
        coordinator.expandingView = ExpandedItem(show: true, type: .battery)

        Defaults[.enableDownloadListener] = false
        watcher.deliverForTest(["queued.download"], allFiles: ["queued.download"], ticket: previous)
        await until { watcher.sessionForTest == nil }
        precondition(!completion.isValid && !watcher.isDownloading && !watcher.isDownloadCompleted)
        precondition(watcher.activeFileIcon == nil)
        precondition(coordinator.expandingView.show && coordinator.expandingView.type == .battery)

        Defaults[.enableDownloadListener] = true
        await until { watcher.didScanForTest }
        let restarted = watcher.sessionForTest!
        Defaults[.enableDownloadListener] = false
        Defaults[.enableDownloadListener] = true
        watcher.deliverForTest(["queued.download"], allFiles: ["queued.download"], ticket: restarted)
        await until { watcher.sessionForTest != restarted && watcher.didScanForTest }
        watcher.deliverForTest(["queued.download"], allFiles: ["queued.download"], ticket: previous)
        precondition(!watcher.isDownloading && coordinator.expandingView.type == .battery)

        try write("fresh.zip.download")
        await until { watcher.isDownloading }
        Defaults[.enableDownloadListener] = false
        await until { watcher.sessionForTest == nil }
        precondition(!watcher.isDownloading && !coordinator.expandingView.show)
        print("Download directory watching, off/on, stale scans and completion teardown passed")
    }

    @MainActor
    private static func write(_ name: String) throws {
        try Data([0]).write(to: directory.appendingPathComponent(name))
    }

    @MainActor
    private static func until(_ satisfied: () -> Bool) async {
        for _ in 0..<200 {
            if satisfied() { return }
            await settle()
        }
        preconditionFailure("Timed out waiting for the isolated Downloads watcher")
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(10))
    }
}
