/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
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
import Defaults
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
        let mode = Defaults[.launcherPresentationMode]
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = LauncherPanel.calculateFrame(for: mode, on: screen)

        let hosting = FirstMouseHostingView(
            rootView: LauncherView(
                onLaunch: { [weak self] app in
                    AppIndex.shared.launch(app)
                    // The launched app takes focus itself, so do not restore.
                    self?.hide(restoringFocus: false)
                },
                onDismiss: { [weak self] in self?.hide() }
            ))
        hosting.frame = NSRect(origin: .zero, size: frame.size)
        hosting.autoresizingMask = [.width, .height]

        let panel = LauncherPanel(contentView: hosting, mode: mode)
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.positionOnActiveScreen(mode: mode)
        self.panel = panel

        // Order the panel front and nominate it as key BEFORE asking for
        // activation.
        panel.makeKeyAndOrderFront(nil as Any?)
        panel.makeFirstResponder(hosting)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hide(restoringFocus: Bool = true) {
        guard let panel else { return }
        panel.onResignKey = nil
        let appToRestore = previouslyActiveApp
        self.previouslyActiveApp = nil
        self.panel = nil

        panel.dismiss {
            if restoringFocus, let appToRestore,
                appToRestore.bundleIdentifier != Bundle.main.bundleIdentifier
            {
                appToRestore.activate()
            }
        }
    }
}
