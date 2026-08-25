/*
 * Atoll (DynamicIsland)
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

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    /// Concurrent on purpose. Rasterising an .icns and writing its PNG takes
    /// long enough that a serial queue warms roughly five icons per second —
    /// the grid showed placeholders for everything past the first row. Each
    /// entry writes to its own file and NSCache is thread-safe, so there is
    /// nothing to serialise.
    private let io = DispatchQueue(
        label: "com.anchor.app-icon-cache", qos: .utility, attributes: .concurrent)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        // Versioned: v1 stored whatever `tiffRepresentation` produced, which was
        // the full-size .icns slice. Reading those back would keep the old
        // 1024x1024 images alive indefinitely, because the cache key is derived
        // from the app path and mtime and neither of those changed.
        directory = base.appendingPathComponent("Anchor/AppIcons-v2", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        // Reclaim v1. Off the calling thread: this deleted 129 MB on the machine
        // where the bug was found, and per CLAUDE.md nothing in a manager's init
        // may block.
        let legacy = base.appendingPathComponent("Anchor/AppIcons", isDirectory: true)
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.removeItem(at: legacy)
        }

        memory.countLimit = 512
    }

    /// Returns a cached icon immediately if there is one, otherwise nil and
    /// calls `completion` on the main queue once the icon has been produced.
    func icon(for app: LauncherApp, completion: @escaping (NSImage) -> Void) -> NSImage? {
        let key = cacheKey(for: app)

        if let hit = memory.object(forKey: key as NSString) { return hit }

        io.async { [weak self] in
            guard let self else { return }
            let image: NSImage
            if let onDisk = self.readFromDisk(key: key) {
                image = onDisk
            } else {
                image = self.render(app)
                self.writeToDisk(image, key: key)
            }
            self.memory.setObject(image, forKey: key as NSString)
            DispatchQueue.main.async { completion(image) }
        }
        return nil
    }

    /// Renders and caches icons for `apps` ahead of them being shown.
    ///
    /// Without this, the first open of the grid is a sheet of grey placeholders:
    /// every visible tile requests its icon at once, and each request rasterises
    /// an .icns and writes a PNG on a single serial queue. Warming after the
    /// index scan moves that cost off the moment the user is looking.
    func warm(_ apps: [LauncherApp]) {
        for app in apps {
            let key = cacheKey(for: app)
            guard memory.object(forKey: key as NSString) == nil else { continue }
            io.async { [weak self] in
                guard let self else { return }
                guard self.memory.object(forKey: key as NSString) == nil else { return }
                let image = self.readFromDisk(key: key) ?? {
                    let rendered = self.render(app)
                    self.writeToDisk(rendered, key: key)
                    return rendered
                }()
                self.memory.setObject(image, forKey: key as NSString)
            }
        }
    }

    func clear() {
        memory.removeAllObjects()
        io.async { [directory] in
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: - Internals

    /// Keyed by path *and* modification date, so an app update invalidates its
    /// icon rather than showing the old one forever.
    private func cacheKey(for app: LauncherApp) -> String {
        let modified =
            (try? app.url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let raw = "\(app.url.path)|\(Int(modified))"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func render(_ app: LauncherApp) -> NSImage {
        Self.rasterised(NSWorkspace.shared.icon(forFile: app.url.path))
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
