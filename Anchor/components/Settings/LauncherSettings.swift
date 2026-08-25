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
    @Default(.launcherGridColumns) private var columns
    @Default(.launcherGridRows) private var rows

    @State private var didClearHistory = false
    @State private var didClearIcons = false

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
