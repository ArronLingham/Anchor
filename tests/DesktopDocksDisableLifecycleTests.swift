import AppKit

struct DesktopDock: Codable, Equatable {
    var id = UUID()
    var enabled = true
    var workspaceModeIDs: [UUID] = []
    var showsRecentApps = false
}

struct Mode: Codable {
    var id = UUID()
    var rule = ""
}

struct DesktopWorkspaceConfiguration: Codable {
    var docks: [DesktopDock] = []
    var modes: [Mode] = []
    var automationEnabled = false
}

struct WorkspaceEnvironment {
    var externalDisplayIDs: Set<String>
    var onAC: Bool
    var charging: Bool
}

struct WorkspaceAutomationState {
    mutating func resume() {}
}

@MainActor
final class DesktopDockController {
    var visible: [DesktopDock] = []
    var closed = false

    init(manager: DesktopWorkspaceManager) {}
    func closeAll() { closed = true; visible = [] }
    func reconcile(visible: [DesktopDock]) { self.visible = visible }
}

@main
enum DesktopDocksDisableLifecycleTests {
    @MainActor
    static func main() {
        let domain = "Anchor.test.desktop-docks.\(UUID())"
        let preferences = UserDefaults(suiteName: domain)!
        defer { preferences.removePersistentDomain(forName: domain) }
        let manager = DesktopWorkspaceManager(preferences: preferences)
        precondition(manager.docksEnabled)
        manager.modesEnabled = false
        manager.configuration.docks = [DesktopDock(), DesktopDock(enabled: false, showsRecentApps: true)]
        let savedConfiguration = preferences.data(forKey: DesktopWorkspaceManager.storageKey)
        manager.start()
        let controller = manager.dockController!
        precondition(controller.visible.count == 1 && manager.screenObserver != nil)
        precondition(manager.wakeObserver == nil && manager.recentsObserver == nil)
        precondition(manager.runningAppObservers.count == 2)
        manager.toggleShowAllDocks()
        precondition(controller.visible.count == 2 && manager.recentsObserver != nil)
        let oldSession = manager.dockSession
        precondition(manager.acceptsDockSession(oldSession))

        manager.docksEnabled = false
        precondition(controller.closed && manager.dockController == nil && !manager.forceShowAllDocks)
        precondition(manager.screenObserver == nil && manager.recentsObserver == nil && manager.runningAppObservers.isEmpty)
        precondition(!manager.acceptsDockSession(oldSession))
        manager.toggleShowAllDocks()
        precondition(manager.dockController == nil && !manager.forceShowAllDocks)
        precondition(preferences.data(forKey: DesktopWorkspaceManager.storageKey) == savedConfiguration)
        precondition(!DesktopWorkspaceManager(preferences: preferences).docksEnabled)

        manager.modesEnabled = true
        precondition(manager.screenObserver != nil && manager.wakeObserver != nil)
        precondition(manager.dockController == nil && manager.recentsObserver == nil)
        manager.docksEnabled = true
        precondition(manager.dockController?.visible.count == 1 && !manager.acceptsDockSession(oldSession))
        manager.modesEnabled = false
        precondition(manager.dockController?.visible.count == 1 && manager.screenObserver != nil && manager.wakeObserver == nil)
        manager.stop()
        precondition(manager.dockController == nil && manager.screenObserver == nil && manager.runningAppObservers.isEmpty)
        print("Desktop Docks persistence, panel closure, stale sessions and shared observation checks passed")
    }
}
