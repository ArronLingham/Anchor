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

/// Lets a HUD be dragged to set the value it is showing.
///
/// Applied to the circular, custom-OSD and inline HUDs, so the gesture means
/// the same thing across them.
///
/// **Not** the vertical bar: that one already has its own drag, complete with
/// rubber-band overshoot and auto-hide cancellation, gated on
/// `verticalHUDInteractive` and on by default. Adding this there put a second
/// DragGesture on the same view for the two to fight over.
///
/// Only volume and brightness are draggable. Keyboard backlight is on the same
/// key path but has no continuous control worth scrubbing, and the remaining
/// sneak-peek types (music, mic, battery, Bluetooth) are notifications rather
/// than controls — dragging one would have nothing to set.
struct HUDDragToSet: ViewModifier {
    let type: SneakContentType
    /// `.vertical` for a bar that fills upward, `.horizontal` for one that
    /// fills rightward. The circle passes `.horizontal`, where left-to-right
    /// across the glyph is the least surprising mapping.
    let axis: Axis
    /// Which screen's brightness to set. Volume ignores it.
    ///
    /// Left nil by every current caller, because the circular, custom-OSD and
    /// inline HUDs do not carry one — so it is resolved from the pointer at
    /// drag time instead. On two displays that matters: nil means the main
    /// screen, which would dim the built-in while you drag the HUD on the
    /// external one.
    var screen: NSScreen?

    @Default(.enableHUDDrag) private var enabled

    private var draggable: Bool {
        enabled && (type == .volume || type == .brightness)
    }

    func body(content: Content) -> some View {
        if draggable {
            GeometryReader { geo in
                content
                    .contentShape(Rectangle())
                    .gesture(
                        // minimumDistance 0 so a press sets the value straight
                        // away, the way a slider track does. Without it the
                        // first few points of movement are swallowed and the
                        // value jumps once the drag is finally recognised.
                        DragGesture(minimumDistance: 0)
                            .onChanged { drag in
                                apply(fraction(for: drag.location, in: geo.size))
                            })
            }
        } else {
            content
        }
    }

    private func fraction(for point: CGPoint, in size: CGSize) -> Double {
        switch axis {
        case .vertical:
            // SwiftUI's y grows downward; a bar fills upward.
            guard size.height > 0 else { return 0 }
            return clamp(1 - Double(point.y / size.height))
        case .horizontal:
            guard size.width > 0 else { return 0 }
            return clamp(Double(point.x / size.width))
        }
    }

    private func clamp(_ v: Double) -> Double { max(0, min(1, v)) }

    private func apply(_ fraction: Double) {
        switch type {
        case .volume:
            SystemVolumeController.shared.setVolume(Float(fraction))
        case .brightness:
            // Immediate rather than the smoothed setter: the pointer is already
            // the smoothing, and easing toward a target that moves every frame
            // reads as lag.
            let target = screen
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
            SystemBrightnessController.shared.setBrightnessImmediate(Float(fraction), for: target)
        default:
            break
        }
    }
}

extension View {
    /// See `HUDDragToSet`.
    func hudDragToSet(type: SneakContentType, axis: Axis, screen: NSScreen? = nil) -> some View {
        modifier(HUDDragToSet(type: type, axis: axis, screen: screen))
    }
}
