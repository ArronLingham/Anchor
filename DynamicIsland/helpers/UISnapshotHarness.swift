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
import Sparkle
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
    /// Debug-only. The harness renders settings panes, and a settings pane may
    /// read a credential to display it — `ClaudeUsageSettings` loads the ntfy
    /// topic out of the Keychain on `onAppear`. In a signed Release that turned
    /// the Keychain ACL into a no-op: the process doing the reading *is* Anchor,
    /// so securityd hands the secret over without a prompt, and the harness then
    /// writes it to a PNG at a path the caller chose via the environment. Anyone
    /// running as the user could `open -n /Applications/Anchor.app
    /// --env ANCHOR_RENDER_UI=/tmp/x` and read the topic out of the image.
    static var requestedDirectory: URL? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["ANCHOR_RENDER_UI"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        #else
        return nil
        #endif
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
            let viewModel = DynamicIslandViewModel()

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

                await capture(
                    ClaudeUsageSettings()
                        .formStyle(.grouped)
                        .environmentObject(highlight),
                    size: CGSize(width: 720, height: 860),
                    scheme: scheme,
                    to: directory.appendingPathComponent("settings-claude-usage-\(suffix).png"))

                // Every remaining settings pane. These were one 7,784-line file
                // until they were split out, and nothing else exercises them
                // without opening the window and clicking each tab.
                for pane in settingsPanes(highlight: highlight, viewModel: viewModel) {
                    await capture(
                        pane.view,
                        size: pane.size,
                        scheme: scheme,
                        to: directory.appendingPathComponent("settings-\(pane.name)-\(suffix).png"))
                }
            }

            NSLog("UISnapshotHarness: wrote snapshots to \(directory.path)")
            exit(0)
        }
    }

    /// Every pane reachable from the settings sidebar.
    ///
    /// One tall canvas for all of them rather than a hand-tuned size each: the
    /// point is to catch a pane that renders empty or crashes, and whitespace at
    /// the bottom of a short pane costs nothing. A pane that outgrows this will
    /// be visibly cut off, which is itself the signal to raise it.
    @MainActor
    private static func settingsPanes(
        highlight: SettingsHighlightCoordinator,
        viewModel: DynamicIslandViewModel
    ) -> [(name: String, size: CGSize, view: AnyView)] {
        let size = CGSize(width: 720, height: 1200)

        func pane<V: View>(_ name: String, _ view: V) -> (String, CGSize, AnyView) {
            (name, size, AnyView(
                view
                    .formStyle(.grouped)
                    .environmentObject(highlight)
                    .environmentObject(viewModel)))
        }

        return [
            pane("general", GeneralSettings()),
            pane("charge", Charge()),
            pane("downloads", Downloads()),
            pane("hud", HUD()),
            pane("media", Media()),
            pane("calendar", CalendarSettings()),
            // startingUpdater: false, matching DynamicIslandApp. Sparkle must
            // never run here — every channel in UpdateChannel points at upstream
            // Atoll's appcast, and a live updater replaced Anchor with upstream
            // once already.
            pane("about", About(updaterController: SPUStandardUpdaterController(
                startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil))),
            pane("live-activities", LiveActivitiesSettings()),
            pane("appearance", Appearance()),
            pane("lock-screen", LockScreenSettings()),
            pane("shortcuts", Shortcuts()),
            pane("timer", TimerSettings()),
            pane("clipboard", ClipboardSettings()),
            pane("custom-osd", CustomOSDSettings()),
            pane("notes", NotesSettingsView()),
            pane("terminal", TerminalSettings()),
        ]
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
