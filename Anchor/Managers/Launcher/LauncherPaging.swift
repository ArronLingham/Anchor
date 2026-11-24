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
    static let categoriesPage = -1

    static func landingPage(showCategories: Bool, startOnCategories: Bool) -> Int {
        showCategories && startOnCategories ? categoriesPage : 0
    }

    /// App page indices stay the same when the categories page is hidden.
    static func pageIDs(appPageCount: Int, showCategories: Bool) -> Range<Int> {
        (showCategories ? categoriesPage : 0)..<max(1, appPageCount)
    }

    /// Folders occupy the first slots, before any app that can receive selection.
    static func page(forSelection selection: Int, folderCount: Int, perPage: Int) -> Int {
        guard perPage > 0 else { return 0 }
        return (max(0, selection) + max(0, folderCount)) / perPage
    }

    /// The app indices visible on a page. Categories and folder-only pages have no selection.
    static func selections(onPage page: Int, folderCount: Int, perPage: Int, appCount: Int) -> Range<Int> {
        guard page >= 0, perPage > 0, appCount > 0 else { return 0..<0 }
        let start = max(0, page * perPage - max(0, folderCount))
        let end = min(appCount, (page + 1) * perPage - max(0, folderCount))
        return start..<max(start, end)
    }

    /// How many pages the grid has, counting folder slots.
    static func pageCount(folderCount: Int, appCount: Int, perPage: Int) -> Int {
        guard perPage > 0 else { return 0 }
        let slots = max(0, folderCount) + max(0, appCount)
        guard slots > 0 else { return 0 }
        return (slots + perPage - 1) / perPage
    }
}
