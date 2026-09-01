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

/// Fullscreen launcher overlay.
final class LauncherPanel: NSPanel {
    var onResignKey: (() -> Void)?

    init(contentView: NSView) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 860, height: 560)
        
        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Wrap the content view in a visual effect view to get a native blur background
        let effectView = NSVisualEffectView(frame: frame)
        effectView.material = .hudWindow
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        
        contentView.frame = frame
        contentView.autoresizingMask = [.width, .height]
        effectView.addSubview(contentView)
        
        self.contentView = effectView

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .screenSaver // High enough to cover menu bar and everything
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onResignKey?()
    }

    func positionOnActiveScreen() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let screenFrame = screen?.frame else { return }
        setFrame(screenFrame, display: true)
        
        // Add a slight fade-in effect when positioning (which usually happens on show)
        self.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().alphaValue = 1.0
        }
    }
}
