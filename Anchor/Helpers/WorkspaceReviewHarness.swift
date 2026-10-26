#if DEBUG
import AppKit
import SwiftUI

/// Isolated fixtures: no user workspace preferences, documents, volume, or brightness are changed.
@MainActor
enum WorkspaceReviewHarness {
    static func run(into directory: URL) async {
        let suite = "Anchor.WorkspaceReview.\(UUID().uuidString)"
        let preferences = UserDefaults(suiteName: suite)!
        defer { preferences.removePersistentDomain(forName: suite) }
        let manager = DesktopWorkspaceManager(preferences: preferences)
        let apps = ["/System/Applications/Mail.app", "/System/Applications/Utilities/Terminal.app", "/System/Volumes/Preboot/Cryptexes/App/System/Applications/Safari.app"]
            .compactMap { WorkspaceApp(url: URL(fileURLWithPath: $0)) }
        var left = DesktopDock(name: "Review Left Dock", x: 0, apps: apps)
        let right = DesktopDock(name: "Review Right Dock", x: 1, apps: Array(apps.reversed()))
        let center = DesktopDock(name: "Review Center Dock", vertical: false, x: 0.5, y: 0.5, apps: apps)
        manager.configuration.docks = [left, right, center]
        if let app = apps.first {
            manager.configuration.modes[0].apps = apps
            manager.configuration.modes[0].windows = [WorkspaceWindow(app: app, title: "Saved window", ordinal: 0, displayID: "", rect: WorkspaceRect(width: 0.5))]
        }
        var report: [String] = []
        func check(_ condition: Bool, _ name: String) { report.append("\(condition ? "PASS" : "FAIL") \(name)") }
        manager.start()
        defer { manager.stop() }
        try? await Task.sleep(for: .milliseconds(300))
        let titles = Set(manager.configuration.docks.map(\.name))
        func panels() -> [NSWindow] { NSApp.windows.filter { titles.contains($0.title) && $0.isVisible } }
        check(panels().count == 3, "Three independent dock panels are visible")
        check(panels().allSatisfy { panel in NSScreen.screens.contains { $0.visibleFrame.contains(panel.frame) } }, "Every dock fits a usable display frame")
        check(panels().allSatisfy { !$0.isKeyWindow }, "Docks do not take keyboard focus")
        for panel in panels() { report.append("Panel \(panel.title): \(panel.frame)") }
        let reloaded = DesktopWorkspaceManager(preferences: preferences)
        check(reloaded.configuration == manager.configuration, "Docks, app order, modes, and layouts reload from preferences")
        manager.configuration.docks[0].displayID = "review-disconnected-display"
        check(panels().count == 3, "Disconnected dock display falls back to the primary display")
        check(manager.configuration.docks[0].displayID == "review-disconnected-display", "Fallback preserves saved monitor identity")
        manager.configuration.docks[1].enabled = false
        check(panels().count == 2, "Hiding a dock removes only that panel")
        manager.configuration.docks[1].enabled = true
        left.displayID = ""
        manager.configuration.docks[0] = left

        let previousTab = SettingsNavigationState.shared.selectedTab
        SettingsNavigationState.shared.select(tab: .workspaceModes)
        await UISnapshotHarness.capture(SettingsView(), size: CGSize(width: 1060, height: 850), scheme: .dark,
                                        to: directory.appendingPathComponent("workspace-settings-window.png"))
        SettingsNavigationState.shared.select(tab: previousTab)
        let highlight = SettingsHighlightCoordinator()
        await UISnapshotHarness.capture(
            Form { SettingsDocks(manager: manager) }
                .environmentObject(highlight).formStyle(AnchorFormStyle()).anchorTheme().background(AnchorCanvas()),
            size: CGSize(width: 700, height: 1100), scheme: .dark,
            to: directory.appendingPathComponent("docks-settings.png"))
        await UISnapshotHarness.capture(
            Form { SettingsWorkspaceModes(manager: manager) }
                .environmentObject(highlight).formStyle(AnchorFormStyle()).anchorTheme().background(AnchorCanvas()),
            size: CGSize(width: 760, height: 1500), scheme: .dark,
            to: directory.appendingPathComponent("workspace-modes-settings.png"))
        for dock in manager.configuration.docks {
            await UISnapshotHarness.capture(DesktopDockView(id: dock.id, manager: manager),
                size: dock.vertical ? CGSize(width: 66, height: 206) : CGSize(width: 206, height: 66), scheme: .dark,
                to: directory.appendingPathComponent("\(dock.vertical ? (dock.x == 0 ? "left" : "right") : "center")-dock.png"))
        }

        // Mode application exercises only isolated docks and an optional disposable fixture app.
        var smoke = WorkspaceMode(name: "Review Smoke", visibleDockIDs: [left.id])
        let fixturePath = ProcessInfo.processInfo.environment["ANCHOR_WORKSPACE_FIXTURE_APP"]
        if WorkspaceWindows.permitted, let fixturePath, let app = WorkspaceApp(url: URL(fileURLWithPath: fixturePath)) {
            smoke.apps = [app]
            smoke.windows = [WorkspaceWindow(app: app, title: "Fixture One", ordinal: 0, displayID: "", rect: WorkspaceRect(width: 0.5)),
                             WorkspaceWindow(app: app, title: "Fixture Two", ordinal: 1, displayID: "", rect: WorkspaceRect(x: 0.5, width: 0.5))]
        } else {
            report.append("SKIP Live Accessibility restoration: permission or disposable fixture app unavailable")
        }
        manager.configuration.modes.append(smoke)
        manager.apply(smoke.id)
        for _ in 0..<100 {
            if !manager.applying { break }
            try? await Task.sleep(for: .milliseconds(200))
        }
        check(!manager.applying && manager.activeModeID == smoke.id, "Manual mode application completes")
        check(manager.manualHold, "Manual choice holds automation")
        check(panels().count == 1, "Mode applies its saved dock selection")
        report += manager.issues.map { "ISSUE \($0)" }
        if let app = smoke.apps.first {
            check(manager.issues.isEmpty, "Disposable fixture app opens and both windows restore")
            if let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).first {
                let frames = WorkspaceWindows.windows(for: running).compactMap { WorkspaceWindows.frame($0) }
                report += frames.map { "Restored fixture window: \($0)" }
                check(frames.count == 2, "Both fixture windows remain open")
                _ = running.hide()
                manager.apply(smoke.id)
                for _ in 0..<100 {
                    if !manager.applying { break }
                    try? await Task.sleep(for: .milliseconds(100))
                }
                check(!running.isHidden, "Applying a mode reveals an already-running hidden app")
            }
            var quit = WorkspaceMode(name: "Review Quit", quitApps: [app])
            quit.visibleDockIDs = []
            manager.configuration.modes.append(quit)
            manager.apply(quit.id)
            for _ in 0..<50 {
                if !manager.applying { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            try? await Task.sleep(for: .milliseconds(500))
            check(NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty, "Mode requests normal termination of fixture app")
        }
        try? report.joined(separator: "\n").write(to: directory.appendingPathComponent("workspace-review.txt"), atomically: true, encoding: .utf8)
    }
}
#endif
