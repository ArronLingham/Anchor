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

/// Adaptable launcher window supporting Fullscreen Launchpad and Floaty Panel presentation.
final class LauncherPanel: NSPanel {
    var onResignKey: (() -> Void)?
    private(set) var currentMode: LauncherPresentationMode = .fullscreen
    private var isDismissing = false

    init(contentView: NSView, mode: LauncherPresentationMode) {
        self.currentMode = mode
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let frame = Self.calculateFrame(for: mode, on: screen)

        super.init(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        contentView.frame = NSRect(origin: .zero, size: frame.size)
        contentView.autoresizingMask = [.width, .height]
        self.contentView = contentView
        appearance = NSAppearance(named: .darkAqua)

        isOpaque = false
        backgroundColor = .clear
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        configureForMode(mode)
    }

    private func configureForMode(_ mode: LauncherPresentationMode) {
        currentMode = mode
        switch mode {
        case .fullscreen:
            level = .statusBar + 1
            hasShadow = false
        case .floaty:
            level = .floating
            hasShadow = true
        }
    }

    static func calculateFrame(for mode: LauncherPresentationMode, on screen: NSScreen?) -> NSRect {
        guard let screen = screen ?? NSScreen.main else {
            return NSRect(x: 0, y: 0, width: 1040, height: 830)
        }

        switch mode {
        case .fullscreen:
            return screen.frame
        case .floaty:
            let visible = screen.visibleFrame
            let targetWidth = min(900, visible.width * 0.86)
            let targetHeight = min(760, visible.height * 0.86)
            let x = visible.midX - targetWidth / 2
            let y = visible.midY - targetHeight / 2
            return NSRect(x: x, y: y, width: targetWidth, height: targetHeight)
        }
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        guard !isDismissing else { return }
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        guard !isDismissing else { return }
        onResignKey?()
    }

    func positionOnActiveScreen(mode: LauncherPresentationMode) {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let targetFrame = Self.calculateFrame(for: mode, on: screen)
        configureForMode(mode)

        setFrame(targetFrame, display: true)
        contentView?.frame = NSRect(origin: .zero, size: targetFrame.size)
        alphaValue = LauncherMotion.reduced ? 1 : 0
    }

    /// Start once the panel is on screen. A short compositor fade avoids
    /// moving the entire SwiftUI layout and delaying keyboard focus.
    func animatePresentation() {
        guard !LauncherMotion.reduced else { alphaValue = 1; return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.09
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
            animator().alphaValue = 1
        }
    }

    func dismiss(completion: @escaping () -> Void) {
        guard !isDismissing else { return }
        isDismissing = true
        if LauncherMotion.reduced { orderOut(nil); close(); completion(); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.08
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            self.animator().alphaValue = 0.0
        } completionHandler: {
            self.orderOut(nil)
            self.close()
            completion()
        }
    }
}
