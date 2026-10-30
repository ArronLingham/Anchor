import Foundation
import Dispatch

@main struct ApplicationDirectoryMonitorTests {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstEvent = DispatchSemaphore(value: 0)
        let oldMonitor = ApplicationDirectoryMonitor(directories: [root], debounceInterval: 0.05) {
            firstEvent.signal()
        }
        try Data("one".utf8).write(to: root.appendingPathComponent("one"))
        precondition(firstEvent.wait(timeout: .now() + 5) == .success, "active monitor missed a change")
        oldMonitor.stop()
        try Data("two".utf8).write(to: root.appendingPathComponent("two"))
        precondition(firstEvent.wait(timeout: .now() + 0.5) == .timedOut, "stopped monitor delivered a change")

        let resumedEvent = DispatchSemaphore(value: 0)
        let resumedMonitor = ApplicationDirectoryMonitor(directories: [root], debounceInterval: 0.05) {
            resumedEvent.signal()
        }
        try Data("three".utf8).write(to: root.appendingPathComponent("three"))
        precondition(resumedEvent.wait(timeout: .now() + 5) == .success, "restarted monitor missed a change")
        resumedMonitor.stop()
        print("Passed: active, stopped, and restarted application-directory monitoring.")
    }
}
