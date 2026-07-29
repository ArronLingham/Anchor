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

    /// Rendered size in points. Retina backing is handled by the NSImage size.
    static let iconSize = CGSize(width: 64, height: 64)

    private let memory = NSCache<NSString, NSImage>()
    private let directory: URL
    /// Concurrent on purpose. Rasterising an .icns and writing its PNG takes
    /// long enough that a serial queue warms roughly five icons per second —
    /// the grid showed placeholders for everything past the first row. Each
    /// entry writes to its own file and NSCache is thread-safe, so there is
    /// nothing to serialise.
    private let io = DispatchQueue(
        label: "com.atoll.app-icon-cache", qos: .utility, attributes: .concurrent)

    private init() {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        directory = base.appendingPathComponent("Anchor/AppIcons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
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
        let icon = NSWorkspace.shared.icon(forFile: app.url.path)
        icon.size = Self.iconSize
        return icon
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
        guard
            let tiff = image.tiffRepresentation,
            let rep = NSBitmapImageRep(data: tiff),
            let png = rep.representation(using: .png, properties: [:])
        else { return }
        try? png.write(to: fileURL(for: key), options: .atomic)
    }
}
