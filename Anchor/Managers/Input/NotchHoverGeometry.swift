/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * See NOTICE for details.
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

import CoreGraphics
import Foundation

/// Geometry for the "extend hover area" band above each display's pill, and the
/// resolution of *which* displays the pointer is currently extending into.
///
/// This is pure so it can be tested without AppKit — see
/// `tests/run_externalpill_tests.sh`.
///
/// It returns a **set of screen names**, not a single `Bool`, and that is the
/// whole point. `NotchHoverManager` used to publish one global
/// `isHoveringExtendedArea`, which every per-screen `ContentView` observed —
/// so with `showOnAllDisplays` (or the external pill) on, hovering the band on
/// *one* display called `handleHover(true)` on *every* display and opened the
/// notch on all of them at once. The pointer is only ever over one screen.
enum NotchHoverGeometry {
    /// Extra width either side of the pill, so the hover does not have to be precise.
    static let horizontalPadding: CGFloat = 40
    /// Extra height below the pill, for the same reason.
    static let extensionHeight: CGFloat = 12

    /// One display, described by only what the geometry needs.
    struct Display: Equatable {
        let name: String
        /// Cocoa coordinates: origin bottom-left, y increasing upward.
        let frame: CGRect
        /// This display's own closed pill size.
        ///
        /// Per-display, deliberately. The old code read
        /// `AppDelegate.shared.vm.closedNotchSize` — the *singleton* view model,
        /// which in multi-window mode drives no window at all and is sized for
        /// `NSScreen.main`. On an external display that made the hover band the
        /// width of the built-in's physical notch rather than of the pill it was
        /// supposed to be extending.
        let closedNotchSize: CGSize

        init(name: String, frame: CGRect, closedNotchSize: CGSize) {
            self.name = name
            self.frame = frame
            self.closedNotchSize = closedNotchSize
        }
    }

    /// The hover band for one display: the pill, grown by the padding above.
    static func extendedRect(screenFrame: CGRect, closedNotchSize: CGSize) -> CGRect {
        let width = closedNotchSize.width + horizontalPadding
        let height = closedNotchSize.height + extensionHeight
        return CGRect(
            x: screenFrame.midX - (width / 2),
            y: screenFrame.maxY - height,
            width: width,
            height: height
        )
    }

    /// The displays whose hover band contains `point`.
    ///
    /// Normally zero or one. Two displays can only both match if their frames
    /// overlap, which macOS allows for mirrored sets.
    static func hoveredDisplayNames(point: CGPoint, displays: [Display]) -> Set<String> {
        var hovered: Set<String> = []
        for display in displays {
            let band = extendedRect(
                screenFrame: display.frame,
                closedNotchSize: display.closedNotchSize
            )
            if band.contains(point) {
                hovered.insert(display.name)
            }
        }
        return hovered
    }
}
