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
            let viewModel = AnchorViewModel()

            // The lyrics tab renders an "off" placeholder unless the feature is
            // enabled, and the key defaults to false. Flip it for the render and
            // put it back before exiting — this runs against the real defaults
            // domain, and a snapshot run must not change the user's settings.
            let lyricsWereEnabled = Defaults[.enableLyrics]
            Defaults[.enableLyrics] = true

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

                // The lyrics tab, seeded so it renders the real list rather
                // than its "nothing playing" state. MusicManager.shared is the
                // only source these views read, and this process exits without
                // ever starting playback.
                await capture(
                    seededLyricsTab(timed: true),
                    size: CGSize(width: 560, height: 260),
                    scheme: scheme,
                    to: directory.appendingPathComponent("notch-lyrics-\(suffix).png"))

                // The untimed variant: LRCLIB frequently has only a plain
                // version, and that path renders differently.
                await capture(
                    seededLyricsTab(timed: false),
                    size: CGSize(width: 560, height: 260),
                    scheme: scheme,
                    to: directory.appendingPathComponent("notch-lyrics-untimed-\(suffix).png"))

                // The lock screen's immersive player, with and without lyrics
                // — the layout differs, since artwork centres when there is no
                // lyric column to sit beside.
                await capture(
                    seededImmersivePlayer(withLyrics: true),
                    size: CGSize(width: 1280, height: 800),
                    scheme: scheme,
                    to: directory.appendingPathComponent("lockscreen-immersive-lyrics-\(suffix).png"))
                await capture(
                    seededImmersivePlayer(withLyrics: false),
                    size: CGSize(width: 1280, height: 800),
                    scheme: scheme,
                    to: directory.appendingPathComponent("lockscreen-immersive-plain-\(suffix).png"))

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

            // Restored explicitly rather than with `defer`: exit() terminates
            // the process without unwinding, so a deferred block never runs.
            Defaults[.enableLyrics] = lyricsWereEnabled

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
        viewModel: AnchorViewModel
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
            // startingUpdater: false, matching AnchorApp. Sparkle must
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

    /// The lyrics tab with fixture lyrics in place.
    ///
    /// Positioned mid-song so the render shows what actually matters: the
    /// current line highlighted, the neighbours fading with distance, and lines
    /// both above and below it.
    @MainActor
    private static func seededLyricsTab(timed: Bool) -> AnyView {
        let manager = MusicManager.shared

        guard timed else {
            // Untimed lyrics: every stamp 0, which is what
            // `MusicManager.untimedLines(from:)` produces from a plain blob.
            manager.syncedLyrics = MusicManager.untimedLines(from: """
                Emiliana, it's been so long since you texted me
                I finally took a break and now I feel like I'm on ecstasy
                You say what my work means to me will one day be the death of me
                But I keep going anyway
                """)
            manager.currentLyricIndex = -1
            manager.currentLyrics = ""
            return AnyView(NotchLyricsView().padding(12).background(Color.black))
        }

        // Setting `currentLyricIndex` directly does not hold: MusicManager runs
        // a 300 ms sync task that recomputes it from the playback position, and
        // with nothing playing every fixture timestamp is already in the past,
        // so it settles on the final line and the render shows no lines below
        // the highlight. Instead the later timestamps are pushed past any
        // position that task can produce, which pins the current line at index 2
        // no matter when the capture lands.
        let farFuture: TimeInterval = 86_400
        manager.syncedLyrics = [
            LyricLine(timestamp: 0, text: "Is this the real life?"),
            LyricLine(timestamp: 4, text: "Is this just fantasy?"),
            LyricLine(timestamp: 8, text: "Caught in a landslide"),
            LyricLine(timestamp: farFuture, text: "No escape from reality"),
            LyricLine(timestamp: farFuture + 4, text: "Open your eyes"),
            LyricLine(timestamp: farFuture + 8, text: "Look up to the skies and see"),
        ]
        manager.currentLyricIndex = 2
        manager.currentLyrics = manager.syncedLyrics[2].text
        return AnyView(NotchLyricsView().padding(12).background(Color.black))
    }

    @MainActor
    private static func seededImmersivePlayer(withLyrics: Bool) -> AnyView {
        let manager = MusicManager.shared
        manager.songTitle = "Bohemian Rhapsody"
        manager.artistName = "Queen"
        manager.isPlaying = true
        if withLyrics {
            _ = seededLyricsTab(timed: true)
        } else {
            manager.syncedLyrics = []
        }
        return AnyView(LockScreenImmersivePlayer())
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
