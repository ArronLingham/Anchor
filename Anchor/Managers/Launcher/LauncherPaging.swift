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

import Foundation

/// Where the launcher grid's selection sits relative to its pages.
///
/// Two facts make this worth its own type rather than arithmetic inline in the
/// view. First, **selection indexes apps, while the grid lays out folders and
/// then apps** — so every conversion between the two has to carry the folder
/// count, and the three paging controls each got it wrong once by setting
/// `page * perPage` directly, which lands a page further on for each full page
/// of folders and can run past the end of the app list. Second, it is pure, so
/// it can be pinned by a harness where the view cannot be.
enum LauncherPaging {
    /// The page a given selection appears on.
    ///
    /// Folders occupy the first `folderCount` slots, so an app at index 0 is
    /// not necessarily in slot 0.
    static func page(forSelection selection: Int, folderCount: Int, perPage: Int) -> Int {
        guard perPage > 0 else { return 0 }
        let slot = max(0, selection) + max(0, folderCount)
        return slot / perPage
    }

    /// The selection that puts `page` on screen, clamped to the app list.
    ///
    /// Returns nil when there is nothing to select — an empty grid, or a
    /// nonsense page size — so the caller leaves the selection alone rather
    /// than moving it somewhere meaningless.
    static func selection(forPage page: Int, folderCount: Int, perPage: Int, appCount: Int) -> Int? {
        guard perPage > 0, appCount > 0 else { return nil }
        let target = page * perPage - max(0, folderCount)
        return min(max(0, target), appCount - 1)
    }

    /// How many pages the grid has, counting folder slots.
    static func pageCount(folderCount: Int, appCount: Int, perPage: Int) -> Int {
        guard perPage > 0 else { return 0 }
        let slots = max(0, folderCount) + max(0, appCount)
        guard slots > 0 else { return 0 }
        return (slots + perPage - 1) / perPage
    }
}
