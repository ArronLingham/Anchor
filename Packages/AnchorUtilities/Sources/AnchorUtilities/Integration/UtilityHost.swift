import AppKit
import Combine
import SwiftUI
import UserNotifications

/// Adapts upstream's presentation requests to Anchor. It is deliberately not
/// NSApplication's delegate: Anchor owns its one menu and application lifecycle.
final class AppDelegate: NSObject, NSWindowDelegate, UNUserNotificationCenterDelegate {
    private var settingsWindow: NSWindow?
    private var panelWindow: UtilityPanelWindow?
    private var updatingPanelLayout = false
    private var retainedWindows = Set<ObjectIdentifier>()
    private var statusController: StatusItemController?
    private var micSubscription: AnyCancellable?

    func syncStatusItems() {
        if AppFeature.micMute.isAvailable, micSubscription == nil {
            micSubscription = MicMuteService.shared.$isMuted.dropFirst().sink { [weak self] muted in
                UtilityWorkspace.shared.onMicrophoneMuteChange?(muted)
                self?.syncStatusItems()
            }
            UtilityWorkspace.shared.onMicrophoneMuteChange?(MicMuteService.shared.isMuted)
        } else if !AppFeature.micMute.isAvailable, micSubscription != nil,
                  !MicMuteService.shared.isMuted { micSubscription = nil }
        let defaults = UtilityPreferences.standard
        let clipboard = AppFeature.clipboardHistory.isAvailable
            && defaults.bool(forKey: DefaultsKey.clipboardHistoryEnabled)
            && defaults.bool(forKey: DefaultsKey.clipboardHistoryMenuBarPreview)
        let countdown = AppFeature.keepAwake.isAvailable && KeepAwakeManager.shared.isActive
            && defaults.bool(forKey: DefaultsKey.showCountdown)
        let mic = AppFeature.micMute.isAvailable && MicMuteService.shared.isMuted
        let wanted = MenuBarMetric.anyEnabled(in: defaults) || clipboard || countdown || mic
        if wanted, statusController == nil {
            let controller = StatusItemController(embedded: true)
            controller.onLeftClick = { [weak self] in self?.showPanel() }
            controller.onRightClick = { [weak self] _ in self?.showPanel() }
            controller.onMetricClick = { [weak self] metric, _ in self?.showPanel(metric: metric.detailKind) }
            controller.onClipboardPreviewClick = { ClipboardHistoryService.shared.showHistoryWindow() }
            statusController = controller
        } else if !wanted, statusController != nil {
            statusController = nil
            SystemMonitor.shared.setMenuBarActive(false)
        }
    }

    func openSettingsWindow(preservingNotch: Bool = false) {
        if !preservingNotch, NotchSupport.isEnabled() { NotchService.shared.collapse() }
        let window: NSWindow
        if let existing = settingsWindow { window = existing }
        else {
            let host = NSHostingController(rootView: SettingsView()
                .defaultAppStorage(UtilityPreferences.standard))
            host.sizingOptions = []
            window = NSWindow(contentViewController: host)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.isReleasedWhenClosed = false
            window.isRestorable = false
            window.minSize = NSSize(width: 820, height: 560)
            window.setContentSize(NSSize(width: 1050, height: 730))
            window.delegate = self
            window.setFrameAutosaveName("AnchorUtilitiesSettings")
            settingsWindow = window
            constrain(window)
        }
        window.title = "Anchor · Controls"
        retain(window)
        // The floating Quick Panel must not cover the controls it just opened.
        if let panel = panelWindow, panel.isVisible || panel.isMiniaturized { panel.close() }
        SettingsWindowVisibility.shared.set(true)
        SecureInputMonitor.shared.setSettingsWindowOpen(true)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func showPanel(metric: MetricDetailKind? = nil) {
        PanelInteractionState.shared.anchorScreen = NSScreen.screens.first {
            $0.frame.contains(NSEvent.mouseLocation)
        } ?? NSScreen.main
        if let metric { MenuPanelFocus.shared.focus(metric) }
        else { MenuPanelFocus.shared.showNormalPanel() }
        let window: UtilityPanelWindow
        if let existing = panelWindow { window = existing }
        else {
            let host = NSHostingController(rootView: MenuPanelView()
                .defaultAppStorage(UtilityPreferences.standard))
            host.sizingOptions = .preferredContentSize
            window = UtilityPanelWindow(contentViewController: host)
            window.delegate = self
            panelWindow = window
            constrain(window)
        }
        updatePanelLayout()
        retain(window)
        MenuPanelFocus.shared.setPopoverVisible(true)
        NotificationCenter.default.post(name: .menuPanelWillShow, object: nil)
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closePopover(animated: Bool = true, after delay: TimeInterval = 0,
                      preservingNotch: Bool = false,
                      completion: (() -> Void)? = nil) {
        if delay > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.closePopover(animated: animated, preservingNotch: preservingNotch,
                                   completion: completion)
            }
            return
        }
        if !preservingNotch, NotchSupport.isEnabled() { NotchService.shared.collapse() }
        panelWindow?.close()
        completion?()
    }

    func isOverStatusItem(_ point: NSPoint) -> Bool { statusController?.containsStatusItem(at: point) == true }

    func relaunchApp() { FeatureRuntime.shared.relaunchApp() }
    func reshowStatusItem() { UtilityWorkspace.shared.onShowAnchorMenuIcon?() }
    func showOnboarding(mode: OnboardingMode = .full) { UtilityWorkspace.shared.showLibrary() }
    func showUpdateHighlights(isReview: Bool = false) { UtilityWorkspace.shared.showLibrary() }
    func openSettingsFromHighlights() { openSettingsWindow() }
    func showUpdatePreview() { UtilityWorkspace.shared.showLibrary() }

    func openFeedbackWindow(kind: FeedbackKind = .bug) {
        let alert = NSAlert()
        alert.messageText = "Anchor diagnostics"
        alert.informativeText = "Copy a local diagnostic summary to include with a bug report. It contains the app version, macOS version and installed feature names."
        alert.addButton(withTitle: "Copy Summary")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            let report = "Anchor \(AppInfo.version)\n\(ProcessInfo.processInfo.operatingSystemVersionString)\nFeatures: "
                + UtilityWorkspace.shared.features.filter(\.isAvailable).map(\.id).joined(separator: ", ")
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(report, forType: .string)
        }
    }

    private func constrain(_ window: NSWindow) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { return }
        let available = screen.visibleFrame.insetBy(dx: 16, dy: 16)
        var frame = window.frame
        frame.size.width = min(frame.width, available.width)
        frame.size.height = min(frame.height, available.height)
        frame.origin = NSPoint(x: available.midX - frame.width / 2,
                               y: available.midY - frame.height / 2)
        window.setFrame(frame, display: false)
    }

    private func retain(_ window: NSWindow) {
        if retainedWindows.insert(ObjectIdentifier(window)).inserted {
            WindowActivationPolicy.retain()
        }
    }

    private func updatePanelLayout() {
        guard !updatingPanelLayout, let panel = panelWindow,
              let screen = panel.screen ?? PanelInteractionState.shared.anchorScreen else { return }
        updatingPanelLayout = true
        defer { updatingPanelLayout = false }
        PanelInteractionState.shared.anchorScreen = screen
        MenuPanelFocus.shared.setMaximumContentHeight(panel.maximumContentHeight(on: screen))
        panel.constrainToScreen(screen)
    }

    func windowDidResize(_ notification: Notification) {
        if (notification.object as? NSWindow) === panelWindow { updatePanelLayout() }
    }

    func windowDidChangeScreen(_ notification: Notification) {
        if (notification.object as? NSWindow) === panelWindow { updatePanelLayout() }
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === panelWindow {
            MenuPanelFocus.shared.setPopoverVisible(false)
            SystemMonitor.shared.setMenuPanelNeeds(.none)
        }
        if window === settingsWindow {
            SettingsWindowVisibility.shared.set(false)
            SecureInputMonitor.shared.setSettingsWindowOpen(false)
        }
        if retainedWindows.remove(ObjectIdentifier(window)) != nil { WindowActivationPolicy.release() }
    }

    func releaseInactiveViews(disabling: Bool) {
        if let panel = panelWindow, disabling || (!panel.isVisible && !panel.isMiniaturized) {
            panel.close()
            panel.contentViewController = nil
            panelWindow = nil
        }
        if let settings = settingsWindow, !settings.isVisible && !settings.isMiniaturized {
            settings.contentViewController = nil
            settingsWindow = nil
        }
    }

    func closeWindows() {
        settingsWindow?.close()
        panelWindow?.close()
        statusController = nil
        micSubscription = nil
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let id = Notifier.whatsAppOrganizerTransactionID(from: response) {
            DispatchQueue.main.async { WhatsAppDownloadOrganizer.shared.undoLastRun(transactionID: id) }
        }
        completionHandler()
    }
}
