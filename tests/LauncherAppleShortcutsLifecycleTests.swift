import Combine
import Darwin
import Foundation

enum Defaults {
    enum Key<Value> {
        case enableLauncher
        case enableShortcutsLauncher
    }

    struct Change {
        let newValue: Bool
    }

    private static var values: [Key<Bool>: Bool] = [.enableLauncher: true, .enableShortcutsLauncher: false]
    private static let changes = PassthroughSubject<(Key<Bool>, Bool), Never>()

    static subscript(key: Key<Bool>) -> Bool {
        get { values[key] ?? false }
        set {
            values[key] = newValue
            changes.send((key, newValue))
        }
    }

    static func publisher(_ key: Key<Bool>, options: [String]) -> AnyPublisher<Change, Never> {
        changes.filter { $0.0 == key }.map { Change(newValue: $0.1) }.eraseToAnyPublisher()
    }
}

struct LauncherCommand {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    let keywords: [String]
    let run: @MainActor () -> Void
}

@main
enum LauncherAppleShortcutsLifecycleTests {
    @MainActor
    static func main() async {
        let binary = URL(fileURLWithPath: CommandLine.arguments[1])
        let directory = binary.deletingLastPathComponent()
        let pidFile = directory.appendingPathComponent("listing-pid")
        let runFile = directory.appendingPathComponent("ran")
        let fastFile = directory.appendingPathComponent("fast")
        let manager = AppleShortcutsManager(binary: binary)

        manager.loadIfNeeded()
        try? await Task.sleep(for: .milliseconds(80))
        precondition(!FileManager.default.fileExists(atPath: pidFile.path))

        Defaults[.enableShortcutsLauncher] = true
        manager.loadIfNeeded()
        await wait("catalog subprocess started") { FileManager.default.fileExists(atPath: pidFile.path) }
        let pidText = try! String(contentsOf: pidFile, encoding: .utf8)
        let pid = pid_t(pidText.trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(pid > 1 && kill(pid, 0) == 0)
        Defaults[.enableShortcutsLauncher] = false
        await wait("discovery subprocess terminated on disable") { kill(pid, 0) == -1 && errno == ESRCH }
        precondition(manager.names.isEmpty)

        try! Data().write(to: fastFile)
        Defaults[.enableShortcutsLauncher] = true
        manager.loadIfNeeded()
        await wait("fresh catalog after re-enable") { manager.names == ["Fixture Shortcut"] }
        let old = manager.launcherCommands()[0]
        Defaults[.enableLauncher] = false
        precondition(manager.launcherCommands().isEmpty && manager.names.isEmpty)
        old.run()

        Defaults[.enableLauncher] = true
        manager.loadIfNeeded()
        await wait("catalog after Launchpad re-enable") { manager.names.count == 1 }
        old.run()
        try? await Task.sleep(for: .milliseconds(80))
        precondition(!FileManager.default.fileExists(atPath: runFile.path))

        let current = manager.launcherCommands()[0]
        current.run()
        await wait("current shortcut allowed") { FileManager.default.fileExists(atPath: runFile.path) }
        precondition((try? String(contentsOf: runFile, encoding: .utf8)) == "Fixture Shortcut\n")

        try! FileManager.default.removeItem(at: fastFile)
        try! FileManager.default.removeItem(at: pidFile)
        Defaults[.enableShortcutsLauncher] = false
        Defaults[.enableShortcutsLauncher] = true
        manager.loadIfNeeded()
        await wait("catalog subprocess restarted") { FileManager.default.fileExists(atPath: pidFile.path) }
        let closedPanelPID = pid_t((try! String(contentsOf: pidFile, encoding: .utf8))
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        precondition(closedPanelPID > 1)
        manager.cancelLoading()
        await wait("close cancels in-flight discovery") { kill(closedPanelPID, 0) == -1 && errno == ESRCH }
        print("Launchpad Shortcuts disable, rapid re-enable, stale command, and subprocess teardown checks passed")
    }

    @MainActor
    private static func wait(_ message: String, until condition: () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }
}
