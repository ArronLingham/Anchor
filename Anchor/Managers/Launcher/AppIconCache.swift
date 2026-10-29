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
import CryptoKit
import Foundation

/// Two-tier icon cache for the launcher.
///
/// `NSWorkspace.icon(forFile:)` reads the app bundle from disk and rasterises
/// from an `.icns` on every call. Doing that per row, per keystroke, is the
/// standard way a launcher quietly becomes expensive — so icons are rendered
/// once at display size, held in memory, and persisted as PNGs so the cost is
/// not paid again on the next launch.
final class AppIconCache {
    static let shared = AppIconCache()

    /// Rendered size in points. The grid draws at 56.
    static let iconSize = CGSize(width: 64, height: 64)

    /// Backing scale the PNGs are rasterised at. 2 covers every Retina display
    /// at this size, and is what the built-in panel runs at.
    private static let iconScale = 2

    private final class Entry: NSObject {
        let image: NSImage
        let revision: String
        init(image: NSImage, revision: String) {
            self.image = image
            self.revision = revision
        }
    }

    private struct PendingLoad {
        let id = UUID()
        var completions: [(NSImage) -> Void]
    }

    /// One purgeable cache: aliases in a second cache kept images alive after
    /// the first evicted them. Charge decoded pixels, rather than PNG bytes.
    private let memory = NSCache<NSString, Entry>()
    private let directory: URL
    private let renderer: (LauncherApp) -> NSImage
    private let lock = NSLock()
    private var pending: [String: PendingLoad] = [:]
    private var generation = 0
    /// Bound peak .icns decoding memory and disk work during a full index scan.
    private let io: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.anchor.app-icon-cache"
        queue.qualityOfService = .utility
        queue.maxConcurrentOperationCount = 2
        return queue
    }()

    init(directory: URL? = nil, renderer: @escaping (LauncherApp) -> NSImage = {
        AppIconCache.rasterised(NSWorkspace.shared.icon(forFile: $0.url.path))
    }) {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        self.directory = directory ?? base.appendingPathComponent("Anchor/AppIcons-v2", isDirectory: true)
        self.renderer = renderer
        // Directory creation and legacy cleanup belong off the caller's thread.
        io.addBarrierBlock { [directory = self.directory] in
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        if directory == nil {
            let legacy = base.appendingPathComponent("Anchor/AppIcons", isDirectory: true)
            io.addOperation { try? FileManager.default.removeItem(at: legacy) }
        }
        memory.countLimit = 256
        memory.totalCostLimit = 24 * 1_024 * 1_024
    }

    /// Returns immediately on a hit. Concurrent warm/grid/switcher misses
    /// share one decode and receive their completions on the main queue.
    func icon(for app: LauncherApp, completion: @escaping (NSImage) -> Void) -> NSImage? {
        if let hit = memory.object(forKey: app.url.path as NSString) { return hit.image }
        enqueue(app, completion: completion)
        return nil
    }

    /// Revalidate revisions after an application-directory change. Existing
    /// entries avoid decoding; visible requests join an in-flight warm instead
    /// of decoding and writing the same image again.
    func warm(_ apps: [LauncherApp]) {
        for app in apps { enqueue(app, completion: nil) }
    }

    private func enqueue(_ app: LauncherApp, completion: ((NSImage) -> Void)?) {
        let path = app.url.path
        lock.lock()
        if pending[path] != nil {
            if let completion { pending[path]?.completions.append(completion) }
            lock.unlock()
            return
        }
        let load = PendingLoad(completions: completion.map { [$0] } ?? [])
        let requestedGeneration = generation
        pending[path] = load
        // Enqueue while locked so clear's barrier always follows earlier work.
        io.addOperation { [weak self] in
            autoreleasepool {
                guard let self else { return }
                let key = self.cacheKey(for: app)
                let image: NSImage
                if let entry = self.memory.object(forKey: path as NSString), entry.revision == key {
                    image = entry.image
                } else if let diskImage = self.readFromDisk(key: key) {
                    image = diskImage
                } else {
                    image = self.renderer(app)
                    self.writeToDisk(image, key: key)
                }
                self.lock.lock()
                guard self.pending[path]?.id == load.id else {
                    self.lock.unlock()
                    return
                }
                let callbacks = self.pending.removeValue(forKey: path)?.completions ?? []
                let pixelBytes = Int(Self.iconSize.width * Self.iconSize.height)
                    * Self.iconScale * Self.iconScale * 4
                self.memory.setObject(Entry(image: image, revision: key),
                                      forKey: path as NSString, cost: pixelBytes)
                self.lock.unlock()
                guard !callbacks.isEmpty else { return }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    let current = self.generation == requestedGeneration
                    self.lock.unlock()
                    if current { callbacks.forEach { $0(image) } }
                }
            }
        }
        lock.unlock()
    }

    func clear() {
        lock.lock()
        generation += 1
        pending.removeAll()
        memory.removeAllObjects()
        io.cancelAllOperations()
        // Wait for already-running writes before deleting, and finish before
        // accepting new work. Old requests cannot repopulate the cleared cache.
        io.addBarrierBlock { [directory] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        lock.unlock()
    }

    // MARK: - Internals

    /// Keyed by path *and* modification date, so an app update invalidates its
    /// icon rather than showing the old one forever.
    private func cacheKey(for app: LauncherApp) -> String {
        let modified =
            (try? URL(fileURLWithPath: app.url.path).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let raw = "\(app.url.path)|\(Int(modified))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Draws `image` into a bitmap of exactly the size this cache stores.
    ///
    /// `NSImage.size` is a logical hint; it does not touch the underlying
    /// representations. `NSWorkspace.icon(forFile:)` returns every slice in the
    /// .icns up to 1024x1024, and `tiffRepresentation` serialises the largest of
    /// them — so assigning `.size` and writing produced 1024x1024 PNGs of up to
    /// 3 MB each for icons that are drawn at 56pt. The cache reached 129 MB over
    /// 87 apps before anyone looked. Rasterise, don't relabel.
    private static func rasterised(_ image: NSImage) -> NSImage {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(iconSize.width) * iconScale,
            pixelsHigh: Int(iconSize.height) * iconScale,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0)
        else {
            // Nothing sensible to fall back to but the original.
            image.size = iconSize
            return image
        }
        rep.size = iconSize

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(
            in: NSRect(origin: .zero, size: iconSize),
            from: .zero,
            operation: .copy,
            fraction: 1.0)
        NSGraphicsContext.restoreGraphicsState()

        let output = NSImage(size: iconSize)
        output.addRepresentation(rep)
        return output
    }

    private func fileURL(for key: String) -> URL {
        directory.appendingPathComponent("\(key).png")
    }

    private func readFromDisk(key: String) -> NSImage? {
        let url = fileURL(for: key)
        guard let data = try? Data(contentsOf: url), let image = NSImage(data: data) else {
            return nil
        }
        image.size = Self.iconSize
        return image
    }

    private func writeToDisk(_ image: NSImage, key: String) {
        // `render` produces a single bitmap rep at the stored size; use it
        // directly. Falling back through `tiffRepresentation` picks the largest
        // representation, which is what wrote 1024x1024 PNGs in v1.
        let existing = image.representations.compactMap { $0 as? NSBitmapImageRep }.first
        guard
            let rep = existing ?? image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: fileURL(for: key), options: .atomic)
    }
}
