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
import AppKit
import SwiftUI

/// The to-do tab: type a line, tick it off.
struct NotchTodoView: View {
    @ObservedObject private var todo = TodoManager.shared
    @Default(.todoShowCompleted) private var showCompleted

    @State private var draft = ""
    @State private var editingID: UUID?
    @State private var editingText = ""
    @FocusState private var draftFocused: Bool

    @State private var undoMonitor: Any?

    var body: some View {
        VStack(spacing: 6) {
            entryField

            if todo.items.isEmpty {
                empty
            } else {
                list
            }

            if todo.lastCompletion != nil {
                undoBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .animation(.easeInOut(duration: 0.16), value: todo.lastCompletion?.item.id)
        .onAppear(perform: installUndoMonitor)
        .onDisappear(perform: removeUndoMonitor)
    }

    /// Shown only while something can actually be taken back.
    private var undoBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.uturn.backward")
                .font(.system(size: 10))
            Text(todo.lastCompletion.map { "Completed \"\($0.item.title)\"" } ?? "")
                .font(.system(size: 10))
                .lineLimit(1)
            Spacer(minLength: 4)
            Button("Undo") { todo.undoLastCompletion() }
                .buttonStyle(.plain)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(.white.opacity(0.06)))
        .transition(.opacity.combined(with: .move(edge: .bottom)))
    }

    /// ⌘Z while the tab is on screen.
    ///
    /// A local monitor rather than `.keyboardShortcut`: the notch is a
    /// non-activating panel, so SwiftUI's shortcut plumbing never sees the
    /// event. ⌃Z is accepted too, since that is what the request asked for.
    private func installUndoMonitor() {
        guard undoMonitor == nil else { return }
        undoMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard event.charactersIgnoringModifiers?.lowercased() == "z",
                  event.modifierFlags.contains(.command) || event.modifierFlags.contains(.control),
                  !event.modifierFlags.contains(.shift)
            else { return event }

            return MainActor.assumeIsolated {
                todo.undoLastCompletion() ? nil : event
            }
        }
    }

    private func removeUndoMonitor() {
        if let undoMonitor { NSEvent.removeMonitor(undoMonitor) }
        undoMonitor = nil
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
                todo.complete(item)
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
        // Without this the row only right-clicks where a label happens to be
        // drawn — the gaps between the title, the due date and the delete
        // button hit nothing at all, which reads as "the context menu is
        // broken".
        .contentShape(Rectangle())
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
