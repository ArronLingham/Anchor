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
import SwiftUI

/// Renders UI to PNGs so it can be reviewed without a screen-recording grant.
///
/// Set `ANCHOR_RENDER_UI` to a directory and launch the app: it writes a
/// snapshot of each major surface there and exits. Development aid only.
///
/// Uses a real `NSHostingView` in a window rather than `ImageRenderer`, because
/// ImageRenderer draws a placeholder for AppKit-backed controls (`TextField`
/// comes out as a solid yellow bar) and never materialises lazy containers, so
/// a `LazyHStack` of app tiles renders completely empty.
enum UISnapshotHarness {
    static var requestedDirectory: URL? {
        ProcessInfo.processInfo.environment["ANCHOR_RENDER_UI"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
    }

    @MainActor
    static func renderAndExit(into directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)

        AppIndex.shared.refresh()

        Task { @MainActor in
            // Let the index scan and the first icons land, or the grid would be
            // a sheet of placeholder rectangles.
            try? await Task.sleep(for: .seconds(4))

            let highlight = SettingsHighlightCoordinator()

            for scheme in [ColorScheme.dark, ColorScheme.light] {
                let suffix = scheme == .dark ? "dark" : "light"

                await capture(
                    LauncherView(onLaunch: { _ in }, onDismiss: {}),
                    size: CGSize(width: 860, height: 560),
                    scheme: scheme,
                    to: directory.appendingPathComponent("launcher-grid-\(suffix).png"))

                // Settings panes are Forms; without .formStyle(.grouped) and a
                // window background they render as unstyled floating labels,
                // which is nothing like how they appear in the real window.
                await capture(
                    DictationSettings()
                        .formStyle(.grouped)
                        .environmentObject(highlight),
                    size: CGSize(width: 720, height: 720),
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-dictation-\(suffix).png"))

                await capture(
                    LauncherSettings()
                        .formStyle(.grouped)
                        .environmentObject(highlight),
                    size: CGSize(width: 720, height: 780),
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-launcher-\(suffix).png"))
            }

            NSLog("UISnapshotHarness: wrote snapshots to \(directory.path)")
            exit(0)
        }
    }

    @MainActor
    private static func capture<V: View>(
        _ view: V, size: CGSize, scheme: ColorScheme, to url: URL
    ) async {
        let hosting = NSHostingView(rootView: AnyView(view))
        hosting.frame = NSRect(origin: .zero, size: size)

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        window.contentView = hosting
        window.backgroundColor = .clear
        window.isOpaque = false
        // Appearance has to be set on the window — .environment(\.colorScheme)
        // alone does not reach AppKit-backed controls inside NSHostingView.
        window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        // Must be ordered in for AppKit to build a backing store, but keep it
        // off the visible desktop so this does not flash over the user's screen.
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()

        hosting.layoutSubtreeIfNeeded()
        // Async content — icons, index results — needs a beat to arrive.
        try? await Task.sleep(for: .milliseconds(1200))
        hosting.layoutSubtreeIfNeeded()

        defer { window.orderOut(nil) }

        guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else {
            NSLog("UISnapshotHarness: no bitmap rep for \(url.lastPathComponent)")
            return
        }
        hosting.cacheDisplay(in: hosting.bounds, to: rep)

        guard let png = rep.representation(using: .png, properties: [:]) else {
            NSLog("UISnapshotHarness: PNG encode failed for \(url.lastPathComponent)")
            return
        }
        try? png.write(to: url)
    }
}
