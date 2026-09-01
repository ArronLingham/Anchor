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
    @ObservedObject private var manager = SpaceIndicatorManager.shared

    var body: some View {
        if manager.currentSpace > 0 {
            Text("\(manager.currentSpace)")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 18, height: 18)
                .background(
                    Circle().fill(.white.opacity(0.14))
                )
                .help(
                    manager.totalSpaces > 0
                        ? "Desktop \(manager.currentSpace) of \(manager.totalSpaces)"
                        : "Desktop \(manager.currentSpace)"
                )
                .transition(.opacity)
        }
    }
}
