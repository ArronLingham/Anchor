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
/// Which way round the card is laid out.
enum VinylOrientation: String, Codable, CaseIterable, Defaults.Serializable {
    /// Record on top, text and transport beneath.
    case portrait
    /// Record on the left, text and transport beside it — shorter, for sitting
    /// along the bottom of a screen.
    case landscape

    var label: String {
        switch self {
        case .portrait: return String(localized: "Vertical")
        case .landscape: return String(localized: "Horizontal")
        }
    }
}

enum VinylWidgetSize: String, Codable, CaseIterable, Defaults.Serializable {
    case small, medium, regular, large, desktop

    var label: String {
        switch self {
        case .small: return String(localized: "Small")
        case .medium: return String(localized: "Medium")
        case .regular: return String(localized: "Regular")
        case .large: return String(localized: "Large")
        case .desktop: return String(localized: "Desktop")
        }
    }

    var width: CGFloat {
        switch self {
        case .small: return 190
        case .medium: return 250
        case .regular: return 320
        case .large: return 420
        case .desktop: return 560
        }
    }

    /// Height for what is actually being drawn.
    ///
    /// This was a fixed 1.36 ratio, so turning the progress bar off left an
    /// empty strip at the bottom of the card rather than making it shorter.
    /// Each optional row is now worth its own share of the width, matching the
    /// proportional padding the view lays out with.
    var height: CGFloat {
        Self.height(
            width: width,
            orientation: Defaults[.vinylOrientation],
            showsTitle: Defaults[.vinylShowTitle],
            showsProgress: Defaults[.vinylShowProgress] && Defaults[.vinylProgressStyle] == .bar)
    }

    static func height(
        width: CGFloat, orientation: VinylOrientation, showsTitle: Bool, showsProgress: Bool
    ) -> CGFloat {
        switch orientation {
        case .portrait:
            // record (0.72w) + padding, then each row beneath it
            var h = width * 0.72 + width * 0.15
            h += width * 0.16                        // transport, always shown
            if showsTitle { h += width * 0.17 }
            if showsProgress { h += width * 0.11 }
            return h.rounded()
        case .landscape:
            // The record sets the height; the text column sits beside it, so
            // hiding a row makes the card narrower rather than shorter.
            return (width * 0.52).rounded()
        }
    }

    /// Landscape needs more width for the text to sit beside the record.
    var size: CGSize {
        let w = Defaults[.vinylOrientation] == .landscape ? width * 1.5 : width
        return CGSize(
            width: w.rounded(),
            height: Self.height(
                width: width,
                orientation: Defaults[.vinylOrientation],
                showsTitle: Defaults[.vinylShowTitle],
                showsProgress: Defaults[.vinylShowProgress] && Defaults[.vinylProgressStyle] == .bar))
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
    init(contentView: NSView, size: CGSize) {
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
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

        Defaults.publisher(
            keys: .enableVinylWidget, .vinylWidgetSize, .vinylWindowLevel,
            .vinylOrientation, .vinylShowTitle, .vinylShowProgress, .vinylProgressStyle)
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

    /// Keeps a resized widget inside the display it is on.
    ///
    /// Resizing keeps the origin, so growing the card pushes its right and top
    /// edges outward — and every size and shape is now on the widget's own
    /// right-click menu, so going from Small to Desktop (190pt to 560) or
    /// portrait to horizontal (1.5x wider) near an edge slid it off screen.
    /// A borderless panel you cannot see is one you cannot drag back.
    private static func keptOnScreen(_ frame: NSRect, near panel: NSPanel) -> NSRect {
        let screen = panel.screen
            ?? NSScreen.screens.first { $0.frame.intersects(frame) }
            ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return frame }

        var f = frame
        // Only ever pull it back in; a widget smaller than the screen keeps
        // wherever the user put it.
        f.origin.x = min(f.origin.x, visible.maxX - f.width)
        f.origin.y = min(f.origin.y, visible.maxY - f.height)
        f.origin.x = max(f.origin.x, visible.minX)
        f.origin.y = max(f.origin.y, visible.minY)
        return f
    }

    /// Creates, resizes or removes the window to match the settings.
    func sync() {
        let wanted = Defaults[.enableVinylWidget]
            && !SystemActivityGate.shared.shouldSuspendBackgroundWork

        guard wanted else {
            teardown()
            return
        }

        let size = Defaults[.vinylWidgetSize].size
        let level = Defaults[.vinylWindowLevel].windowLevel

        if let panel {
            if panel.frame.size != size {
                var frame = panel.frame
                frame.size = size
                panel.setFrame(Self.keptOnScreen(frame, near: panel), display: true)
            }
            panel.level = level
            return
        }

        let host = NSHostingView(rootView: VinylWidgetView())
        host.frame = NSRect(origin: .zero, size: size)

        let panel = VinylWidgetPanel(contentView: host, size: size)
        panel.level = level
        panel.setFrameAutosaveName(Self.frameAutosaveName)
        if panel.frame.origin == .zero { positionDefault(panel, size: size) }
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
    private func positionDefault(_ panel: NSPanel, size: CGSize) {
        guard let visible = NSScreen.main?.visibleFrame else { return }
        panel.setFrameOrigin(NSPoint(
            x: visible.maxX - size.width - 40,
            y: visible.minY + 40))
    }

    /// Saves the position. Called at quit so a drag is not lost.
    func persistFrame() {
        panel?.saveFrame(usingName: Self.frameAutosaveName)
    }
}
