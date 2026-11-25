import Combine
import CoreGraphics
import Foundation
import os

enum Defaults {
    struct Key<Value> { let name: String; let defaults: Value }
    struct Change<Value> { let newValue: Value }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()

    static subscript<Value>(key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.defaults }
        set { values[key.name] = newValue; changes.send((key.name, newValue)) }
    }

    static func publisher<Value>(_ key: Key<Value>, options: [String]) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }.compactMap { ($0.1 as? Value).map(Change.init) }.eraseToAnyPublisher()
    }
}

extension Defaults.Key where Value == Bool {
    static let enableMenuBarShrink = Self(name: "shrink", defaults: false)
    static let enableShortcuts = Self(name: "shortcuts", defaults: true)
    static let menuBarAlwaysHiddenSection = Self(name: "always hidden", defaults: false)
    static let menuBarExpandOnHover = Self(name: "expand", defaults: false)
}

extension Defaults.Key where Value == Int {
    static let menuBarAutoHideSeconds = Self(name: "rehide", defaults: 5)
}

enum FixtureApplication {
    static let didChangeScreenParametersNotification = Notification.Name("display fixture")
}

struct FixtureScreen {
    static let main: Self? = Self()
    static var screens: [Self] { main.map { [$0] } ?? [] }
    let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
    let visibleFrame = CGRect(x: 0, y: 0, width: 100, height: 80)
}

enum FixtureEvent {
    enum Mask { case mouseMoved }
    static let mouseLocation = CGPoint(x: 20, y: 20)
    static var monitors: [UUID: (Int) -> Void] = [:]
    static func addGlobalMonitorForEvents(matching: [Mask], handler: @escaping (Int) -> Void) -> Any? {
        let token = UUID()
        monitors[token] = handler
        return token
    }
    static func removeMonitor(_ monitor: Any) { monitors[monitor as! UUID] = nil }
}

final class FixtureTimer {
    init(queue: DispatchQueue) {}
    var event: (() -> Void)?
    private(set) var cancelled = false
    func schedule(deadline: DispatchTime, leeway: DispatchTimeInterval) {}
    func setEventHandler(_ handler: @escaping () -> Void) { event = handler }
    func resume() {}
    func cancel() { cancelled = true }
}

@MainActor
final class MenuBarShrinkManager {
    static let shared = MenuBarShrinkManager()
    let activationEpoch = OSAllocatedUnfairLock(initialState: UUID())
    var activation: UUID?
    var enablementSubscription: AnyCancellable?
    var activeSubscriptions = Set<AnyCancellable>()
    var started = false
    var isActive = false
    var isCollapsed = true
    var arrangementState: Bool?
    var installations = 0
    var lengthsApplied = 0
    var rehideMonitor: Any?
    var rehideTimer: FixtureTimer?
    var rehideTimerID: UUID?
    var autoHideGeneration = UUID()

    func deactivate() {
        activation = nil
        isActive = false
        activeSubscriptions.removeAll()
        cancelAutoHide()
    }
    func applyLengths() { lengthsApplied += 1 }
    func syncAlwaysHiddenDivider() {}
    func syncHoverTracking() {}
    func collapse() { isCollapsed = true; cancelAutoHide() }
    func destination(for kind: ArrangementFixture.Section) -> CGPoint? { CGPoint(x: 90, y: 0) }
    func section(for rect: CGRect) -> ArrangementFixture.Section { .hidden }
    func endArrangingItems() {}
}

final class ShortcutFixture {
    enum Name { case toggleMenuBarSection, toggleAlwaysHiddenSection }
    var statuses: [Name: Bool] = [:]
    func updateShortcut(_ name: Name, isEnabled: Bool) { statuses[name] = isEnabled }
}

final class CGEventSource {
    enum State { case hidSystemState }
    init(stateID: State) {}
}

enum CGEventType { case leftMouseDown, leftMouseUp, leftMouseDragged }
enum CGMouseButton { case left }
final class CGEvent {
    enum Flags { case maskCommand }
    enum Tap { case cghidEventTap }
    static var posted: [(CGEventType, CGPoint)] = []
    var flags: Flags?
    let type: CGEventType
    let point: CGPoint

    init?(mouseEventSource: CGEventSource?, mouseType: CGEventType, mouseCursorPosition: CGPoint, mouseButton: CGMouseButton) {
        type = mouseType
        point = mouseCursorPosition
    }

    func post(tap: Tap) { Self.posted.append((type, point)) }
}

@MainActor
final class ArrangementFixture {
    enum Section { case visible, hidden }
    struct Item { let element: Int; let section: Section }
    var operation: Task<Void, Never>?
    var isMoving = false
    var isArranging = true
    var error: String?
    func refresh(session: UUID) async {}
    static func frame(_ element: Int) -> CGRect? { CGRect(x: 0, y: 0, width: 10, height: 10) }
    static func sameDisplay(source: CGPoint, destination: CGPoint) -> Bool { true }
}

@main
enum MenuBarShrinkLifecycleTests {
    @MainActor
    static func main() async {
        let menu = MenuBarShrinkManager.shared
        menu.start()
        let shortcut = ShortcutFixture()
        shortcut.reconcile()
        precondition(shortcut.statuses.values.allSatisfy { !$0 })
        precondition(menu.activeSubscriptions.isEmpty && menu.installations == 0)

        Defaults[.enableMenuBarShrink] = true
        Defaults[.enableMenuBarShrink] = false
        await settle()
        precondition(menu.installations == 0)
        Defaults[.enableMenuBarShrink] = true
        await settle()
        let first = menu.currentSession!
        precondition(menu.activeSubscriptions.count == 4)
        shortcut.reconcile()
        precondition(shortcut.statuses[.toggleMenuBarSection] == true)
        precondition(shortcut.statuses[.toggleAlwaysHiddenSection] == false)

        menu.isCollapsed = false
        menu.scheduleAutoHide()
        let timer = menu.rehideTimer!
        Defaults[.menuBarAutoHideSeconds] = 0
        timer.event?()
        precondition(!menu.isCollapsed)
        await settle()
        precondition(timer.cancelled && FixtureEvent.monitors.isEmpty)

        NotificationCenter.default.post(name: FixtureApplication.didChangeScreenParametersNotification, object: nil)
        Defaults[.enableMenuBarShrink] = false
        Defaults[.enableMenuBarShrink] = true
        precondition(menu.currentSession == nil)
        await settle()
        precondition(menu.currentSession != first && menu.installations == 2)
        try? await Task.sleep(for: .milliseconds(230))
        precondition(menu.lengthsApplied == 0)

        Defaults[.menuBarAlwaysHiddenSection] = true
        shortcut.reconcile()
        precondition(shortcut.statuses[.toggleAlwaysHiddenSection] == true)
        Defaults[.enableShortcuts] = false
        shortcut.reconcile()
        precondition(shortcut.statuses.values.allSatisfy { !$0 })
        Defaults[.enableShortcuts] = true

        let arranger = ArrangementFixture()
        arranger.move(.init(element: 1, section: .visible), to: .hidden)
        for _ in 0..<80 {
            if CGEvent.posted.last?.0 == .leftMouseDragged { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        precondition(CGEvent.posted.first?.0 == .leftMouseDown)
        precondition(CGEvent.posted.last?.0 == .leftMouseDragged)
        let postedCount = CGEvent.posted.count
        let lastDragPoint = CGEvent.posted.last?.1
        Defaults[.enableMenuBarShrink] = false
        await arranger.operation?.value
        precondition(CGEvent.posted.count == postedCount + 1 && CGEvent.posted.last?.0 == .leftMouseUp)
        precondition(lastDragPoint == CGEvent.posted.last?.1 && !arranger.isMoving)
        precondition(menu.activeSubscriptions.isEmpty)
        shortcut.reconcile()
        precondition(shortcut.statuses.values.allSatisfy { !$0 })

        menu.stop()
        Defaults[.enableMenuBarShrink] = true
        await settle()
        precondition(menu.currentSession == nil && menu.installations == 2)
        print("Menu-bar observers, auto-hide, shortcut demand, and cancelled icon drag passed")
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
