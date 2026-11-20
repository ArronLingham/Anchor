import AppKit

enum DockClickAction { case minimize, restore, hide, cycleWindows, passThrough }
enum DockClickSupport {
    static func isDragMovement(from origin: CGPoint, to point: CGPoint) -> Bool { origin != point }
}
enum AppFeature {
    case dockClick
    static var available = true
    var isAvailable: Bool { Self.available }
}
enum DefaultsKey {
    static let dockClickMinimize = "minimize"
    static let dockClickHide = "hide"
    static let dockClickCycleWindows = "cycle"
}
final class FixturePreferences {
    var enabled = Set([DefaultsKey.dockClickMinimize])
    func bool(forKey key: String) -> Bool { enabled.contains(key) }
}
enum UtilityPreferences { static let standard = FixturePreferences() }
final class SessionActivity {
    static let shared = SessionActivity()
    var isActive = true
}
final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    func prepareOwnership() {}
}
func AXIsProcessTrusted() -> Bool { true }

final class DockClickFixture {
    struct Click {
        let action: DockClickAction
        let origin = CGPoint.zero
    }
    struct Record {
        let kind: DockClickAction
        let time: CFAbsoluteTime
    }
    static let syntheticEventMarker: Int64 = 1
    var tap: Int? = 1
    var pendingClick: Click?
    var discardingPress = false
    var drainOnly = false
    let minimizeWorkGate = ClipboardPresentationGate()
    var lastAction: [pid_t: Record] = [:]
    var minimizeZOrder: [pid_t: [CGWindowID]] = [:]
    var replayedDown = false
    var committed = 0

    func start() { tap = 1 }
    func stop() {
        tap = nil
        drainOnly = false
        discardingPress = false
        pendingClick = nil
        clearActions()
    }
    func clearActions() {
        minimizeWorkGate.update(available: false)
        lastAction = [:]
        minimizeZOrder = [:]
    }
    func cancelSweeps() {}
    func commit(_ click: Click) { committed += 1 }
}

@main
enum DockClickDisableLifecycleTests {
    static func main() {
        let fixture = DockClickFixture()
        let drag = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDragged,
                           mouseCursorPosition: CGPoint(x: 40, y: 0), mouseButton: .left)!
        let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                         mouseCursorPosition: .zero, mouseButton: .left)!
        fixture.pendingClick = .init(action: .minimize)
        fixture.lastAction[42] = .init(kind: .minimize, time: 10)
        let oldWorker = fixture.minimizeWorkCheck()!
        precondition(oldWorker())
        precondition(fixture.acceptsDeferredAction(.minimize, pid: 42, at: 10))
        AppFeature.available = false
        fixture.syncWithPreferences()
        precondition(fixture.drainOnly && fixture.tap != nil && fixture.pendingClick == nil)
        precondition(fixture.handleDragged(drag) == nil && !fixture.replayedDown)
        precondition(fixture.handleUp(up) == nil && fixture.tap == nil && fixture.committed == 0)
        precondition(fixture.handleUp(up) != nil)

        AppFeature.available = true
        fixture.syncWithPreferences()
        precondition(!oldWorker() && fixture.minimizeWorkCheck()?() == true)
        fixture.pendingClick = .init(action: .minimize)
        fixture.lastAction[42] = .init(kind: .minimize, time: 20)
        UtilityPreferences.standard.enabled = [DefaultsKey.dockClickHide]
        fixture.syncWithPreferences()
        UtilityPreferences.standard.enabled.insert(DefaultsKey.dockClickMinimize)
        fixture.syncWithPreferences()
        precondition(!fixture.acceptsDeferredAction(.minimize, pid: 42, at: 20))
        precondition(fixture.handleUp(up) == nil && fixture.tap != nil && fixture.committed == 0)

        fixture.discardingPress = true
        precondition(fixture.handleDragged(drag) == nil && fixture.handleUp(up) == nil)
        precondition(!fixture.replayedDown && fixture.committed == 0)

        fixture.pendingClick = .init(action: .minimize)
        precondition(fixture.handleDragged(drag) == nil && fixture.replayedDown)
        precondition(fixture.handleUp(up) != nil && fixture.committed == 0)
        fixture.pendingClick = .init(action: .hide)
        precondition(fixture.handleUp(up) == nil && fixture.committed == 1)
        print("Dock Click disable, release, drag and deferred action checks passed")
    }
}
