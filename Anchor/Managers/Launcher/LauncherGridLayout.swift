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
import Foundation

/// Screen-adaptive grid dimensions for the launcher.
///
/// Automatically fills the available screen space with an appropriate number
/// of columns and rows based on container geometry and display bounds.
public struct LauncherGridLayout: Equatable, Sendable {
    public let columns: Int
    public let rows: Int
    public var perPage: Int { columns * rows }

    public static let `default` = LauncherGridLayout(columns: 7, rows: 4)

    /// Computes the optimal number of columns and rows for a given display or container size.
    ///
    /// - Parameters:
    ///   - size: Measured size of the grid container (if available).
    ///   - screen: Target screen to use as reference or fallback.
    /// - Returns: A `LauncherGridLayout` whose columns and rows scale to fill the space cleanly.
    public static func calculate(
        for size: CGSize? = nil,
        screen: NSScreen? = nil
    ) -> LauncherGridLayout {
        let targetSize: CGSize
        if let size, size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 {
            targetSize = size
        } else {
            let activeScreen = screen
                ?? NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? NSScreen.main
            let screenFrame = activeScreen?.visibleFrame.size ?? CGSize(width: 1440, height: 900)
            targetSize = screenFrame
        }

        // Available area inside the grid after accounting for horizontal padding (20 on each edge)
        // and bottom navigation controls (scrubber/dots).
        let availableWidth = max(1, targetSize.width - 40)
        let availableHeight = max(1, targetSize.height - 68)

        // Target cell dimensions:
        // LauncherGridCell contains 56pt icon + 6pt spacing + 28pt 2-line title + 16pt vertical padding = 106pt.
        // With vertical row spacing (8pt), each row needs ~114pt.
        // Horizontally, comfortable tile width with spacing is ~115pt.
        let cellWidth: CGFloat = 115
        let cellHeight: CGFloat = 114

        let computedColumns = Int(availableWidth / cellWidth)
        let computedRows = Int(availableHeight / cellHeight)

        // Clamp to sensible minimums and maximums so tiles remain well-proportioned
        let cols = max(1, min(32, computedColumns))
        let rows = max(1, min(24, computedRows))

        return LauncherGridLayout(columns: cols, rows: rows)
    }
}
