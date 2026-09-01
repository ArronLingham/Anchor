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

import Combine
import Defaults
import Foundation

/// The to-do list.
///
/// Entirely event-driven: it is a store with no clock. Nothing here schedules,
/// polls or wakes — an item with a due date goes red because the *view* asks
/// what the date is when it draws, not because anything is watching it. That
/// keeps a list of a thousand items exactly as expensive at idle as an empty
/// one, which is zero.
@MainActor
final class TodoManager: ObservableObject {
    static let shared = TodoManager()

    @Published var items: [TodoItem] = [] {
        didSet {
            guard !isLoading else { return }
            Defaults[.savedTodos] = items
        }
    }

    private var isLoading = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        isLoading = true
        items = Defaults[.savedTodos]
        isLoading = false

        // Another window (or a future import) writing the key directly should
        // still show up here.
        Defaults.publisher(.savedTodos)
            .sink { [weak self] change in
                guard let self, change.newValue != self.items else { return }
                self.isLoading = true
                self.items = change.newValue
                self.isLoading = false
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived

    var openItems: [TodoItem] { sorted.filter { !$0.isDone } }
    var doneItems: [TodoItem] {
        // Most recently ticked first — the undo you are most likely to want.
        items.filter(\.isDone).sorted {
            ($0.completedAt ?? $0.createdAt) > ($1.completedAt ?? $1.createdAt)
        }
    }

    var openCount: Int { items.lazy.filter { !$0.isDone }.count }
    var overdueCount: Int { items.lazy.filter(\.isOverdue).count }

    /// The open items in the user's chosen order.
    ///
    /// `.manual` returns the array as stored, which is what drag-to-reorder
    /// writes; every other case is a pure sort over a copy.
    private var sorted: [TodoItem] {
        switch Defaults[.todoSortOrder] {
        case .manual:
            return items
        case .created:
            return items.sorted { $0.createdAt > $1.createdAt }
        case .priority:
            return items.sorted {
                $0.priority == $1.priority
                    ? $0.createdAt < $1.createdAt
                    : $0.priority > $1.priority
            }
        case .dueDate:
            // Items with no due date sort last rather than first, which is what
            // `nil` would do if it were treated as the distant past.
            return items.sorted { lhs, rhs in
                switch (lhs.dueDate, rhs.dueDate) {
                case let (l?, r?): return l == r ? lhs.createdAt < rhs.createdAt : l < r
                case (nil, _?): return false
                case (_?, nil): return true
                case (nil, nil): return lhs.createdAt < rhs.createdAt
                }
            }
        }
    }

    // MARK: - Mutation

    @discardableResult
    func add(_ title: String, dueDate: Date? = nil, priority: Int = 0) -> TodoItem? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item = TodoItem(title: trimmed, dueDate: dueDate, priority: priority)
        // Newest at the top in manual order, so a just-typed item is where you
        // are already looking.
        items.insert(item, at: 0)
        return item
    }

    /// One completion that can still be taken back.
    ///
    /// Only the most recent is kept: a deeper stack would mean holding items the
    /// user has already moved on from, and the point of this is catching the tick
    /// you did not mean, not browsing history.
    struct CompletionUndo {
        let item: TodoItem
        let index: Int
    }

    @Published private(set) var lastCompletion: CompletionUndo?

    /// Completes an item and takes it off the list.
    ///
    /// The item is not deleted until another completion replaces it in the undo
    /// slot, so ⌘Z puts it back exactly where it was rather than at the end.
    func complete(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var completed = items[index]
        completed.isDone = true
        completed.completedAt = Date()
        lastCompletion = CompletionUndo(item: completed, index: index)
        items.remove(at: index)
    }

    /// Puts the last completed item back where it was.
    @discardableResult
    func undoLastCompletion() -> Bool {
        guard let undo = lastCompletion else { return false }
        var restored = undo.item
        restored.isDone = false
        restored.completedAt = nil
        items.insert(restored, at: min(undo.index, items.count))
        lastCompletion = nil
        return true
    }

    func toggle(_ item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].isDone.toggle()
        items[index].completedAt = items[index].isDone ? Date() : nil
    }

    func setTitle(_ title: String, for item: TodoItem) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == item.id })
        else { return }
        items[index].title = trimmed
    }

    func setDueDate(_ date: Date?, for item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].dueDate = date
    }

    func setPriority(_ priority: Int, for item: TodoItem) {
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].priority = max(0, min(3, priority))
    }

    func delete(_ item: TodoItem) {
        items.removeAll { $0.id == item.id }
    }

    func clearCompleted() {
        items.removeAll(where: \.isDone)
    }

    /// Moves items within the open list. Only meaningful in manual order.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard Defaults[.todoSortOrder] == .manual else { return }
        items.move(fromOffsets: source, toOffset: destination)
    }
}
