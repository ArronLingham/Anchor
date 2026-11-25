import AppKit
import Combine

@main
enum NavigationDisablementTests {
    @MainActor
    static func main() async {
        let manager = SystemNavigationShortcutManager.shared
        let launcher = LauncherPanelManager.shared
        let switcher = AppSwitcherPanelManager.shared
        let tracking = AppSwitcherManager.shared
        let corners = LauncherHotCornerMonitor.shared

        // A stored ⌘Space from the previous migration cannot claim Spotlight
        // when the system replacement is off.
        KeyboardShortcuts.shortcuts[.toggleLauncher] = .init(carbonKeyCode: 49, modifiers: .command)
        KeyboardShortcuts.shortcuts[.appSwitcher] = .init(carbonKeyCode: 48, modifiers: .option)
        KeyboardShortcuts.shortcuts[.appSwitcherReverse] = .init(carbonKeyCode: 48, modifiers: [.control, .shift])
        manager.start()
        corners.setup()
        precondition(!KeyboardShortcuts.registered.contains(.toggleLauncher))
        precondition(KeyboardShortcuts.registered.contains(.appSwitcher))
        precondition(tracking.isTracking)
        manager.invokeRecorded(.appSwitcherReverse)
        precondition(switcher.lastInvocation?.reverse == true && switcher.lastInvocation?.hold == .control)

        Defaults[.enableAppSwitcher] = false
        precondition(!tracking.isTracking && switcher.cancelled == 1)
        precondition(!KeyboardShortcuts.registered.contains(.appSwitcher))
        manager.invokeRecorded(.appSwitcher)
        precondition(switcher.invocations == 1)
        Defaults[.enableAppSwitcher] = true
        precondition(tracking.isTracking && KeyboardShortcuts.registered.contains(.appSwitcher))

        Defaults[.appSwitcherUsesCommandTab] = true
        precondition(manager.handle(.keyDown, event: key(48)) == nil)
        precondition(switcher.lastInvocation?.hold == .command)
        Defaults[.appSwitcherUsesCommandTab] = false
        precondition(switcher.systemCancellations == 1 && tracking.isTracking)
        precondition(manager.handle(.keyDown, event: key(48, repeatPress: true)) == nil)
        precondition(manager.handle(.keyUp, event: key(48)) == nil)
        precondition(manager.handle(.keyDown, event: key(48)) != nil)
        precondition(KeyboardShortcuts.registered.contains(.appSwitcher))

        KeyboardShortcuts.shortcuts[.toggleLauncher] = .init(carbonKeyCode: 49, modifiers: .option)
        manager.recordedShortcutsChanged()
        precondition(KeyboardShortcuts.registered.contains(.toggleLauncher))
        Defaults[.enableLauncher] = false
        precondition(!KeyboardShortcuts.registered.contains(.toggleLauncher) && tracking.isTracking)
        manager.invokeRecorded(.toggleLauncher)
        precondition(launcher.toggles == 0)
        await settle()
        precondition(MouseFixture.monitors.isEmpty && launcher.shows == 0)

        Defaults[.enableLauncher] = true
        await settle()
        let oldMonitor = MouseFixture.monitors.values.first!
        precondition(MouseFixture.monitors.count == 2)
        oldMonitor()
        Defaults[.enableLauncher] = false
        Defaults[.enableLauncher] = true
        // The queued cursor evaluation belongs to the retired monitoring session.
        await settle()
        precondition(MouseFixture.monitors.count == 2 && launcher.shows == 0)
        oldMonitor()
        await settle()
        precondition(launcher.shows == 0)
        MouseFixture.monitors.values.first!()
        await settle()
        precondition(launcher.shows == 1)

        // Exercise the production event handler without posting system input.
        Defaults[.launcherUsesCommandSpace] = true
        precondition(manager.handle(.keyDown, event: key(49)) == nil)
        Defaults[.launcherUsesCommandSpace] = false
        Defaults[.launcherUsesCommandSpace] = true
        precondition(manager.handle(.keyDown, event: key(49, repeatPress: true)) == nil)
        precondition(manager.handle(.keyUp, event: key(49)) == nil)
        await settle()
        precondition(launcher.toggles == 0, "Queued launch from retired preference session")
        precondition(manager.handle(.keyDown, event: key(49, repeatPress: true)) != nil)
        precondition(manager.handle(.keyUp, event: key(49)) != nil)
        precondition(manager.handle(.keyDown, event: key(49)) == nil)
        await settle()
        precondition(launcher.toggles == 1)
        Defaults[.enableShortcuts] = false
        precondition(!tracking.isTracking && KeyboardShortcuts.registered.isEmpty)
        precondition(manager.handle(.keyUp, event: key(49)) == nil)
        precondition(manager.handle(.keyDown, event: key(49)) != nil)
        manager.stop()
        corners.stop()
        precondition(MouseFixture.monitors.isEmpty)
        print("Launchpad corner, native and recorded shortcuts, held-key drain, and Switcher demand checks passed")
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }

    private static func key(_ keyCode: CGKeyCode, repeatPress: Bool = false) -> CGEvent {
        let key = CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: true)!
        key.flags = .maskCommand
        key.setIntegerValueField(.keyboardEventAutorepeat, value: repeatPress ? 1 : 0)
        return key
    }
}

enum Defaults {
    struct Key<Value>: Equatable {
        let name: String
        let initialValue: Value
        static func == (lhs: Self, rhs: Self) -> Bool { lhs.name == rhs.name }
    }

    struct Change<Value> { let newValue: Value }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()

    static subscript<Value>(_ key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.initialValue }
        set {
            values[key.name] = newValue
            changes.send((key.name, newValue))
        }
    }

    static func publisher<Value>(_ key: Key<Value>, options: [String]) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }
            .compactMap { ($0.1 as? Value).map { Change(newValue: $0) } }
            .eraseToAnyPublisher()
    }
}

extension Defaults.Key where Value == Bool {
    static var enableLauncher: Self { .init(name: "launcher", initialValue: true) }
    static var enableAppSwitcher: Self { .init(name: "switcher", initialValue: true) }
    static var enableShortcuts: Self { .init(name: "shortcuts", initialValue: true) }
    static var launcherUsesCommandSpace: Self { .init(name: "spotlight", initialValue: false) }
    static var appSwitcherUsesCommandTab: Self { .init(name: "tab", initialValue: false) }
}

enum LauncherHotCorner { case none, topLeft, topRight, bottomLeft, bottomRight }
extension Defaults.Key where Value == LauncherHotCorner {
    static var launcherHotCorner: Self { .init(name: "corner", initialValue: .topLeft) }
}

enum KeyboardShortcuts {
    enum Name { case toggleLauncher, appSwitcher, appSwitcherReverse }
    struct Shortcut {
        let carbonKeyCode: Int
        let modifiers: NSEvent.ModifierFlags
    }
    static var registered = Set<Name>()
    static var shortcuts: [Name: Shortcut] = [:]
    static func getShortcut(for name: Name) -> Shortcut? { shortcuts[name] }
    static func disable(_ name: Name) { registered.remove(name) }
    static func enable(_ name: Name) { registered.insert(name) }
}

@MainActor
final class LauncherPanelManager {
    static let shared = LauncherPanelManager()
    var shows = 0
    var toggles = 0
    func show() { shows += 1 }
    func toggle() { toggles += 1 }
}

@MainActor
final class AppSwitcherPanelManager {
    static let shared = AppSwitcherPanelManager()
    var invocations = 0
    var lastInvocation: (reverse: Bool, hold: NSEvent.ModifierFlags)?
    var cancelled = 0
    func dismiss(activating: Bool) {
        precondition(!activating)
        cancelled += 1
    }
    var systemCancellations = 0
    func cancelSystemInvocation() { systemCancellations += 1 }
    func invoke(reverse: Bool, holding modifiers: NSEvent.ModifierFlags, systemInvocation: Bool = false) {
        invocations += 1
        lastInvocation = (reverse, modifiers)
    }
}

@MainActor
final class AppSwitcherManager {
    static let shared = AppSwitcherManager()
    var isTracking = false
    let isVisible = true
    func startTracking() { isTracking = true }
    func stopTracking() { isTracking = false }
}

struct DisplayFixture {
    static let screens = [DisplayFixture()]
    let frame = CGRect(x: 0, y: 0, width: 500, height: 500)
}

@MainActor
enum MouseFixture {
    enum Mask { case mouseMoved }
    static let mouseLocation = CGPoint(x: 1, y: 499)
    static var monitors: [UUID: @MainActor () -> Void] = [:]

    static func addGlobalMonitorForEvents(matching: Mask, handler: @escaping (Int) -> Void) -> Any? {
        let id = UUID()
        monitors[id] = { handler(0) }
        return id
    }

    static func addLocalMonitorForEvents(matching: Mask, handler: @escaping (Int) -> Int?) -> Any? {
        let id = UUID()
        monitors[id] = { _ = handler(0) }
        return id
    }

    static func removeMonitor(_ monitor: Any) { monitors.removeValue(forKey: monitor as! UUID) }
}
