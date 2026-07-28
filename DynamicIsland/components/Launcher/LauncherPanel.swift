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

/// Spotlight-style floating search panel.
///
/// The awkward part of this window class is focus. A borderless `NSPanel` does
/// not take key status by default, so the search field would never receive
/// typing; `canBecomeKey` has to be overridden. `.nonactivatingPanel` keeps the
/// rest of Atoll from being brought forward, so dismissing the panel returns the
/// user to whatever app they were in — which is the whole point of a launcher.
final class LauncherPanel: NSPanel {
    /// Called when the panel loses key status, so the manager can tear it down.
    var onResignKey: (() -> Void)?

    init(contentView: NSView) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.contentView = contentView

        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .floating
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        // Follow the user across spaces, and show over full-screen apps.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }

    /// Required for the search field to receive keystrokes.
    override var canBecomeKey: Bool { true }
    /// Borderless panels cannot be main; keeping this false avoids stealing
    /// main-window status from the app the user is actually working in.
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// Esc closes the panel. `cancelOperation` is what AppKit routes Esc to.
    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }

    /// Centres horizontally and sits slightly above centre vertically, which
    /// reads better than dead-centre and matches Spotlight.
    func positionOnActiveScreen() {
        let screen =
            NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }

        let size = frame.size
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.midY - size.height / 2 + visible.height * 0.12
        )
        setFrameOrigin(origin)
    }
}
