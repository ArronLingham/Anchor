/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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

/// LRU cache for device icons to avoid repeated disk I/O on BT device reconnects.
/// Thread-safe: accessed only from @MainActor contexts.
@MainActor
final class DeviceIconCache {
    static let shared = DeviceIconCache()

    private var cache: [String: NSImage] = [:]
    private var order: [String] = []
    private let maxSize: Int

    init(maxSize: Int = 30) {
        self.maxSize = maxSize
    }

    /// Returns cached icon or loads via the provided closure and caches it.
    func icon(for uid: String, loader: () -> NSImage?) -> NSImage? {
        if let cached = cache[uid] {
            moveToFront(uid)
            return cached
        }
        guard let icon = loader() else { return nil }
        insert(uid, icon)
        return icon
    }

    /// Clears the cache (useful for testing or memory pressure).
    func clear() {
        cache.removeAll()
        order.removeAll()
    }

    private func moveToFront(_ uid: String) {
        order.removeAll { $0 == uid }
        order.insert(uid, at: 0)
    }

    private func insert(_ uid: String, _ icon: NSImage) {
        cache[uid] = icon
        order.insert(uid, at: 0)

        // Evict oldest entries if over capacity
        while order.count > maxSize {
            if let removed = order.popLast() {
                cache.removeValue(forKey: removed)
            }
        }
    }
}
