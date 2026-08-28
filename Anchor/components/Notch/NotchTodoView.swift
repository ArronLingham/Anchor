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

/// The to-do tab: type a line, tick it off.
struct NotchTodoView: View {
    @ObservedObject private var todo = TodoManager.shared
    @Default(.todoShowCompleted) private var showCompleted

    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @FocusState private var draftFocused: Bool

    var body: some View {
        VStack(spacing: 6) {
            entryField

            if todo.items.isEmpty {
                empty
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    // MARK: - Entry

    private var entryField: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.circle")
                .font(.system(size: 13))
                .foregroundStyle(.white.opacity(0.45))

            TextField("Add a task", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .focused($draftFocused)
                .onSubmit(commitDraft)

            if !todo.doneItems.isEmpty {
                Button {
                    todo.clearCompleted()
                } label: {
                    Text("Clear done")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                }
                .buttonStyle(.plain)
                .help("Remove every ticked item")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.07)))
    }

    private func commitDraft() {
        todo.add(draft)
        draft = ""
        // Keep focus so several items can be typed in a row.
        draftFocused = true
    }

    // MARK: - List

    private var empty: some View {
        VStack(spacing: 5) {
            Image(systemName: "checklist")
                .font(.system(size: 20, weight: .light))
                .foregroundStyle(.white.opacity(0.45))
            Text("Nothing to do")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var list: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 2) {
                ForEach(todo.openItems) { item in
                    row(item)
                }

                if showCompleted, !todo.doneItems.isEmpty {
                    Divider()
                        .background(.white.opacity(0.12))
                        .padding(.vertical, 3)

                    ForEach(todo.doneItems) { item in
                        row(item)
                    }
                }
            }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func row(_ item: TodoItem) -> some View {
        HStack(spacing: 8) {
            Button {
                todo.toggle(item)
            } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.isDone ? .green : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help(item.isDone ? "Mark as not done" : "Mark as done")

            if editingID == item.id {
                TextField("", text: $editingText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.white)
                    .onSubmit {
                        todo.setTitle(editingText, for: item)
                        editingID = nil
                    }
                    .onExitCommand { editingID = nil }
            } else {
                Text(item.title)
                    .font(.system(size: 12))
                    .strikethrough(item.isDone, color: .white.opacity(0.35))
                    .foregroundStyle(item.isDone ? .white.opacity(0.35) : .white.opacity(0.9))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editingText = item.title
                        editingID = item.id
                    }
            }

            Spacer(minLength: 4)

            if let due = item.dueDate, !item.isDone {
                Text(dueLabel(due))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(item.isOverdue ? .red : .white.opacity(0.45))
            }

            if let color = item.priority.todoPriorityColor, !item.isDone {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }

            Button {
                todo.delete(item)
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.3))
            }
            .buttonStyle(.plain)
            .help("Delete")
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .contextMenu {
            Menu("Priority") {
                ForEach(0...3, id: \.self) { level in
                    Button(level.todoPriorityLabel) { todo.setPriority(level, for: item) }
                }
            }
            Button("Due today") {
                todo.setDueDate(Calendar.current.startOfDay(for: Date()), for: item)
            }
            Button("Due tomorrow") {
                let tomorrow = Calendar.current.date(
                    byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: Date()))
                todo.setDueDate(tomorrow, for: item)
            }
            if item.dueDate != nil {
                Button("Clear due date") { todo.setDueDate(nil, for: item) }
            }
            Divider()
            Button("Delete", role: .destructive) { todo.delete(item) }
        }
    }

    /// Short relative label — "Today", "Tomorrow", otherwise a date.
    private func dueLabel(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return String(localized: "Today") }
        if calendar.isDateInTomorrow(date) { return String(localized: "Tomorrow") }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }
}
