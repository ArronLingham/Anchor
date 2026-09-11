/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Anchor (DynamicIsland)
 * See NOTICE for details.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Defaults
import SwiftUI
import Sparkle

@MainActor
final class SettingsNavigationState: ObservableObject {
    static let shared = SettingsNavigationState()

    @Published var selectedTab: SettingsTab = .general
    let highlightCoordinator = SettingsHighlightCoordinator()

    private init() {}

    func select(tab: SettingsTab, highlightID: String? = nil) {
        selectedTab = tab
        if let highlightID {
            highlightCoordinator.focus(onHighlightID: highlightID, in: tab)
        }
    }

    func select(for notchView: NotchViews) {
        let target = notchView.settingsTarget
        select(tab: target.tab, highlightID: target.highlightID)
    }
}

extension NotchViews {
    var settingsTarget: (tab: SettingsTab, highlightID: String?) {
        switch self {
        case .home:
            return (.general, nil)
        case .timer:
            return (.timer, nil)
        case .notes:
            return Defaults[.enableNotes] ? (.notes, nil) : (.clipboard, nil)
        case .clipboard:
            return (.clipboard, nil)
        case .terminal:
            return (.terminal, nil)
        case .lyrics:
            return (.media, SettingsTab.media.highlightID(for: "Enable lyrics"))
        case .shelf:
            return (.general, SettingsTab.general.highlightID(for: "File shelf"))
        case .stats:
            return (.general, SettingsTab.general.highlightID(for: "System stats"))
        case .notifications:
            return (.liveActivities, nil)
        case .todo:
            return (.todo, nil)
        case .cameraMirror:
            return (.media, SettingsTab.media.highlightID(for: "Camera mirror"))
        case .gemini:
            return (.gemini, nil)
        }
    }
}

class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()
    private var updaterController: SPUStandardUpdaterController?
    
    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 700, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        
        super.init(window: window)
        
        setupWindow()
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setUpdaterController(_ controller: SPUStandardUpdaterController) {
        self.updaterController = controller
        // Recreate the content view with the proper updater controller
        setupWindow()
    }
    
    private func setupWindow() {
        guard let window = window else { return }
        
        window.title = "Anchor Settings"
        window.titlebarAppearsTransparent = false
        window.titleVisibility = .visible
        window.toolbarStyle = .unified
        window.isMovableByWindowBackground = true
        window.level = .normal
        
        // Make it behave like a regular app window with proper Spaces support
        window.collectionBehavior = [.managed, .participatesInCycle]
        
        // Ensure proper window behavior
        window.hidesOnDeactivate = false
        window.isExcludedFromWindowsMenu = false
        
        // Configure window to be a standard document-style window
        window.isRestorable = true
        window.identifier = NSUserInterfaceItemIdentifier("AnchorSettingsWindow")
        
        // Create the SwiftUI content
        let settingsView = SettingsView(updaterController: updaterController)
        let hostingView = NSHostingView(rootView: settingsView)
        window.contentView = hostingView
        
        // Handle window closing
        window.delegate = self
        
        ScreenCaptureVisibilityManager.shared.register(window, scope: .panelsOnly)
    }
    
    func showWindow(tab: SettingsTab? = nil, highlightID: String? = nil) {
        if let tab {
            SettingsNavigationState.shared.select(tab: tab, highlightID: highlightID)
        }
        presentWindow()
    }

    func showWindow(for notchView: NotchViews) {
        SettingsNavigationState.shared.select(for: notchView)
        presentWindow()
    }

    func showWindow() {
        let currentTab = AnchorViewCoordinator.shared.currentView
        if currentTab != .home {
            showWindow(for: currentTab)
            return
        }
        presentWindow()
    }

    private func presentWindow() {
        // Ensure window exists
        _ = window

        // Reassert regular window semantics in case any prior state mutated this window.
        window?.level = .normal
        window?.collectionBehavior = [.managed, .participatesInCycle]
        
        // If window is already visible, bring it to front properly
        if window?.isVisible == true {
            NSApp.activate(ignoringOtherApps: true)
            window?.orderFrontRegardless()
            window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Show the window with proper ordering
        window?.orderFrontRegardless()
        window?.makeKeyAndOrderFront(nil)
        window?.center()
        
        // Activate the app and ensure window gets focus
        NSApp.activate(ignoringOtherApps: true)
        
        // Force window to front after activation
        DispatchQueue.main.async { [weak self] in
            self?.window?.makeKeyAndOrderFront(nil)
        }
    }
    
    override func close() {
        super.close()
        relinquishFocus()
    }
    
    private func relinquishFocus() {
        window?.orderOut(nil)
        
        // Set app back to accessory mode immediately
        NSApp.setActivationPolicy(.accessory)
    }
    
    deinit {
        if let window = window {
            ScreenCaptureVisibilityManager.shared.unregister(window)
        }
    }
}

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        relinquishFocus()
    }
    
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        return true
    }
    
    func windowDidBecomeKey(_ notification: Notification) {
        // Ensure app is in regular mode when window becomes key
        NSApp.setActivationPolicy(.regular)
    }
    
    func windowDidResignKey(_ notification: Notification) {
    }
    
}
