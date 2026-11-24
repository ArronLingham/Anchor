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
import CoreImage
import Defaults
import ImageIO
import AnchorUtilities
import SwiftUI

/// Only wallpaper mode needs a bitmap. Decode a small thumbnail off the main actor
/// and keep enough for two displays. The system material handles the live backdrop.
private actor LauncherWallpaperCache {
    static let shared = LauncherWallpaperCache()
    private final class Entry {
        let modified: Date?
        let image: CGImage

        init(modified: Date?, image: CGImage) {
            self.modified = modified
            self.image = image
        }
    }

    private let cache = NSCache<NSURL, Entry>()
    private let context = CIContext(options: [.cacheIntermediates: false])

    private init() { cache.countLimit = 2 }

    func image(for url: URL) -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        if let cached = cache.object(forKey: url as NSURL), cached.modified == modified { return cached.image }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 640
        ]
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              !Task.isCancelled else { return nil }
        let input = CIImage(cgImage: thumbnail)
        let blurred = input.clampedToExtent().applyingGaussianBlur(sigma: 10)
        guard let output = context.createCGImage(blurred, from: input.extent), !Task.isCancelled else { return nil }
        cache.setObject(Entry(modified: modified, image: output), forKey: url as NSURL)
        return output
    }
}

struct LauncherBackdrop: View {
    let mode: LauncherPresentationMode
    let screen: NSScreen?
    let onDismiss: () -> Void
    @Default(.launcherBackgroundStyle) private var style
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var wallpaper: CGImage?

    private var wallpaperURL: URL? {
        guard style == .desktopWallpaper, !reduceTransparency, let screen else { return nil }
        return NSWorkspace.shared.desktopImageURL(for: screen)
    }

    var body: some View {
        let radius: CGFloat = mode == .floaty ? 24 : 0
        let shape = AnchorCorners.rectangle(cornerRadius: radius)
        ZStack {
            if reduceTransparency {
                AnchorDesign.canvas
            } else {
                LauncherGlass()
                if style == .desktopWallpaper, let wallpaper {
                    GeometryReader { geometry in
                        Image(decorative: wallpaper, scale: 1)
                            .resizable()
                            .scaledToFill()
                            .frame(width: geometry.size.width, height: geometry.size.height)
                            .clipped()
                    }
                    .opacity(0.82)
                }
                LinearGradient(colors: [AnchorDesign.surface.opacity(0.24), AnchorDesign.canvas.opacity(0.48)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipShape(shape)
        .overlay {
            if mode == .floaty {
                shape.anchorStrokeBorder(Color.white.opacity(contrast == .increased ? 0.50 : 0.18), lineWidth: 1)
            }
        }
        .contentShape(shape)
        .onTapGesture { if mode == .fullscreen { onDismiss() } }
        .accessibilityHidden(true)
        .task(id: wallpaperURL) {
            wallpaper = nil
            guard let url = wallpaperURL else { return }
            let image = await LauncherWallpaperCache.shared.image(for: url)
            guard !Task.isCancelled else { return }
            wallpaper = image
        }
        .ignoresSafeArea()
    }
}

private struct LauncherGlass: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
