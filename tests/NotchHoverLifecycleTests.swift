import Combine
import Foundation

enum Defaults {
    enum Key<Value> {
        case openNotchOnHover, extendHoverArea, enableDynamicIsland
    }
    struct Change { let newValue: Bool }
    private static let changes = PassthroughSubject<(Key<Bool>, Bool), Never>()
    private static var values: [Key<Bool>: Bool] = [:]

    static subscript(key: Key<Bool>) -> Bool {
        get { values[key] ?? true }
        set {
            values[key] = newValue
            changes.send((key, newValue))
        }
    }

    static func publisher(_ key: Key<Bool>, options: [String]) -> AnyPublisher<Change, Never> {
        changes.filter { $0.0 == key }
            .map { Change(newValue: $0.1) }
            .eraseToAnyPublisher()
    }
}

struct FixtureEvent {
    struct ModifierFlags: OptionSet {
        let rawValue: Int
        static let command = Self(rawValue: 1)
        static let option = Self(rawValue: 2)
        static let control = Self(rawValue: 4)
        static let shift = Self(rawValue: 8)
    }

    enum Kind { case mouseMoved, flagsChanged }

    let modifierFlags: ModifierFlags
    static var modifierFlags: ModifierFlags = []
    static var mouseLocation = CGPoint(x: 720, y: 899)
    static var handlers: [UUID: (Kind, (FixtureEvent) -> Void)] = [:]

    static func addGlobalMonitorForEvents(matching kinds: [Kind], handler: @escaping (FixtureEvent) -> Void) -> Any? {
        let id = UUID()
        handlers[id] = (kinds[0], handler)
        return id
    }

    static func removeMonitor(_ monitor: Any) {
        handlers[monitor as! UUID] = nil
    }

    static func handler(for kind: Kind) -> ((FixtureEvent) -> Void)? {
        handlers.values.first { $0.0 == kind }?.1
    }
}

enum BiometricAuthManager {
    static let shared = Self.self
    static func relock() {}
}

enum SystemActivityGate {
    static var locked: Bool?
    static func sessionLockStatus() -> Bool? { locked }
}

@MainActor
final class IslandLockFixture {
    var islandLockGeneration = UUID()
    var pendingRestore: (() -> Void)?
    var hides = 0
    var reveals = 0

    func afterUnlock(_ action: @escaping () -> Void) { pendingRestore = action }
    func hideWindowsForLock() { hides += 1 }
    func restoreWindowsAfterLock() { reveals += 1 }
    func adjustWindowPosition(changeAlpha: Bool) {}
}

@main
enum NotchHoverLifecycleTests {
    @MainActor
    static func main() async {
        let hover = NotchHoverManager.shared
        hover.start()
        precondition(FixtureEvent.handlers.isEmpty)

        hover.setIslandVisible(true)
        precondition(FixtureEvent.handlers.count == 2)
        let retiredMove = FixtureEvent.handler(for: .mouseMoved)!
        retiredMove(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames == ["Built-in"])

        hover.setIslandVisible(false)
        precondition(FixtureEvent.handlers.isEmpty && hover.hoveredScreenNames.isEmpty)
        hover.setIslandVisible(true)
        retiredMove(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames.isEmpty)

        Defaults[.enableDynamicIsland] = false
        FixtureEvent.handler(for: .mouseMoved)?(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames.isEmpty)
        await settle()
        precondition(FixtureEvent.handlers.isEmpty)

        FixtureEvent.modifierFlags = .command
        Defaults[.enableDynamicIsland] = true
        await settle()
        let move = FixtureEvent.handler(for: .mouseMoved)!
        move(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames.isEmpty)
        FixtureEvent.handler(for: .flagsChanged)?(FixtureEvent(modifierFlags: []))
        move(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames == ["Built-in"])

        FixtureEvent.modifierFlags = []
        Defaults[.extendHoverArea] = false
        Defaults[.extendHoverArea] = true
        await settle()
        precondition(FixtureEvent.handlers.count == 2 && hover.hoveredScreenNames.isEmpty)
        move(FixtureEvent(modifierFlags: []))
        precondition(hover.hoveredScreenNames.isEmpty)
        hover.stop()
        precondition(FixtureEvent.handlers.isEmpty)

        let island = IslandLockFixture()
        let event = Notification(name: Notification.Name("test lock transition"))
        island.onScreenLocked(event)
        island.onScreenUnlocked(event)
        island.onScreenLocked(event)
        island.pendingRestore?()
        precondition(island.hides == 2 && island.reveals == 0)
        island.onScreenUnlocked(event)
        SystemActivityGate.locked = true
        island.pendingRestore?()
        precondition(island.reveals == 0)
        SystemActivityGate.locked = false
        island.pendingRestore?()
        precondition(island.reveals == 1)
        print("Hover visibility, retired callbacks, and lock transitions passed")
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(30))
    }
}
