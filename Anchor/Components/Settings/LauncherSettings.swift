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
    @Default(.enableLauncher) private var enableLauncher
    @Default(.launcherShowGridWhenEmpty) private var showGrid
    @Default(.launcherLayoutMode) private var launcherLayoutMode
    @Default(.launcherSortMode) private var launcherSortMode
    @Default(.launcherNavigationStyle) private var launcherNavigationStyle
    @Default(.launcherRecallSeconds) private var launcherRecallSeconds
    @Default(.launcherCustomOrder) private var launcherCustomOrder
    @Default(.launcherFolders) private var launcherFolders
    @Default(.launcherGridColumns) private var columns
    @Default(.launcherGridRows) private var rows

    @State private var didClearHistory = false
    @State private var didClearIcons = false

    @Default(.enableAppSwitcher) private var enableAppSwitcher
    @Default(.appSwitcherRingDiameter) private var appSwitcherRingDiameter

    private func highlightID(_ title: String) -> String {
        SettingsTab.launcher.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
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

                KeyboardShortcuts.Recorder("Open switcher:", name: .appSwitcher)
                    .disabled(!enableAppSwitcher)
                    .settingsHighlight(id: highlightID("Open switcher"))

                KeyboardShortcuts.Recorder("Open switcher backwards:", name: .appSwitcherReverse)
                    .disabled(!enableAppSwitcher)
                    .settingsHighlight(id: highlightID("Open switcher backwards"))
                    .settingsInfo("Steps backwards through the ring, the way ⌘⇧Tab does. Defaults to ⌥⇧Tab.")

                Slider(value: $appSwitcherRingDiameter, in: 300...640, step: 20) {
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
                    "Running apps in a ring, most recently used first — hold the "
                    + "shortcut and tap Tab to go round, release to switch. Return "
                    + "confirms, Escape cancels, W closes the highlighted app, and "
                    + "the pointer can pick any of them directly.\n\n"
                    + "The system ⌘Tab is left alone: taking it over means "
                    + "swallowing it with an event tap, and an app that swallows "
                    + "⌘Tab and then hangs leaves you with no way to switch apps "
                    + "at all. Keyboard control needs Accessibility; without it the "
                    + "ring still opens and the pointer still works.")
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
                    // LabeledContent wrapping the Stepper, rather than the other
                    // way round, so the value sits on the trailing edge like
                    // every other value row instead of butting against its label.
                    LabeledContent("Columns") {
                        Stepper("\(columns)", value: $columns, in: 3...12)
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Columns"))

                    LabeledContent("Rows") {
                        Stepper("\(rows)", value: $rows, in: 2...8)
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Rows"))

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

                    Picker("Paging", selection: $launcherNavigationStyle) {
                        ForEach(LauncherNavigationStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Paging"))
                    .settingsInfo("Moving the pointer to either edge of the grid always turns the page, whichever of these is shown.")

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

                    Text("\(columns * rows) apps per page.")
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
                Defaults.Toggle(key: .launcherFullScreen) {
                    Text("Fill the screen")
                }
                .disabled(!enableLauncher)
                .settingsHighlight(id: highlightID("Fill the screen"))
                .settingsInfo("Blurs the whole display behind the launcher and dismisses on a click anywhere outside it. With this off the launcher floats over what is already there.")

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
                Text("Panel")
            }

            Section {
                Defaults.Toggle(key: .launcherShowClockWidget) { Text("Clock") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Clock"))
                Defaults.Toggle(key: .launcherShowWeatherWidget) { Text("Weather") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Weather"))
                Defaults.Toggle(key: .launcherShowVinylWidget) { Text("Now playing") }
                    .disabled(!enableLauncher)
                    .settingsHighlight(id: highlightID("Now playing"))
                    .settingsInfo("A record showing what is playing. Clicking it opens the vinyl player on the desktop.")
            } header: {
                Text("Widgets")
            } footer: {
                Text("All three are off by default — the launcher's job is finding an app, so anything sitting permanently above the grid has to earn the space.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
}
