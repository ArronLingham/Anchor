/*
 * Atoll (DynamicIsland)
 * Copyright (C) 2024-2026 Atoll Contributors
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
import SwiftUI

/// Owns the launcher panel's lifetime. Follows the same shape as the other
/// `*PanelManager` singletons in this codebase.
@MainActor
final class LauncherPanelManager: ObservableObject {
    static let shared = LauncherPanelManager()

    private var panel: LauncherPanel?
    /// The app that was frontmost when the launcher opened, so dismissing
    /// without launching returns the user exactly where they were.
    private var previouslyActiveApp: NSRunningApplication?

    private init() {}

    var isVisible: Bool { panel?.isVisible ?? false }

    func toggle() {
        isVisible ? hide() : show()
    }

    func show() {
        guard panel == nil else { return }

        previouslyActiveApp = NSWorkspace.shared.frontmostApplication

        let hosting = NSHostingView(
            rootView: LauncherView(
                onLaunch: { [weak self] app in
                    AppIndex.shared.launch(app)
                    // The launched app takes focus itself, so do not restore.
                    self?.hide(restoringFocus: false)
                },
                onDismiss: { [weak self] in self?.hide() }
            ))
        hosting.frame = NSRect(x: 0, y: 0, width: 720, height: 420)

        let panel = LauncherPanel(contentView: hosting)
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.positionOnActiveScreen()
        self.panel = panel

        // Activating is what lets the search field take keystrokes. The panel is
        // .nonactivatingPanel, so this does not pull Atoll's other windows
        // forward, and focus is handed back explicitly on dismiss.
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide(restoringFocus: Bool = true) {
        guard let panel else { return }
        // Break the retain cycle before closing, or resignKey re-enters hide().
        panel.onResignKey = nil
        panel.orderOut(nil)
        panel.close()
        self.panel = nil

        if restoringFocus, let previouslyActiveApp,
            previouslyActiveApp.bundleIdentifier != Bundle.main.bundleIdentifier
        {
            previouslyActiveApp.activate()
        }
        previouslyActiveApp = nil
    }
}
