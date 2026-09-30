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
import Foundation

/// App integration for the disk store. Defaults is a migration source and mirror,
/// never a competing writer that can resurrect deleted records.
@MainActor
enum TodoStorage {
    private static var isolatedRoot: URL? {
        #if DEBUG
        guard UISnapshotHarness.requestedDirectory != nil else { return nil }
        return ProcessInfo.processInfo.environment["ANCHOR_TODO_TEST_DIRECTORY"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        return nil
        #endif
    }
    private static let store = TodoFileStore(root: isolatedRoot ?? AppSupportDirectory.root)
    static var primaryURL: URL { store.primaryURL }
    static var backupURL: URL { store.backupURL }
    static var snapshotsDirectory: URL { store.snapshotsDirectory }

    static func load() throws -> [TodoItem] {
        if let items = try store.load() { return items }
        let legacy: [TodoItem] = isolatedRoot == nil ? Defaults[.savedTodos] : []
        try save(legacy)
        return legacy
    }

    static func save(_ items: [TodoItem]) throws {
        try store.save(items)
        if isolatedRoot == nil { Defaults[.savedTodos] = items }
    }

    static func availableSnapshots() -> [URL] { store.availableSnapshots() }

    static func restore(from url: URL) throws -> [TodoItem] {
        let snapshot = try TodoFileStore.decode(Data(contentsOf: url))
        try store.restore(snapshot.items)
        if isolatedRoot == nil { Defaults[.savedTodos] = snapshot.items }
        return snapshot.items
    }

    static func restoreLatestSnapshot() throws -> [TodoItem] {
        // The immediate backup is the previous edit, not today's older snapshot.
        for url in [backupURL] + availableSnapshots() {
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? TodoFileStore.decode(data) else { continue }
            try store.restore(snapshot.items)
            if isolatedRoot == nil { Defaults[.savedTodos] = snapshot.items }
            return snapshot.items
        }
        throw TodoFileStore.StorageError.unreadable
    }

    static func export(items: [TodoItem], to destination: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(items).write(to: destination, options: .atomic)
    }

    static func revealInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting([AppSupportDirectory.root])
    }
}
