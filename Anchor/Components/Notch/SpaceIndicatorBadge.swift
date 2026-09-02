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

import SwiftUI

/// Which desktop you are on, in the notch header.
///
/// A leaf view that observes `SpaceIndicatorManager` directly. Per CLAUDE.md,
/// `ContentView` must not take another `@ObservedObject` — every publish from
/// one re-renders the whole notch, and this value changes on every desktop
/// switch.
struct SpaceIndicatorBadge: View {
    /// The screen this notch is on. Spaces are per-display, so a badge that
    /// asked a global manager showed the focused screen's desktop on every
    /// display at once.
    let screenName: String?

    @ObservedObject private var manager = SpaceIndicatorManager.shared

    private var position: SpaceIndicatorManager.Position? {
        manager.position(for: screenName)
    }

    var body: some View {
        if let position, position.index > 0 {
            Text("\(position.index)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(.white.opacity(0.14))
                )
                .help(
                    position.total > 0
                        ? "Desktop \(position.index) of \(position.total)"
                        : "Desktop \(position.index)"
                )
                .transition(.opacity)
        }
    }
}
