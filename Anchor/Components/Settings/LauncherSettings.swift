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

import Defaults
import KeyboardShortcuts
import SwiftUI

struct LauncherSettings: View {
    @ObservedObject private var index = AppIndex.shared
    @ObservedObject private var navigationShortcuts = SystemNavigationShortcutManager.shared
    @Default(.enableLauncher) private var enableLauncher
    @Default(.enableShortcuts) private var enableShortcuts
    @Default(.launcherShowGridWhenEmpty) private var showGrid
    @Default(.launcherLayoutMode) private var launcherLayoutMode
    @Default(.launcherSortMode) private var launcherSortMode
    @Default(.launcherNavigationStyle) private var launcherNavigationStyle
    @Default(.launcherPresentationMode) private var presentationMode
    @Default(.launcherBackgroundStyle) private var backgroundStyle
    @Default(.launcherHotCorner) private var hotCorner
    @Default(.launcherShowCategoryPage) private var showCategoryPage
    @Default(.launcherRecallSeconds) private var launcherRecallSeconds
    @Default(.launcherCustomOrder) private var launcherCustomOrder
    @Default(.launcherFolders) private var launcherFolders
    @Default(.launcherShowVinylWidget) private var showMusicWidget
    @Default(.launcherWidgetSize) private var musicWidgetSize
    @Default(.playerWindowLevel) private var playerWindowLevel
    @Default(.playerBackgroundOpacity) private var playerBackgroundOpacity
    @Default(.lockFullBackground) private var fullPlayerBackground

    @State private var didClearHistory = false
    @State private var didClearIcons = false
    @State private var showingPlayerLayoutEditor = false

    @Default(.enableAppSwitcher) private var enableAppSwitcher
    @Default(.launcherUsesCommandSpace) private var useCommandSpace
    @Default(.appSwitcherUsesCommandTab) private var useCommandTab
    @Default(.appSwitcherRingDiameter) private var appSwitcherRingDiameter

    private func highlightID(_ title: String) -> String {
        SettingsTab.launcher.highlightID(for: title)
    }

    var body: some View {
        Form {
            QuicklinkSettingsSection()
            Section {
                Defaults.Toggle(key: .launcherReduceAnimations) { Text("Reduce animations") }
                    .help("Open and close the launcher and switcher without animation.")
                Defaults.Toggle(key: .enableLauncher) {
                    Text("Enable Launcher")
                }
                .settingsHighlight(id: highlightID("Enable Launcher"))

                Defaults.Toggle(key: .enableShortcutsLauncher) {
                    Text("Show Apple Shortcuts")
                }
                .settingsHighlight(id: highlightID("Show Apple Shortcuts"))
                .settingsInfo("Adds your Apple Shortcuts to the launcher so you can run one by name. The list is read once from the Shortcuts app and refreshed only when you ask \u{2014} nothing is queried while you type.")

                KeyboardShortcuts.Recorder("Open launcher:", name: .toggleLauncher)
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Open launcher"))

                Defaults.Toggle(key: .launcherUsesCommandSpace) {
                    Text("Use ⌘Space for Launchpad")
                }
                .disabled(!enableLauncher)
                .settingsInfo("Replaces Spotlight while Anchor is running. Your other launcher shortcut still works.")
                .settingsHighlight(id: highlightID("Use ⌘Space for Launchpad"))
                shortcutAvailabilityHint(requested: enableLauncher && useCommandSpace)

                Button("Preview launcher") {
                    LauncherPanelManager.shared.show()
                }
                .disabled(!enableLauncher)
            } header: {
                Text("Launcher")
            } footer: {
                Text("Press the shortcut, type a few letters, press Return.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .enableAppSwitcher) {
                    Text("Enable app switcher")
                }
                .settingsHighlight(id: highlightID("Enable app switcher"))

                Defaults.Toggle(key: .appSwitcherUsesCommandTab) {
                    Text("Use ⌘Tab for Anchor’s app switcher")
                }
                .disabled(!enableAppSwitcher)
                .settingsInfo("Hold Command and tap Tab to cycle. Add Shift to go backwards; release Command to switch.")
                .settingsHighlight(id: highlightID("Use ⌘Tab for Anchor’s app switcher"))
                shortcutAvailabilityHint(requested: enableAppSwitcher && useCommandTab)

                KeyboardShortcuts.Recorder("Open switcher:", name: .appSwitcher)
                    .disabled(!enableAppSwitcher)
                    .settingsHighlight(id: highlightID("Open switcher"))

                KeyboardShortcuts.Recorder("Open switcher backwards:", name: .appSwitcherReverse)
                    .disabled(!enableAppSwitcher)
                    .settingsHighlight(id: highlightID("Open switcher backwards"))
                    .settingsInfo("Steps backwards through the ring, the way ⌘⇧Tab does. Defaults to ⌥⇧Tab.")

                Slider(value: $appSwitcherRingDiameter, in: 280...560, step: 20) {
                    Text("Ring size")
                } minimumValueLabel: {
                    Text("S").font(.caption)
                } maximumValueLabel: {
                    Text("L").font(.caption)
                }
                .disabled(!enableAppSwitcher)
                .settingsHighlight(id: highlightID("Ring size"))
            } header: {
                Text("App switcher")
            } footer: {
                Text(
                    "The ring opens at your pointer and stays within the active display. Running apps are most recently used first — hold the "
                    + "shortcut and tap Tab to go round, release to switch. Type to filter. Return "
                    + "confirms, Escape cancels, ⌘W closes the highlighted app, and "
                    + "the pointer can pick any of them directly. Keyboard control needs Accessibility. "
                    + "The standard macOS shortcuts return when Anchor quits or these replacements are turned off.")
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .launcherShowGridWhenEmpty) {
                    Text("Show all apps when the field is empty")
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Show all apps when the field is empty"))

                if showGrid {
                    Picker("When typing", selection: $launcherLayoutMode) {
                        ForEach(LauncherLayoutMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("When typing"))

                    Picker("Order", selection: $launcherSortMode) {
                        ForEach(LauncherSortMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Order"))
                    .settingsInfo("Custom is your own order — drag icons in the grid to set it. Dragging does nothing under the other three, because their positions are derived.")

                    Picker("Paging controls", selection: $launcherNavigationStyle) {
                        ForEach(LauncherNavigationStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Paging"))
                    .settingsInfo("Choose between interactive page dots, a macOS-style scroll bar, or both when deploying the launchpad.")

                    // Both of these are written by dragging in the grid, not
                    // by a control — so without a reset there is no way back
                    // from an arrangement you did not mean to make.
                    HStack {
                        Button("Reset custom order") {
                            Defaults[.launcherCustomOrder] = []
                        }
                        .disabled(!enableLauncher || launcherCustomOrder.isEmpty)
                        Spacer()
                        Text(launcherCustomOrder.isEmpty
                             ? "Not set" : "\(launcherCustomOrder.count) placed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsHighlight(id: highlightID("Reset custom order"))

                    HStack {
                        Button("Remove all folders") {
                            Defaults[.launcherFolders] = [:]
                        }
                        .disabled(!enableLauncher || launcherFolders.isEmpty)
                        Spacer()
                        Text(launcherFolders.isEmpty
                             ? "None" : "\(launcherFolders.count) folders")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .settingsHighlight(id: highlightID("Remove all folders"))
                    .settingsInfo("Removing a folder puts its apps back in the grid; nothing is uninstalled.")

                    Text("Grid automatically fills your screen with an optimal amount of apps.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("An empty field will show your most-used apps as a list.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Grid")
            }

            Section {
                Picker("Presentation mode", selection: $presentationMode) {
                    ForEach(LauncherPresentationMode.allCases) { mode in
                        Text(mode.localizedName).tag(mode)
                    }
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Presentation mode"))
                .settingsInfo("Fullscreen Launchpad covers the display with an immersive grid. Floaty Panel floats a sleek centered window.")

                Picker("Background blur style", selection: $backgroundStyle) {
                    ForEach(LauncherBackgroundStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Background style"))
                .settingsInfo("Choose whether Launchpad blurs your desktop wallpaper (ignoring open windows) or blurs whatever windows and apps are currently open on your screen (e.g. Safari).")

                Picker("Hot corner trigger", selection: $hotCorner) {
                    ForEach(LauncherHotCorner.allCases) { corner in
                        Text(corner.localizedName).tag(corner)
                    }
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Hot corner trigger"))
                .settingsInfo("Move the cursor into this screen corner to open the launcher effortlessly.")

                Defaults.Toggle(key: .launcherShowCategoryPage) {
                    Text("Show categories tab")
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Show categories tab"))
                .settingsInfo("Organizes apps into categorized library collections (Developer Tools, Productivity, Social, Games, etc.).")

                LabeledContent("Remember the last search for") {
                    Picker("", selection: $launcherRecallSeconds) {
                        Text("Off").tag(0.0)
                        Text("3 seconds").tag(3.0)
                        Text("5 seconds").tag(5.0)
                        Text("15 seconds").tag(15.0)
                        Text("1 minute").tag(60.0)
                    }
                    .labelsHidden()
                    .fixedSize()
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Remember the last search for"))
                .settingsInfo("Reopen within this long and your previous search is still in the field. After it, the field opens empty.")
            } header: {
                Text("Presentation & Behavior")
            }

            Section {
                Defaults.Toggle(key: .launcherShowClockWidget) { Text("Clock") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Clock"))
                Defaults.Toggle(key: .launcherShowWeatherWidget) { Text("Weather") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Weather"))
                Defaults.Toggle(key: .launcherShowCalendarWidget) { Text("Calendar") }
                    .disabled(!enableLauncher)
                Defaults.Toggle(key: .launcherShowRemindersWidget) { Text("Reminders") }
                    .disabled(!enableLauncher)
                Defaults.Toggle(key: .launcherShowVinylWidget) { Text("Now playing") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Now playing"))
                    .settingsInfo("A music player in the launcher with playback controls and seeking.")
                if showMusicWidget {
                    Picker("Music player size", selection: $musicWidgetSize) {
                        ForEach(LauncherPlayerWidget.Size.allCases, id: \.self) { size in
                            Text(size.label).tag(size)
                        }
                    }
                    Defaults.Toggle(key: .launcherAlwaysShowsControls) {
                        Text("Always show music controls")
                    }
                }
            } header: {
                Text("Widgets")
            } footer: {
                Text("Choose the cards and controls that are useful in your launcher.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cadence player") {
                Defaults.Toggle(key: .enablePlayerWidget) {
                    Text("Show desktop music player")
                }
                Picker("Desktop position", selection: $playerWindowLevel) {
                    ForEach(PlayerWindowLevel.allCases, id: \.self) { level in
                        Text(level.label).tag(level)
                    }
                }
                Defaults.Toggle(key: .playerUsesGlass) { Text("Glass background") }
                Defaults.Toggle(key: .playerTintsWithAlbum) { Text("Tint from album art") }
                LabeledContent("Background opacity") {
                    Slider(value: $playerBackgroundOpacity, in: 0.15...1)
                        .frame(width: 180)
                }
                Defaults.Toggle(key: .hoverGrowsWidget) { Text("Grow for controls on hover") }
                Defaults.Toggle(key: .playerFollowsSpaces) { Text("Show on all desktops") }
                Defaults.Toggle(key: .volumeControlsApp) { Text("Control app volume") }
                Defaults.Toggle(key: .useCadenceLockLayouts) {
                    Text("Use Cadence layouts on the lock screen")
                }
                Picker("Full-screen background", selection: $fullPlayerBackground) {
                    Text("Blurred artwork").tag(LockFullBackground.blurredArtwork)
                    Text("Album colour").tag(LockFullBackground.albumColour)
                }
                Button("Customize all player layouts…") {
                    showingPlayerLayoutEditor = true
                }
                .sheet(isPresented: $showingPlayerLayoutEditor) {
                    LayoutEditorView()
                }
            }

            Section {
                Defaults.Toggle(key: .launcherEnableCalculator) {
                    Text("Evaluate arithmetic")
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Evaluate arithmetic"))

                Defaults.Toggle(key: .launcherShowPaths) {
                    Text("Show file paths in results")
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Show file paths in results"))
            } header: {
                Text("Results")
            } footer: {
                Text("Typing something like 18*7.5 shows the answer; Return copies it.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }

            Section {
                LabeledContent("Indexed applications") {
                    if index.isIndexing {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("\(index.apps.count)")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }

                Button("Rebuild index now") {
                    index.refresh()
                }
                .disabled(!enableLauncher || index.isIndexing)
                .settingsHighlight(id: highlightID("Rebuild index now"))

                Button(didClearHistory ? "Ranking reset" : "Reset ranking") {
                    LaunchHistory.shared.reset()
                    didClearHistory = true
                }
                .disabled(!enableLauncher || didClearHistory)
                .settingsHighlight(id: highlightID("Reset ranking"))

                Button(didClearIcons ? "Icon cache cleared" : "Clear icon cache") {
                    AppIconCache.shared.clear()
                    didClearIcons = true
                }
                .disabled(!enableLauncher || didClearIcons)
                .settingsHighlight(id: highlightID("Clear icon cache"))
            } header: {
                Text("Index")
            } footer: {
                Text(
                    "Results are ordered by how often and how recently you launch each app. Resetting puts everything back to alphabetical."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
    }

    @ViewBuilder private func shortcutAvailabilityHint(requested: Bool) -> some View {
        if requested && enableShortcuts && !navigationShortcuts.isAvailable {
            Text("This shortcut is unavailable. Check Anchor’s Accessibility permission in System Settings, then return to Anchor.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
