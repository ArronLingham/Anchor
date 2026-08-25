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
import AVFoundation
import Combine
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import Sparkle
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

// Extracted from SettingsView.swift, originally created by
// Richard Kunkli on 07/08/2024. Behaviour unchanged.

struct NotesSettingsView: View {
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject var coordinator = AnchorViewCoordinator.shared
    @ObservedObject private var appleNotesSync = AppleNotesSyncManager.shared
    @Default(.enableNotes) private var enableNotes
    @Default(.enableAppleNotesSync) private var enableAppleNotesSync
    @Default(.appleNotesLastSyncDate) private var appleNotesLastSyncDate

    private func highlightID(_ title: String) -> String {
        SettingsTab.notes.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableNotes) {
                    Text("Enable Notes")
                }
                if enableNotes {
                    Defaults.Toggle(key: .enableNotePinning) {
                        Text("Enable Note Pinning")
                    }
                    Defaults.Toggle(key: .enableNoteSearch) {
                        Text("Enable Note Search")
                    }
                    Defaults.Toggle(key: .enableNoteColorFiltering) {
                        Text("Enable Color Filtering")
                    }
                    Defaults.Toggle(key: .enableCreateFromClipboard) {
                        Text("Enable Create from Clipboard")
                    }
                    Defaults.Toggle(key: .enableNoteCharCount) {
                        Text("Show Character Count")
                    }
                }
            } header: {
                Text("General")
            } footer: {
                Text("Customize how you organize and create notes. Enabling color filtering and search helps manage large lists.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if enableNotes {
                Section {
                    Defaults.Toggle(key: .enableAppleNotesSync) {
                        Text("Sync with Apple Notes")
                    }
                    .settingsHighlight(id: highlightID("Sync with Apple Notes"))

                    if enableAppleNotesSync {
                        Button {
                            Task {
                                let notes = Defaults[.savedNotes]
                                if let merged = await appleNotesSync.sync(localNotes: notes) {
                                    Defaults[.savedNotes] = merged
                                }
                            }
                        } label: {
                            HStack {
                                Text("Sync Now")
                                Spacer()
                                if appleNotesSync.isSyncing {
                                    ProgressView()
                                        .controlSize(.small)
                                }
                            }
                        }
                        .disabled(appleNotesSync.isSyncing)
                        .settingsHighlight(id: highlightID("Sync Now"))

                        if let lastSync = appleNotesLastSyncDate {
                            LabeledContent("Last synced") {
                                Text(lastSync, style: .relative)
                                    .foregroundStyle(.secondary)
                            }
                        }

                        if let error = appleNotesSync.lastError {
                            Text(error)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                } header: {
                    Text("Apple Notes")
                } footer: {
                    Text("Two-way sync with the macOS Notes app. Notes created in Atoll appear in the Atoll folder in Notes, and your existing Apple Notes are imported into the notch. Grant Automation permission for Notes when prompted.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("Notes")
    }
}

// MARK: - Terminal Settings
