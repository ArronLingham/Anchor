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

    @Published private(set) var items: [TodoItem] = [] {
        didSet {
            guard !isLoading else { return }
            persist()
        }
    }

    @Published private(set) var storageError: String?
    @Published private(set) var storageNeedsRecovery = false

    private var isLoading = false
    private var cancellables = Set<AnyCancellable>()

    private init() {
        isLoading = true
        do { items = try TodoStorage.load() }
        catch {
            storageError = error.localizedDescription
            storageNeedsRecovery = true
        }
        isLoading = false

        // Ensure changes are flushed on app termination
        NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
            .sink { [weak self] _ in
                guard let self else { return }
                guard !self.storageNeedsRecovery else { return }
                self.persist()
            }
            .store(in: &cancellables)

        // Trigger updates when sort preferences change
        Publishers.Merge4(
            Defaults.publisher(.todoSortOrder).map { _ in () },
            Defaults.publisher(.todoSortInverted).map { _ in () },
            Defaults.publisher(.todoSecondarySortOrder).map { _ in () },
            Defaults.publisher(.todoSecondarySortInverted).map { _ in () }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.objectWillChange.send()
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
        TodoSortOrder.sort(
            items,
            order: Defaults[.todoSortOrder],
            inverted: Defaults[.todoSortInverted],
            secondary: Defaults[.todoSecondarySortOrder],
            secondaryInverted: Defaults[.todoSecondarySortInverted]
        )
    }

    // MARK: - Mutation

    @discardableResult
    func add(_ title: String, dueDate: Date? = nil, priority: Int = 0) -> TodoItem? {
        guard !storageNeedsRecovery else { return nil }
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

    /// Completion is stored on disk too, so a crash cannot erase the done pile.
    func complete(_ item: TodoItem) {
        guard !storageNeedsRecovery, let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        lastCompletion = CompletionUndo(item: items[index], index: index)
        var updated = items[index]
        updated.isDone = true
        updated.completedAt = Date()
        items[index] = updated
    }

    @discardableResult
    func undoLastCompletion() -> Bool {
        guard !storageNeedsRecovery, let undo = lastCompletion,
              let index = items.firstIndex(where: { $0.id == undo.item.id }) else { return false }
        var restored = items[index]
        restored.isDone = undo.item.isDone
        restored.completedAt = undo.item.completedAt
        items[index] = restored
        lastCompletion = nil
        return true
    }

    func toggle(_ item: TodoItem) {
        guard !storageNeedsRecovery else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        var updated = items[index]
        updated.isDone.toggle()
        updated.completedAt = updated.isDone ? Date() : nil
        items[index] = updated
    }

    func setTitle(_ title: String, for item: TodoItem) {
        guard !storageNeedsRecovery else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = items.firstIndex(where: { $0.id == item.id })
        else { return }
        items[index].title = trimmed
    }

    func setDueDate(_ date: Date?, for item: TodoItem) {
        guard !storageNeedsRecovery else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].dueDate = date
    }

    func setPriority(_ priority: Int, for item: TodoItem) {
        guard !storageNeedsRecovery else { return }
        guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[index].priority = max(0, min(3, priority))
    }

    func delete(_ item: TodoItem) {
        guard !storageNeedsRecovery else { return }
        items.removeAll { $0.id == item.id }
    }

    func deleteAll() {
        guard !storageNeedsRecovery else { return }
        lastCompletion = nil
        items.removeAll()
    }

    func clearCompleted() {
        guard !storageNeedsRecovery else { return }
        items.removeAll(where: \.isDone)
    }

    /// Moves items within the open list. Only meaningful in manual order.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        guard !storageNeedsRecovery else { return }
        guard Defaults[.todoSortOrder] == .manual else { return }
        var open = openItems
        open.move(fromOffsets: source, toOffset: destination)
        var iterator = open.makeIterator()
        items = items.map { $0.isDone ? $0 : (iterator.next() ?? $0) }
    }

    /// Restores items from a backup file or snapshot URL.
    @discardableResult
    func restore(from url: URL) -> Bool {
        do {
            applyRestored(try TodoStorage.restore(from: url))
            return true
        } catch { storageError = error.localizedDescription; return false }
    }

    @discardableResult
    func restoreLatestBackup() -> Bool {
        do {
            applyRestored(try TodoStorage.restoreLatestSnapshot())
            return true
        } catch { storageError = error.localizedDescription; return false }
    }

    private func applyRestored(_ restored: [TodoItem]) {
        isLoading = true
        items = restored
        lastCompletion = nil
        storageNeedsRecovery = false
        storageError = nil
        isLoading = false
    }

    func applySyncedItems(_ updated: [TodoItem]) throws {
        guard !storageNeedsRecovery else { throw TodoFileStore.StorageError.unreadable }
        guard updated != items else { return }
        try TodoStorage.save(updated)
        isLoading = true
        items = updated
        isLoading = false
        storageError = nil
    }

    func retryStorage() {
        if storageNeedsRecovery {
            do { applyRestored(try TodoStorage.load()) }
            catch { storageError = error.localizedDescription }
        } else { persist() }
    }

    private func persist() {
        do { try TodoStorage.save(items); storageError = nil }
        catch { storageError = "Your latest changes could not be fully saved. " + error.localizedDescription }
    }

    /// Exports todos to a specified file URL.
    func export(to url: URL) throws {
        try TodoStorage.export(items: items, to: url)
    }
}
