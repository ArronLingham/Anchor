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
    @State private var completingIDs: Set<UUID> = []
    @State private var completionTasks: [UUID: Task<Void, Never>] = [:]
    @State private var showUndoBar: Bool = false
    @State private var undoBarDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 6) {
            entryField

            if todo.items.isEmpty {
                empty
            } else {
                list
            }

            if showUndoBar, todo.lastCompletion != nil {
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
            Button("Undo") {
                undoBarDismissTask?.cancel()
                withAnimation(.easeInOut(duration: 0.2)) {
                    showUndoBar = false
                }
                todo.undoLastCompletion()
            }
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

    private func isItemCompleted(_ item: TodoItem) -> Bool {
        item.isDone || completingIDs.contains(item.id)
    }

    private func handleItemToggle(_ item: TodoItem) {
        if completingIDs.contains(item.id) {
            completionTasks[item.id]?.cancel()
            completionTasks.removeValue(forKey: item.id)
            withAnimation(.easeInOut(duration: 0.15)) {
                completingIDs.remove(item.id)
            }
            return
        }

        if item.isDone {
            todo.complete(item)
            return
        }

        withAnimation(.easeInOut(duration: 0.15)) {
            completingIDs.insert(item.id)
        }

        let task = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.2)) {
                    completingIDs.remove(item.id)
                    todo.complete(item)
                    triggerUndoBar()
                }
            }
        }
        completionTasks[item.id] = task
    }

    private func triggerUndoBar() {
        undoBarDismissTask?.cancel()
        withAnimation(.easeInOut(duration: 0.2)) {
            showUndoBar = true
        }
        undoBarDismissTask = Task {
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeInOut(duration: 0.25)) {
                    showUndoBar = false
                }
            }
        }
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
                if let lastPendingID = completingIDs.first {
                    completionTasks[lastPendingID]?.cancel()
                    completionTasks.removeValue(forKey: lastPendingID)
                    withAnimation(.easeInOut(duration: 0.15)) {
                        completingIDs.remove(lastPendingID)
                    }
                    return nil
                }

                if todo.undoLastCompletion() {
                    undoBarDismissTask?.cancel()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showUndoBar = false
                    }
                    return nil
                }
                return event
            }
        }
    }

    private func removeUndoMonitor() {
        if let undoMonitor { NSEvent.removeMonitor(undoMonitor) }
        undoMonitor = nil
        for (id, task) in completionTasks {
            task.cancel()
            if let item = todo.items.first(where: { $0.id == id }) {
                todo.complete(item)
            }
        }
        completionTasks.removeAll()
        completingIDs.removeAll()
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
        let done = isItemCompleted(item)
        return HStack(spacing: 8) {
            Button {
                handleItemToggle(item)
            } label: {
                Image(systemName: done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(done ? .green : .white.opacity(0.45))
            }
            .buttonStyle(.plain)
            .help(done ? "Mark as not done" : "Mark as done")

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
                    .strikethrough(done, color: .white.opacity(0.35))
                    .foregroundStyle(done ? .white.opacity(0.35) : .white.opacity(0.9))
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        editingText = item.title
                        editingID = item.id
                    }
            }

            Spacer(minLength: 4)

            if let due = item.dueDate, !done {
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
