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
import AnchorUtilities

struct MenuBarSettings: View {
    @Default(.enableMenuBarShrink) private var enabled
    @Default(.menuBarAutoHideSeconds) private var autoHideSeconds
    @Default(.menuBarAlwaysHiddenSection) private var alwaysHidden
    @Default(.menuBarExpandOnHover) private var expandOnHover

    @ObservedObject private var monitoring = UtilitySystemStats.shared
    @StateObject private var arranger = MenuBarItemArranger()

    @ObservedObject private var manager = MenuBarShrinkManager.shared

    private func highlightID(_ title: String) -> String {
        SettingsTab.menuBar.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .menuBarShowCPU) {
                    Text("Show CPU")
                }
                .settingsHighlight(id: highlightID("Show CPU"))

                Defaults.Toggle(key: .menuBarShowMemory) {
                    Text("Show memory")
                }
                .settingsHighlight(id: highlightID("Show memory"))

                Defaults.Toggle(key: .menuBarShowNetwork) {
                    Text("Show network throughput")
                }
                .settingsHighlight(id: highlightID("Show network throughput"))
                Toggle("Keep monitoring when panels are closed", isOn: Binding(
                    get: { monitoring.backgroundMonitoringEnabled },
                    set: { monitoring.setBackgroundMonitoringEnabled($0) }))
            } header: {
                Text("Live readout")
            } footer: {
                Text("Live readings share the Stats panel’s sampler. By default they pause when the panel closes. Enable closed-panel monitoring above to keep menu bar readings and background alerts active. Sampling stops while the display sleeps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .enableMenuBarShrink) {
                    Text("Shrink the menu bar")
                }
                .settingsHighlight(id: highlightID("Shrink the menu bar"))

                if enabled {
                    KeyboardShortcuts.Recorder("Show or hide:", name: .toggleMenuBarSection)
                        .settingsHighlight(id: highlightID("Show or hide"))

                    if alwaysHidden {
                        KeyboardShortcuts.Recorder("Always-hidden:", name: .toggleAlwaysHiddenSection)
                            .settingsHighlight(id: highlightID("Always-hidden"))
                    }
                }
            } footer: {
                Text(
                    "Adds a chevron to the menu bar. Anything you ⌘-drag to the "
                    + "left of it is hidden until you click it.\n\n"
                    + "With 'Add an always-hidden section' enabled, a second divider (/) "
                    + "is added. Click it or ⌥-click the chevron to reveal or hide the "
                    + "always-hidden section while arranging icons.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if enabled {
                Section("Behaviour") {
                    Picker("Hide again after", selection: $autoHideSeconds) {
                        Text("Never").tag(0)
                        Text("5 seconds").tag(5)
                        Text("10 seconds").tag(10)
                        Text("30 seconds").tag(30)
                        Text("1 minute").tag(60)
                    }
                    .settingsHighlight(id: highlightID("Hide again after"))
                    .settingsInfo("A one-shot timer, armed only while the items are showing.")

                    Toggle("Expand on hover", isOn: $expandOnHover)
                        .settingsHighlight(id: highlightID("Expand on hover"))
                        .settingsInfo("Point at the chevron instead of clicking it. The chevron stays on screen either way.")

                    Toggle("Add an always-hidden section", isOn: $alwaysHidden)
                        .settingsHighlight(id: highlightID("Add an always-hidden section"))
                        .settingsInfo(
                            "Adds a second divider (/). Click it or ⌥-click the chevron to show or "
                            + "hide always-hidden items while arranging.")
                }

                if alwaysHidden {
                    iconArrangementSection
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

                    if alwaysHidden {
                        LabeledContent("Always-hidden") {
                            Text(manager.isActive
                                 ? (manager.isAlwaysHiddenRevealed ? "Showing" : "Collapsed")
                                 : "Not installed")
                            .foregroundStyle(.secondary)
                        }
                        Button(manager.isAlwaysHiddenRevealed ? "Hide Always-Hidden" : "Show Always-Hidden") {
                            manager.toggleAlwaysHidden()
                        }
                        .disabled(!manager.isActive)
                        .settingsHighlight(id: highlightID("Show Always-Hidden"))
                    }
                }
            }
        }
        .onDisappear { arranger.end() }
        .onChange(of: enabled) { _, _ in arranger.end() }
        .onChange(of: alwaysHidden) { _, _ in arranger.end() }
    }
    private var iconArrangementSection: some View {
        Section {
            Button(arranger.isArranging ? "Refresh Icons" : "Choose Icons…") {
                arranger.begin()
            }
            .disabled(arranger.isMoving || arranger.isRefreshing)
            .settingsHighlight(id: highlightID("Choose Menu Bar Icons"))
            if arranger.isRefreshing { ProgressView().controlSize(.small) }
            if arranger.isArranging {
                ForEach(arranger.items) { item in
                    HStack {
                        if let icon = item.icon {
                            Image(nsImage: icon).resizable().frame(width: 18, height: 18)
                        }
                        Picker(item.name, selection: Binding(
                            get: { item.section },
                            set: { arranger.move(item, to: $0) }
                        )) {
                            ForEach(MenuBarItemArranger.Section.allCases) { section in
                                Text(section.label).tag(section)
                            }
                        }
                    }
                    .disabled(arranger.isMoving || arranger.isRefreshing)
                }
                Button("Done Arranging") { arranger.end() }
                    .disabled(arranger.isMoving || arranger.isRefreshing)
            }
            if let error = arranger.error { Text(error).foregroundStyle(.orange).font(.caption) }
        } header: {
            Text("Choose Menu Bar Icons")
        } footer: {
            Text("Choose an icon and set it to Always hidden. Icons are temporarily revealed while arranging, then hidden again when you finish. macOS requires Accessibility access to move icons; fixed system controls cannot be moved.")
        }
    }

}
