/*
 * Anchor
 * Copyright (C) 2026 Anchor Contributors
 * GPL-3.0-or-later. See LICENSE and NOTICE.
 */

import EventKit
import Foundation

/// EventKit-backed Reminders card. This is separate from Anchor's local to-do
/// store so it can show every Apple Reminders list without enabling sync.
@MainActor
final class LauncherAppleReminders: ObservableObject {
    static let shared = LauncherAppleReminders()

    struct Item: Identifiable {
        let id: String
        let title: String
        let dueDate: Date?
    }

    @Published private(set) var items: [Item] = []
    @Published private(set) var hasAccess = false
    @Published private(set) var errorMessage: String?
    private var lastRefreshDate: Date?

    private let store = EKEventStore()
    private init() {}

    func refresh(force: Bool = false) async {
        do {
            if !force, hasAccess, let last = lastRefreshDate,
               Date().timeIntervalSince(last) < 15 { return }
            if EKEventStore.authorizationStatus(for: .reminder) == .notDetermined {
                _ = try await store.requestFullAccessToReminders()
            }
            hasAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
            guard hasAccess else {
                items = []
                return
            }

            let calendars = store.calendars(for: .reminder)
            guard !calendars.isEmpty else {
                items = []
                return
            }
            let predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
            let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                store.fetchReminders(matching: predicate) { result in
                    continuation.resume(returning: result ?? [])
                }
            }
            items = reminders.map {
                Item(id: $0.calendarItemIdentifier, title: $0.title,
                     dueDate: $0.dueDateComponents?.date)
            }
            .sorted {
                let left = $0.dueDate ?? .distantFuture
                let right = $1.dueDate ?? .distantFuture
                if left != right { return left < right }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            errorMessage = nil
            lastRefreshDate = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func add(_ title: String) async -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAccess, !title.isEmpty,
              let calendar = store.defaultCalendarForNewReminders()
        else { errorMessage = "Choose a default list in Reminders and allow access."; return false }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        do {
            try store.save(reminder, commit: true)
            await refresh(force: true)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func complete(_ item: Item) async {
        guard hasAccess,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
        else { return }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try store.save(reminder, commit: true)
            await refresh(force: true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
