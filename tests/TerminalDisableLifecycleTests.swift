import AppKit
import Combine
import Foundation
import os

enum Defaults {
    struct Key<Value> { let name: String; let fallback: Value }
    struct Change<Value> { let newValue: Value }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()

    static subscript<Value>(key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.fallback }
        set { values[key.name] = newValue; changes.send((key.name, newValue)) }
    }

    static func publisher<Value>(_ key: Key<Value>, options: [String]) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }.compactMap { ($0.1 as? Value).map(Change.init) }.eraseToAnyPublisher()
    }
}

extension Defaults.Key where Value == Bool {
    static let enableTerminalFeature = Self(name: "terminal", fallback: false)
}

extension Defaults.Key where Value == String {
    static let terminalShellPath = Self(name: "shell", fallback: "/bin/sh")
}

final class FixtureWindow {
    var isKeyWindow = false
    var firstResponder: TerminalView?
    func makeKeyAndOrderFront(_ sender: Any?) { isKeyWindow = true }
    func makeFirstResponder(_ view: TerminalView) -> Bool { firstResponder = view; return true }
}

final class FixtureObservation {
    private(set) var invalidated = false
    func invalidate() { invalidated = true }
}

final class FixtureApp {
    static let shared = FixtureApp()
    var isActive = false
    var activations = 0
    func activate(ignoringOtherApps: Bool) { activations += 1 }
}

class TerminalView {
    var window: FixtureWindow?
    private(set) var removed = false
    func removeFromSuperview() { removed = true }
}

final class LocalProcessTerminalView: TerminalView {
    final class Process {
        var running = false
        let shellPid: pid_t = 5
    }
    let process = Process()
    var processDelegate: NSObject? = NSObject()
    var starts = 0
    var stops = 0

    func startProcess(executable: String, args: [String], environment: [String], execName: String) {
        process.running = true
        starts += 1
    }
    func terminate() { process.running = false; stops += 1 }
}

enum FixtureReaper {
    static var collected: [pid_t] = []
    static func reapOnExit(_ pid: pid_t) { collected.append(pid) }
}

@MainActor
final class TerminalFixture {
    var terminalView: LocalProcessTerminalView?
    let preferenceEpoch = OSAllocatedUnfairLock(initialState: UUID())
    var mountedEpoch: UUID?
    var preferenceSubscription: AnyCancellable?
    var shellSessionID: UUID?
    var focusRequestID = UUID()
    var isProcessRunning = false
    var terminalTitle = "Terminal"
    var scrollerObservations: [FixtureObservation] = []
    var terminalScroller: NSObject?
    var scheduled: [() -> Void] = []
    let containerView = Container()

    final class Container {
        var window: FixtureWindow?
        var subviews: [TerminalView] = []
    }

    func mount(_ view: LocalProcessTerminalView) {
        terminalView = view
        mountedEpoch = preferenceEpoch.withLock { $0 }
        containerView.subviews = [view, TerminalView()]
    }

    func resignTerminalFirstResponderIfNeeded() {}
    func buildEnvironment() -> [String] { [] }
    func enqueueFocusRetry(_ work: @escaping () -> Void) { scheduled.append(work) }
}

@MainActor
final class TerminalSettingsFixture {
    let terminalManager: TerminalFixture
    var sessionToEnd: UUID?
    var enableTerminalFeature: Bool {
        get { Defaults[.enableTerminalFeature] }
        set { Defaults[.enableTerminalFeature] = newValue }
    }
    init(_ terminal: TerminalFixture) { terminalManager = terminal }
}

@main
enum TerminalDisableLifecycleTests {
    @MainActor
    static func main() async {
        let terminal = TerminalFixture()
        let settings = TerminalSettingsFixture(terminal)
        terminal.observePreferences()

        let disabled = LocalProcessTerminalView()
        terminal.mount(disabled)
        terminal.startShellProcess()
        precondition(disabled.starts == 0)

        settings.terminalEnabledBinding.wrappedValue = true
        let first = LocalProcessTerminalView()
        terminal.mount(first)
        terminal.startShellProcess()
        terminal.startShellProcess()
        precondition(first.starts == 1)
        let firstSession = terminal.runningSession!
        settings.terminalEnabledBinding.wrappedValue = false
        precondition(settings.enableTerminalFeature && settings.sessionToEnd == firstSession)
        precondition(first.process.running, "The confirmation must not stop the shell before approval")

        terminal.restartShell()
        let second = LocalProcessTerminalView()
        terminal.mount(second)
        terminal.startShellProcess()
        terminal.processDidTerminate(from: first)
        terminal.updateTitle("retired", from: first)
        precondition(terminal.isProcessRunning && terminal.terminalTitle == "Terminal")
        settings.confirm(firstSession)
        precondition(settings.enableTerminalFeature)

        terminal.focusTerminalIfPossible()
        let oldFocus = terminal.scheduled.removeFirst()
        terminal.containerView.window = FixtureWindow()
        let oldSubviews = terminal.containerView.subviews
        let observation = FixtureObservation()
        terminal.scrollerObservations.append(observation)
        settings.terminalEnabledBinding.wrappedValue = false
        settings.confirm(settings.sessionToEnd!)
        oldFocus()
        precondition(FixtureApp.shared.activations == 0)
        await settle()
        precondition(second.stops == 1 && second.processDelegate == nil && terminal.terminalView == nil)
        precondition(observation.invalidated && oldSubviews.allSatisfy(\.removed))
        precondition(FixtureReaper.collected.count == 2)

        settings.terminalEnabledBinding.wrappedValue = true
        let third = LocalProcessTerminalView()
        terminal.mount(third)
        terminal.startShellProcess()
        Defaults[.enableTerminalFeature] = false
        Defaults[.enableTerminalFeature] = true
        await settle()
        precondition(third.stops == 1 && terminal.runningSession == nil)
        print("Terminal disable confirmation, resource release, and retired callbacks passed")
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
