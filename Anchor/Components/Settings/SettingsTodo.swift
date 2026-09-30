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
import SwiftUI
import UniformTypeIdentifiers

struct TodoSettings: View {
    @Default(.enableTodoFeature) private var enableTodoFeature
    @Default(.todoSortOrder) private var sortOrder
    @Default(.todoSortInverted) private var sortInverted
    @Default(.todoSecondarySortOrder) private var secondarySortOrder
    @Default(.todoSecondarySortInverted) private var secondarySortInverted
    @Default(.todoRemindersSyncEnabled) private var remindersEnabled
    @Default(.todoRemindersListID) private var remindersListID
    @ObservedObject private var remindersSync = TodoRemindersSyncManager.shared
    @Default(.todoShowCompleted) private var showCompleted

    @ObservedObject private var todo = TodoManager.shared
    @State private var showingClearConfirmation = false
    @State private var showingRestoreConfirmation = false
    @State private var exportError: String?
    @State private var restoreURL: URL?

    private func highlightID(_ title: String) -> String {
        SettingsTab.todo.highlightID(for: title)
    }

    private var availableSecondaryOrders: [TodoSecondarySortOrder] {
        TodoSecondarySortOrder.allCases.filter { sec in
            if sec == .none { return true }
            return sec.rawValue != sortOrder.rawValue
        }
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableTodoFeature) {
                    Text("Enable to-do list")
                }
                .settingsHighlight(id: highlightID("Enable to-do list"))
                .settingsInfo("Adds a To-Do tab to the notch.")
            } footer: {
                Text(
                    "Keep a checklist on this Mac, with optional iPhone access through Apple Reminders.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            if enableTodoFeature {
                Section("List") {
                    Picker("Sort by", selection: $sortOrder) {
                        ForEach(TodoSortOrder.allCases, id: \.self) { order in
                            Text(order.label).tag(order)
                        }
                    }
                    .settingsHighlight(id: highlightID("Sort by"))
                    .settingsInfo("Manual keeps whatever order you drag things into.")
                    .onChange(of: sortOrder) { _, newOrder in
                        if secondarySortOrder.rawValue == newOrder.rawValue {
                            secondarySortOrder = .none
                        }
                    }

                    if sortOrder != .manual {
                        Picker("Direction", selection: $sortInverted) {
                            Text(sortOrder.directionLabel(inverted: false)).tag(false)
                            Text(sortOrder.directionLabel(inverted: true)).tag(true)
                        }
                        .settingsHighlight(id: highlightID("Direction"))

                        Picker("Then sort by", selection: $secondarySortOrder) {
                            ForEach(availableSecondaryOrders, id: \.self) { sec in
                                Text(sec.label).tag(sec)
                            }
                        }
                        .settingsHighlight(id: highlightID("Then sort by"))
                        .settingsInfo("Breaks ties when items have the same \(sortOrder.label.lowercased()).")

                        if secondarySortOrder != .none {
                            Picker("Secondary direction", selection: $secondarySortInverted) {
                                Text(secondarySortOrder.directionLabel(inverted: false)).tag(false)
                                Text(secondarySortOrder.directionLabel(inverted: true)).tag(true)
                            }
                            .settingsHighlight(id: highlightID("Secondary direction"))
                        }
                    }

                    Toggle("Show completed items", isOn: $showCompleted)
                        .settingsHighlight(id: highlightID("Show completed items"))
                        .settingsInfo("Off hides ticked items instead of showing them below a divider.")
                }

                Section("Stored") {
                    LabeledContent("Open") { Text("\(todo.openCount)") }
                    LabeledContent("Completed") { Text("\(todo.doneItems.count)") }
                    if todo.overdueCount > 0 {
                        LabeledContent("Overdue") {
                            Text("\(todo.overdueCount)").foregroundStyle(.red)
                        }
                    }

                    HStack {
                        Button("Clear Completed") { todo.clearCompleted() }
                            .disabled(todo.doneItems.isEmpty)
                        Button("Delete All…", role: .destructive) {
                            showingClearConfirmation = true
                        }
                        .disabled(todo.items.isEmpty)
                    }
                    .settingsHighlight(id: highlightID("Clear Completed"))
                }

                phoneSection

                storageSection
            }
        }
        .alert("Export failed", isPresented: Binding(
            get: { exportError != nil }, set: { if !$0 { exportError = nil } }
        )) { Button("OK") { exportError = nil } } message: { Text(exportError ?? "") }
        .confirmationDialog(
            "Delete every to-do item?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { todo.deleteAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .confirmationDialog(
            restoreURL == nil ? "Restore the previous saved list?" : "Restore to-dos from the selected file?",
            isPresented: $showingRestoreConfirmation,
            titleVisibility: .visible
        ) {
            Button("Restore Backup") {
                if let restoreURL { _ = todo.restore(from: restoreURL) }
                else { _ = todo.restoreLatestBackup() }
                restoreURL = nil
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This replaces your current list with the previous saved version. A backup of the current list is kept.")
        }
    }

    private func exportTodos() {
        let panel = NSSavePanel()
        panel.title = "Export To-Dos"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "anchor-todos-\(formatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let destination = panel.url {
            do { try todo.export(to: destination) }
            catch { exportError = error.localizedDescription }
        }
    }
    private var phoneSection: some View {
        Section("iPhone Access") {
            Text("Use Apple Reminders on your iPhone to add tasks, mark them complete, and edit dates or priority. Choose a dedicated iCloud list that appears on both devices.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Load Reminders Lists") { Task { await remindersSync.loadLists() } }
            if !remindersSync.lists.isEmpty {
                Picker("Reminders list", selection: $remindersListID) {
                    Text("Choose a list…").tag("")
                    ForEach(remindersSync.lists) { list in Text(list.name).tag(list.id) }
                }
                .disabled(remindersEnabled || remindersSync.isSyncing)
            }
            Toggle("Sync with Reminders", isOn: $remindersEnabled)
                .settingsHighlight(id: highlightID("Sync with Reminders"))
                .disabled(remindersListID.isEmpty)
            Text("Tasks in the selected list are imported. Anchor tasks are added to it. Turn sync off before changing lists. Use completion for changes on either device; deleting a task on the phone keeps its local copy. If both devices edit the same field offline, Anchor's edit wins.")
                .font(.caption).foregroundStyle(.secondary)
            Text(remindersSync.status).font(.caption)
            if let date = remindersSync.lastSync {
                LabeledContent("Last synced", value: date.formatted(date: .abbreviated, time: .shortened))
            }
            HStack {
                Button(remindersSync.isSyncing ? "Syncing…" : "Sync Now") {
                    Task { await remindersSync.syncNow() }
                }
                .disabled(!remindersEnabled || remindersSync.isSyncing)
                Button("Open Reminders") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.reminders") {
                        NSWorkspace.shared.openApplication(at: url, configuration: .init())
                    }
                }
            }
        }
    }

    private var storageSection: some View {
        Section("Storage & Backup") {
            LabeledContent("Persistence") {
                Text("Saved locally with recovery journal and backups")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let error = todo.storageError {
                Text(error).foregroundStyle(.orange)
                Button("Retry Saving") { todo.retryStorage() }
            }
            let snapshots = TodoStorage.availableSnapshots()
            LabeledContent("Backups") {
                Text("\(snapshots.count) snapshot\(snapshots.count == 1 ? "" : "s") saved")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                Button("Reveal in Finder") {
                    TodoStorage.revealInFinder()
                }

                Button("Export…") {
                    exportTodos()
                }
                .disabled(todo.items.isEmpty)

                Button("Import Backup…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [.json]
                    panel.allowsMultipleSelection = false
                    if panel.runModal() == .OK, let url = panel.url {
                        restoreURL = url
                        showingRestoreConfirmation = true
                    }
                }

                if !snapshots.isEmpty || FileManager.default.fileExists(atPath: TodoStorage.backupURL.path) {
                    Button("Restore Backup…") {
                        restoreURL = nil
                        showingRestoreConfirmation = true
                    }
                }
            }
        }
        .settingsHighlight(id: highlightID("Storage & Backup"))
    }

}
