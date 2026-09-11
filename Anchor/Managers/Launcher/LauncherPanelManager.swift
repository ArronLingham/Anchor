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

        let hosting = FirstMouseHostingView(
            rootView: LauncherView(
                onLaunch: { [weak self] app in
                    AppIndex.shared.launch(app)
                    // The launched app takes focus itself, so do not restore.
                    self?.hide(restoringFocus: false)
                },
                onDismiss: { [weak self] in self?.hide() }
            ))
        // Fill the panel, which is already the size of the screen. It used to
        // be pinned to 860x560, so the launcher was a fixed box floating in a
        // transparent full-screen window — the blurred backdrop had nothing to
        // cover and the layout could not use the space.
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        hosting.frame = NSRect(origin: .zero, size: screen?.frame.size ?? CGSize(width: 860, height: 560))
        hosting.autoresizingMask = [.width, .height]

        let panel = LauncherPanel(contentView: hosting)
        panel.onResignKey = { [weak self] in self?.hide() }
        panel.positionOnActiveScreen()
        self.panel = panel

        // Order the panel front and nominate it as key BEFORE asking for
        // activation. The reverse order is what lost the search field its
        // focus: Anchor is .accessory and the shortcut fires while another app
        // is frontmost, so `activate` is an asynchronous round-trip that
        // resolves several runloop turns later — and AppKit picks the key
        // window from the candidates that existed when activation was
        // requested. With the panel not yet ordered front, that candidate was a
        // notch AnchorWindow, which takes key and drops the launcher's focus.
        //
        // The panel is .nonactivatingPanel, so this does not pull Anchor's
        // other windows forward, and focus is handed back explicitly on
        // dismiss.
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(hosting)
        NSApp.activate(ignoringOtherApps: true)
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
