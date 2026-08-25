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
import ApplicationServices
import Combine
import Defaults
import Foundation

/// Drag a window to a screen edge to tile it. Category 16.
///
/// Costs nothing until a drag starts. The only always-on subscription is to
/// `leftMouseDown`/`leftMouseUp`, which fire once per click; the dragged-position
/// monitor is installed on mouse-down and removed on mouse-up, so no handler
/// runs while the mouse is merely moving. Nothing polls, and there is no timer.
///
/// Uses Accessibility, which this app already requires for dictation — snapping
/// adds no permission that was not already being asked for.
@MainActor
final class SnapZoneManager: ObservableObject {
    static let shared = SnapZoneManager()

    /// Where a window will land. Edges only: corners need a second axis of
    /// intent that a straight drag cannot express unambiguously.
    enum Zone: Equatable {
        case left, right, top

        func frame(in visible: NSRect) -> NSRect {
            switch self {
            case .left:  return NSRect(x: visible.minX, y: visible.minY,
                                       width: visible.width / 2, height: visible.height)
            case .right: return NSRect(x: visible.midX, y: visible.minY,
                                       width: visible.width / 2, height: visible.height)
            case .top:   return visible
            }
        }
    }

    /// The zone the pointer is currently over, for the preview overlay.
    @Published private(set) var activeZone: Zone?

    private var mouseDownMonitor: Any?
    private var mouseUpMonitor: Any?
    private var dragMonitor: Any?
    private var settingsCancellable: AnyCancellable?

    /// How close to an edge counts, in points.
    private let edgeThreshold: CGFloat = 12

    private init() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.settingsCancellable = Defaults.publisher(.enableSnapZones)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncToSettings() }
            self.syncToSettings()
        }
    }

    private func syncToSettings() {
        if Defaults[.enableSnapZones] { startWatching() } else { stopWatching() }
    }

    // MARK: - Monitors

    private func startWatching() {
        guard mouseDownMonitor == nil else { return }
        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.beginDrag() }
        }
        mouseUpMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
            Task { @MainActor in self?.endDrag() }
        }
    }

    private func stopWatching() {
        [mouseDownMonitor, mouseUpMonitor, dragMonitor].forEach {
            if let m = $0 { NSEvent.removeMonitor(m) }
        }
        mouseDownMonitor = nil
        mouseUpMonitor = nil
        dragMonitor = nil
        activeZone = nil
    }

    /// Installed on mouse-down and removed on mouse-up, so nothing observes
    /// pointer movement outside an actual drag.
    private func beginDrag() {
        guard dragMonitor == nil else { return }
        dragMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in self?.updateZone() }
        }
    }

    private func endDrag() {
        if let m = dragMonitor { NSEvent.removeMonitor(m) }
        dragMonitor = nil
        guard let zone = activeZone else { return }
        activeZone = nil
        apply(zone)
    }

    private func updateZone() {
        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main else {
            activeZone = nil
            return
        }
        let f = screen.frame
        let zone: Zone?
        if point.x <= f.minX + edgeThreshold {
            zone = .left
        } else if point.x >= f.maxX - edgeThreshold {
            zone = .right
        } else if point.y >= f.maxY - edgeThreshold {
            // The notch lives along this edge; snapping to it is still the
            // natural "maximise" gesture, and the notch window sits above.
            zone = .top
        } else {
            zone = nil
        }
        if zone != activeZone { activeZone = zone }
    }

    // MARK: - Applying

    private func apply(_ zone: Zone) {
        guard AXIsProcessTrusted() else {
            NSLog("SnapZoneManager: Accessibility not granted; cannot move windows")
            return
        }
        guard let app = NSWorkspace.shared.frontmostApplication else { return }
        let axApp = AXUIElementCreateApplication(app.processIdentifier)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
                axApp, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let focused,
              CFGetTypeID(focused) == AXUIElementGetTypeID()
        else { return }
        // Checked rather than force-cast: the attribute is documented to be an
        // AXUIElement, but a crash in a window manager triggered by whatever app
        // happens to be frontmost is not an acceptable way to find out otherwise.
        let window = focused as! AXUIElement

        let point = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) })
                ?? NSScreen.main else { return }
        let target = zone.frame(in: screen.visibleFrame)

        // Accessibility positions windows in a top-left origin space, while
        // NSScreen reports bottom-left. Converting against the *primary* screen's
        // height is what makes this correct on secondary displays too, because
        // the AX origin is global rather than per-screen.
        guard let primary = NSScreen.screens.first else { return }
        var origin = CGPoint(x: target.minX,
                             y: primary.frame.maxY - target.maxY)
        var size = CGSize(width: target.width, height: target.height)

        // Size first, then position: a window that refuses to shrink would
        // otherwise be moved to a corner and left overhanging the screen.
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
        if let originValue = AXValueCreate(.cgPoint, &origin) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, originValue)
        }
    }
}
