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

struct MenuBarSettings: View {
    @Default(.enableMenuBarShrink) private var enabled
    @Default(.menuBarAutoHideSeconds) private var autoHideSeconds
    @Default(.menuBarAlwaysHiddenSection) private var alwaysHidden

    @ObservedObject private var manager = MenuBarShrinkManager.shared

    private func highlightID(_ title: String) -> String {
        SettingsTab.menuBar.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableMenuBarShrink) {
                    Text("Shrink the menu bar")
                }
                .settingsHighlight(id: highlightID("Shrink the menu bar"))

                KeyboardShortcuts.Recorder("Show or hide:", name: .toggleMenuBarSection)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Show or hide"))
            } footer: {
                Text(
                    "Adds a chevron to the menu bar. Anything you ⌘-drag to the "
                    + "left of it is hidden until you click it.\n\n"
                    + "There is no API for hiding another app's menu bar item, and "
                    + "no private one worth using. What this does instead is what "
                    + "every app of this kind does: the menu bar lays out right to "
                    + "left, so a very wide item pushes everything left of it off "
                    + "the screen. Nothing is injected into another process and no "
                    + "permission is needed — but it does mean you arrange your own "
                    + "menu bar by dragging.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Behaviour") {
                Picker("Hide again after", selection: $autoHideSeconds) {
                    Text("Never").tag(0)
                    Text("5 seconds").tag(5)
                    Text("10 seconds").tag(10)
                    Text("30 seconds").tag(30)
                    Text("1 minute").tag(60)
                }
                .disabled(!enabled)
                .settingsHighlight(id: highlightID("Hide again after"))
                .help("A one-shot timer, armed only while the items are showing.")

                Toggle("Add an always-hidden section", isOn: $alwaysHidden)
                    .disabled(!enabled)
                    .settingsHighlight(id: highlightID("Add an always-hidden section"))
                    .help(
                        "A second divider. Anything dragged to the left of it stays "
                        + "hidden even when the first section is showing — for items "
                        + "you never want to see but cannot remove.")
            }

            Section("Now") {
                LabeledContent("Divider") {
                    Text(manager.isActive
                         ? (manager.isCollapsed ? "Collapsed" : "Showing")
                         : "Not installed")
                    .foregroundStyle(.secondary)
                }
                Button(manager.isCollapsed ? "Show Items" : "Hide Items") {
                    manager.toggle()
                }
                .disabled(!manager.isActive)
                .settingsHighlight(id: highlightID("Show Items"))
            }
        }
    }
}
