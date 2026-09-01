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
import Foundation
import QuickLookThumbnailing

/// The drag-and-drop file shelf. Category 10.
///
/// Entirely event-driven: it does work when something is dropped, dragged out or
/// removed, and nothing whatsoever in between. There is no timer here and there
/// should never be one — the shelf's contents cannot change unless the user
/// changes them.
///
/// Files are referenced, not copied. The shelf holds bookmarks so an item
/// survives the file being moved or renamed, and so dropping a 4 GB video costs
/// a bookmark rather than 4 GB of duplication.
@MainActor
final class ShelfManager: ObservableObject {
    static let shared = ShelfManager()

    struct Item: Identifiable, Codable, Equatable {
        let id: UUID
        /// Security-scoped bookmark. Resolved lazily, because a volume that is
        /// no longer mounted should not block launch.
        let bookmark: Data
        let name: String
        let addedAt: Date

        static func == (a: Item, b: Item) -> Bool { a.id == b.id }
    }

    @Published private(set) var items: [Item] = []
    /// Thumbnails, generated once per item and held only while the shelf exists.
    @Published private(set) var thumbnails: [UUID: NSImage] = [:]

    private let storeURL: URL
    private var thumbnailTasks: [UUID: Task<Void, Never>] = [:]

    private init() {
        storeURL = AppSupportDirectory.subdirectory("Shelf")
            .appendingPathComponent("items.json")
        // Deferred per CLAUDE.md: reading a bookmark can touch a volume, and
        // nothing in a manager's init may block the run loop starting.
        DispatchQueue.main.async { [weak self] in self?.load() }
    }

    // MARK: - Contents

    func add(urls: [URL]) {
        var added = false
        for url in urls {
            guard let bookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil)
            else { continue }
            // Same file twice is a no-op rather than a duplicate row.
            if items.contains(where: { resolve($0)?.standardizedFileURL == url.standardizedFileURL }) {
                continue
            }
            let item = Item(id: UUID(), bookmark: bookmark,
                            name: url.lastPathComponent, addedAt: Date())
            items.append(item)
            generateThumbnail(for: item)
            added = true
        }
        if added { save() }
    }

    func remove(_ item: Item) {
        thumbnailTasks[item.id]?.cancel()
        thumbnailTasks[item.id] = nil
        thumbnails[item.id] = nil
        items.removeAll { $0.id == item.id }
        save()
    }

    func clear() {
        thumbnailTasks.values.forEach { $0.cancel() }
        thumbnailTasks.removeAll()
        thumbnails.removeAll()
        items.removeAll()
        save()
    }

    /// Resolves the bookmark back to a URL, or nil if the file is gone.
    func resolve(_ item: Item) -> URL? {
        var stale = false
        guard let url = try? URL(
            resolvingBookmarkData: item.bookmark,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale)
        else { return nil }
        return url
    }

    func revealInFinder(_ item: Item) {
        guard let url = resolve(item) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func open(_ item: Item) {
        guard let url = resolve(item) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Thumbnails

    private func generateThumbnail(for item: Item) {
        guard let url = resolve(item) else { return }
        thumbnailTasks[item.id]?.cancel()
        thumbnailTasks[item.id] = Task { [weak self] in
            let request = QLThumbnailGenerator.Request(
                fileAt: url, size: CGSize(width: 64, height: 64),
                scale: 2, representationTypes: .thumbnail)
            let image: NSImage? = await withCheckedContinuation { cont in
                QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { rep, _ in
                    cont.resume(returning: rep?.nsImage)
                }
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                // Fall back to the file's icon rather than leaving a blank tile.
                self.thumbnails[item.id] = image ?? NSWorkspace.shared.icon(forFile: url.path)
                self.thumbnailTasks[item.id] = nil
            }
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let stored = try? JSONDecoder().decode([Item].self, from: data)
        else { return }
        // Drop anything whose file no longer exists, so the shelf does not
        // accumulate rows that cannot be opened.
        items = stored.filter { resolve($0) != nil }
        if items.count != stored.count { save() }
        items.forEach { generateThumbnail(for: $0) }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: storeURL, options: .atomic)
    }
}
