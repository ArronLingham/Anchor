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
import SwiftUI

/// Background presenter that provides true desktop wallpaper blur with fallback to macOS material glass.
struct LauncherWallpaperBlur: View {
    @Default(.launcherBackgroundStyle) private var backgroundStyle
    @State private var wallpaperImage: NSImage?
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            if backgroundStyle == .wallpaperBlur, let wallpaperImage {
                Image(nsImage: wallpaperImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .blur(radius: 40)
                    .overlay(
                        Color.black.opacity(colorScheme == .dark ? 0.35 : 0.20)
                    )
            } else {
                VisualEffectBlurView(material: .fullScreenUI, blendingMode: .behindWindow)
                    .overlay(
                        Color.black.opacity(colorScheme == .dark ? 0.30 : 0.15)
                    )
            }
        }
        .ignoresSafeArea()
        .onAppear {
            loadWallpaper()
        }
    }

    private func loadWallpaper() {
        guard backgroundStyle == .wallpaperBlur else { return }
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        guard let targetScreen = screen,
              let imageURL = NSWorkspace.shared.desktopImageURL(for: targetScreen) else {
            return
        }

        // Load off the main thread if needed
        Task.detached(priority: .userInitiated) {
            if let img = NSImage(contentsOf: imageURL) {
                await MainActor.run {
                    self.wallpaperImage = img
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
