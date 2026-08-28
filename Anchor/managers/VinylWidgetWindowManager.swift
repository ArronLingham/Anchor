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
import Combine
import Defaults
import SwiftUI

/// Where the vinyl widget sits relative to everything else.
enum VinylWindowLevel: String, Codable, CaseIterable, Defaults.Serializable {
    case desktop
    case normal
    case floating

    var label: String {
        switch self {
        case .desktop: return String(localized: "Below all windows")
        case .normal: return String(localized: "With other windows")
        case .floating: return String(localized: "Above all windows")
        }
    }

    var windowLevel: NSWindow.Level {
        switch self {
        case .desktop:
            // One above the desktop icons, so it sits on the wallpaper and
            // every ordinary window covers it.
            return NSWindow.Level(
                Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
        case .normal:
            return .normal
        case .floating:
            return .floating
        }
    }
}

/// Size presets, matching VinylPod's own four.
enum VinylWidgetSize: String, Codable, CaseIterable, Defaults.Serializable {
    case small, medium, regular, large

    var label: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .regular: return String(localized: "Regular")
        case .large: return String(localized: "Large")
        }
    }

    var side: CGFloat {
        switch self {
        case .small: return 160
        case .medium: return 220
        case .regular: return 300
        case .large: return 400
        }
    }
}

/// A draggable panel holding the record.
///
/// Borderless and non-activating: clicking the widget must not pull Anchor
/// forward and push the user's actual work behind it.
final class VinylWidgetPanel: NSPanel {
    /// The content view is handed to `init` rather than assigned afterwards,
    /// matching `LauncherPanel`. A borderless panel given its content later can
    /// end up with no backing store and never reach the window server — it
    /// reports `isVisible == true` and simply does not appear.
    init(contentView: NSView, size: CGFloat) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: size, height: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false)

        self.contentView = contentView

        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isFloatingPanel = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Owns the vinyl widget window.
///
/// ## Cost
///
/// The window exists only while the feature is on, and the record's rotation is
/// a `CABasicAnimation` handed to the render server, so a spinning record costs
/// this process nothing per frame. When playback stops, the animation is
/// removed entirely rather than left running at zero speed.
///
/// The widget is also torn down while the display is asleep or the screen is
/// locked, through `SystemActivityGate` — there is nothing to look at then, and
/// an animation the render server is still compositing is not free just because
/// this process is idle.
@MainActor
final class VinylWidgetWindowManager: ObservableObject {
    static let shared = VinylWidgetWindowManager()

    private var panel: VinylWidgetPanel?
    private var cancellables = Set<AnyCancellable>()
    private var started = false

    /// Remembered position, so the widget comes back where it was left.
    private static let frameAutosaveName = "AnchorVinylWidget"

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(keys: .enableVinylWidget, .vinylWidgetSize, .vinylWindowLevel)
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        SystemActivityGate.shared.$shouldSuspendBackgroundWork
            .removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor in self?.sync() }
            }
            .store(in: &cancellables)

        sync()
    }

    /// Creates, resizes or removes the window to match the settings.
    func sync() {
        let wanted = Defaults[.enableVinylWidget]
            && !SystemActivityGate.shared.shouldSuspendBackgroundWork

        guard wanted else {
            teardown()
            return
        }

        let side = Defaults[.vinylWidgetSize].side
        let level = Defaults[.vinylWindowLevel].windowLevel

        if let panel {
            if panel.frame.width != side {
                var frame = panel.frame
                frame.size = CGSize(width: side, height: side)
                panel.setFrame(frame, display: true)
            }
            panel.level = level
            return
        }

        let host = NSHostingView(rootView: VinylWidgetView())
        host.frame = NSRect(x: 0, y: 0, width: side, height: side)

        let panel = VinylWidgetPanel(contentView: host, size: side)
        panel.level = level
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if panel.frame.origin == .zero { positionDefault(panel, side: side) }
        panel.setIsVisible(true)
        panel.orderFrontRegardless()
        panel.displayIfNeeded()
        self.panel = panel
    }

    private func teardown() {
        panel?.saveFrame(usingName: Self.frameAutosaveName)
        panel?.orderOut(nil)
        panel = nil
    }

    /// Bottom-right of the main screen, inset from the corner.
    private func positionDefault(_ panel: NSPanel, side: CGFloat) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - side - 40,
            y: visible.minY + 40))
    }

    /// Saves the position. Called at quit so a drag is not lost.
    func persistFrame() {
        panel?.saveFrame(usingName: Self.frameAutosaveName)
    }
}
