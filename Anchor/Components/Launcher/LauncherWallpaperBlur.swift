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
import SwiftUI

/// Pre-warms and caches edge-clamped Gaussian-blurred desktop wallpapers per display.
final class LauncherWallpaperCache {
    static let shared = LauncherWallpaperCache()

    private struct Entry {
        let url: URL
        let image: NSImage
    }

    private var cache: [String: Entry] = [:]
    private let lock = NSLock()
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    private init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prewarmAll()
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.prewarmAll()
        }
    }

    func screenKey(for screen: NSScreen) -> String {
        "\(screen.frame.origin.x)_\(screen.frame.origin.y)_\(screen.frame.size.width)x\(screen.frame.size.height)"
    }

    func image(for screen: NSScreen) -> NSImage? {
        guard let currentURL = NSWorkspace.shared.desktopImageURL(for: screen) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if let entry = cache[screenKey(for: screen)], entry.url == currentURL {
            return entry.image
        }
        return nil
    }

    func store(_ image: NSImage, url: URL, for screen: NSScreen) {
        lock.lock()
        defer { lock.unlock() }
        cache[screenKey(for: screen)] = Entry(url: url, image: image)
    }

    func renderBlur(for screen: NSScreen) -> (URL, NSImage)? {
        guard let url = NSWorkspace.shared.desktopImageURL(for: screen),
              let ciImage = CIImage(contentsOf: url) else { return nil }

        let scale = screen.backingScaleFactor
        let targetSize = CGSize(width: screen.frame.width * scale, height: screen.frame.height * scale)
        guard targetSize.width > 0, targetSize.height > 0, ciImage.extent.width > 0, ciImage.extent.height > 0 else { return nil }

        let scaleX = targetSize.width / ciImage.extent.width
        let scaleY = targetSize.height / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        // Clamping to extent prevents edge bleed / border transparency
        let clamped = scaledImage.clampedToExtent()
        guard let filter = CIFilter(name: "CIGaussianBlur") else { return nil }
        filter.setValue(clamped, forKey: kCIInputImageKey)
        filter.setValue(45.0 * scale, forKey: kCIInputRadiusKey)

        guard let output = filter.outputImage?.cropped(to: CGRect(origin: .zero, size: targetSize)),
              let cgImage = context.createCGImage(output, from: CGRect(origin: .zero, size: targetSize)) else {
            return nil
        }
        return (url, NSImage(cgImage: cgImage, size: screen.frame.size))
    }

    func prewarmAll() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            for screen in NSScreen.screens {
                if let (url, img) = self.renderBlur(for: screen) {
                    self.store(img, url: url, for: screen)
                }
            }
        }
    }
}

/// Background presenter that provides true desktop wallpaper blur or live open windows blur.
struct LauncherWallpaperBlur: View {
    @Default(.launcherBackgroundStyle) private var backgroundStyle
    @State private var wallpaperImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if backgroundStyle == .desktopWallpaper {
                if let wallpaperImage {
                    Image(nsImage: wallpaperImage)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .overlay(
                            Color.black.opacity(colorScheme == .dark ? 0.35 : 0.18)
                        )
                } else {
                    VisualEffectBlurView(material: .fullScreenUI, blendingMode: .behindWindow)
                        .overlay(
                            Color.black.opacity(colorScheme == .dark ? 0.30 : 0.15)
                        )
                }
            } else {
                VisualEffectBlurView(material: .fullScreenUI, blendingMode: .behindWindow)
                    .overlay(
                        Color.black.opacity(colorScheme == .dark ? 0.28 : 0.14)
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            loadWallpaper()
        }
        .onChange(of: backgroundStyle) { _, _ in
            loadWallpaper()
        }
    }

    private func loadWallpaper() {
        guard backgroundStyle == .desktopWallpaper else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let targetScreen = screen else { return }

        if let cached = LauncherWallpaperCache.shared.image(for: targetScreen) {
            self.wallpaperImage = cached
        } else {
            Task.detached(priority: .userInitiated) {
                if let (url, img) = LauncherWallpaperCache.shared.renderBlur(for: targetScreen) {
                    LauncherWallpaperCache.shared.store(img, url: url, for: targetScreen)
                    await MainActor.run {
                        self.wallpaperImage = img
                    }
                }
            }
        }
    }
}

/// AppKit Visual Effect View representable for high performance system glass.
struct VisualEffectBlurView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .fullScreenUI
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}
