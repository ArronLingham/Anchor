/*
 * Anchor
 * Copyright (C) 2026 Anchor Contributors
 * GPL-3.0-or-later. See LICENSE and NOTICE.
 */

import Combine
import Defaults
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
    private var consumers = Set<UUID>()
    private var session: UUID?
    private var refreshTask: Task<Void, Never>?
    private var eventObserver: AnyCancellable?
    private var preferences = Set<AnyCancellable>()
    private lazy var store = EKEventStore()

    private init() {
        for key in [Defaults.Key<Bool>.enableLauncher, .launcherShowRemindersWidget] {
            Defaults.publisher(key, options: [])
                .sink { [weak self] _ in
                    if Thread.isMainThread {
                        MainActor.assumeIsolated { self?.reconcileDemand() }
                    } else {
                        DispatchQueue.main.async { self?.reconcileDemand() }
                    }
                }
                .store(in: &preferences)
        }
    }

    func setVisible(_ visible: Bool, id: UUID) {
        if visible { consumers.insert(id) } else { consumers.remove(id) }
        reconcileDemand()
    }

    func session(for consumer: UUID) -> UUID? {
        guard consumers.contains(consumer) else { return nil }
        return session
    }

    private var enabled: Bool {
        Defaults[.enableLauncher] && Defaults[.launcherShowRemindersWidget]
    }

    private func reconcileDemand() {
        guard enabled, !consumers.isEmpty else {
            guard session != nil else { return }
            session = nil
            refreshTask?.cancel()
            refreshTask = nil
            eventObserver = nil
            items = []
            hasAccess = false
            errorMessage = nil
            return
        }
        guard session == nil else { return }
        let session = UUID()
        self.session = session
        eventObserver = NotificationCenter.default.publisher(for: .EKEventStoreChanged)
            .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
            .sink { [weak self] _ in self?.scheduleRefresh(session: session) }
        scheduleRefresh(session: session)
    }

    private func scheduleRefresh(session: UUID) {
        guard enabled, self.session == session else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            await self?.refresh(session: session)
        }
    }

    private func refresh(session: UUID) async {
        guard enabled, self.session == session, !Task.isCancelled else { return }
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
        let reminders = await store.anchorFetchReminders(matching: predicate)
        guard enabled, self.session == session, !Task.isCancelled else { return }
        items = reminders.map {
            Item(id: $0.calendarItemIdentifier, title: $0.title, dueDate: $0.dueDateComponents?.date)
        }
        .sorted {
            let left = $0.dueDate ?? .distantFuture
            let right = $1.dueDate ?? .distantFuture
            if left != right { return left < right }
            return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        errorMessage = nil
    }

    func add(_ title: String, consumer: UUID, session: UUID) -> Bool {
        guard enabled, self.session(for: consumer) == session else { return false }
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasAccess, !title.isEmpty,
              let calendar = store.defaultCalendarForNewReminders()
        else { errorMessage = "Choose a default list in Reminders and allow access."; return false }
        let reminder = EKReminder(eventStore: store)
        reminder.calendar = calendar
        reminder.title = title
        do {
            try store.save(reminder, commit: true)
            scheduleRefresh(session: session)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func complete(_ item: Item, consumer: UUID, session: UUID) {
        guard enabled, self.session(for: consumer) == session else { return }
        guard hasAccess,
              let reminder = store.calendarItem(withIdentifier: item.id) as? EKReminder
        else { return }
        reminder.isCompleted = true
        reminder.completionDate = Date()
        do {
            try store.save(reminder, commit: true)
            scheduleRefresh(session: session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
