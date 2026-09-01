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
import SwiftUI

/// Reclaimable space, and what removing each kind costs.
///
/// The consequence line under every row is not decoration. "Caches" sounds
/// free, and two of these are not: clearing app caches signs the user out of
/// some apps, and clearing derived data makes their next build of every project
/// a full one. Both start unticked for that reason.
struct SettingsCleanup: View {
    @ObservedObject private var manager = CleanupManager.shared
    @ObservedObject private var updates = PackageUpdateManager.shared
    @State private var isConfirming = false

    private func highlightID(_ title: String) -> String {
        SettingsTab.cleanup.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                if manager.findings.isEmpty {
                    HStack {
                        Text(manager.isScanning
                             ? "Measuring…"
                             : "Nothing measured yet.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Scan") { Task { await manager.scan() } }
                            .disabled(manager.isScanning)
                            .settingsHighlight(id: highlightID("Scan"))
                    }
                } else {
                    ForEach(manager.findings) { finding in
                        Toggle(isOn: Binding(
                            get: { finding.isSelected },
                            set: { _ in manager.toggle(finding.id) })) {
                            VStack(alignment: .leading, spacing: 1) {
                                HStack {
                                    Text(finding.category.title)
                                    Spacer()
                                    Text(CleanupSafety.formatBytes(finding.bytes))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                Text(finding.category.consequence)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }

                    HStack {
                        Text("Selected: \(CleanupSafety.formatBytes(manager.selectedBytes))")
                            .monospacedDigit()
                        Spacer()
                        Button("Rescan") { Task { await manager.scan() } }
                            .disabled(manager.isScanning)
                        Button("Move to Trash") { isConfirming = true }
                            .disabled(manager.selectedBytes == 0)
                            .settingsHighlight(id: highlightID("Move to Trash"))
                    }
                }

                if let result = manager.lastResult {
                    Text(result)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Reclaim space")
            } footer: {
                Text("Everything here is moved to the Trash, never deleted — if something turns out to matter you can drag it back. Anchor will not empty the Trash for you, deliberately: that is the one step you cannot undo.\n\nOnly the locations listed are ever touched. Anchor does not search your home folder for things that look like caches.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                if updates.isChecking {
                    Text("Checking\u{2026}").foregroundStyle(.secondary)
                } else if updates.outdated.isEmpty && updates.apps.isEmpty {
                    HStack {
                        Text(updates.brewAvailable
                             ? "Nothing checked yet."
                             : "Homebrew was not found \u{2014} only applications will be listed.")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Check") { Task { await updates.check() } }
                            .settingsHighlight(id: highlightID("Check for updates"))
                    }
                } else {
                    ForEach(updates.outdated) { package in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(package.name)
                                Text("\(package.installed) \u{2192} \(package.available)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .monospacedDigit()
                            }
                            Spacer()
                            if package.isPinned {
                                Text("pinned")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button("Upgrade\u{2026}") { updates.upgradeInTerminal(package) }
                            }
                        }
                    }

                    ForEach(updates.apps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(app.name)
                                Text("version \(app.version) \u{2014} check in the app")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Open") { NSWorkspace.shared.open(URL(fileURLWithPath: app.path)) }
                        }
                    }

                    HStack {
                        Spacer()
                        Button("Re-check") { Task { await updates.check() } }
                    }
                }

                if let error = updates.lastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text("Updates")
            } footer: {
                Text("Outdated Homebrew packages, and applications that ship their own updater. Upgrading opens Terminal so you can see exactly what runs and stop it \u{2014} Anchor never upgrades anything silently, and pinned formulae are listed but never offered, because a pin means you chose that version.\n\nApp Store apps are not listed: they update through the App Store and there would be nothing to do from here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Move \(CleanupSafety.formatBytes(manager.selectedBytes)) to the Trash?",
            isPresented: $isConfirming, titleVisibility: .visible
        ) {
            Button("Move to Trash") { _ = manager.cleanSelected(); Task { await manager.scan() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Nothing is deleted. You can restore anything from the Trash.")
        }
    }
}
