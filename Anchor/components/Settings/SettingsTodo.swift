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
import SwiftUI

struct TodoSettings: View {
    @Default(.enableTodoFeature) private var enableTodoFeature
    @Default(.todoSortOrder) private var sortOrder
    @Default(.todoShowCompleted) private var showCompleted

    @ObservedObject private var todo = TodoManager.shared
    @State private var showingClearConfirmation = false

    private func highlightID(_ title: String) -> String {
        SettingsTab.todo.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableTodoFeature) {
                    Text("Enable to-do list")
                }
                .settingsHighlight(id: highlightID("Enable to-do list"))
                .help("Adds a To-Do tab to the notch.")
            } footer: {
                Text(
                    "A plain checklist stored on this Mac. Separate from Apple "
                    + "Reminders, which Anchor reads for the Calendar tab and the "
                    + "lock-screen widget — this is somewhere to write something "
                    + "down without going near EventKit.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("List") {
                Picker("Sort by", selection: $sortOrder) {
                    ForEach(TodoSortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                .disabled(!enableTodoFeature)
                .settingsHighlight(id: highlightID("Sort by"))
                .help("Manual keeps whatever order you drag things into.")

                Toggle("Show completed items", isOn: $showCompleted)
                    .disabled(!enableTodoFeature)
                    .settingsHighlight(id: highlightID("Show completed items"))
                    .help("Off hides ticked items instead of showing them below a divider.")
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
        }
        .confirmationDialog(
            "Delete every to-do item?",
            isPresented: $showingClearConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All", role: .destructive) { todo.items.removeAll() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}
