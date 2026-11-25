/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import EventKit
import SwiftUI

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    static let shared = CalendarManager()

    enum Consumer: Equatable {
        case glance, dashboard, launcher, lockScreen, settings, lockScreenSettings
    }

    private enum Scope: Hashable {
        case day, upcoming, lockScreen, calendarLists, reminderLists
    }

    private var consumers: [UUID: Consumer] = [:]
    private var scopes = Set<Scope>()
    private var generation = UUID()
    private var preferences = Set<AnyCancellable>()


    @Published var currentWeekStartDate: Date
    @Published var events: [EventModel] = []
    @Published var allCalendars: [CalendarModel] = []
    @Published var eventCalendars: [CalendarModel] = []
    @Published var reminderLists: [CalendarModel] = []
    @Published var selectedCalendarIDs: Set<String> = []
    @Published var calendarAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var reminderAuthorizationStatus: EKAuthorizationStatus = .notDetermined
    @Published var lockScreenEvents: [EventModel] = []
    @Published private(set) var launcherEvents: [EventModel] = []
    private var lastLauncherEventsFetchDate: Date?

    private var lockScreenPreviewEvents: [EventModel]?

    private let calendarService: CalendarServiceProviding
    private let authorizationStatus: (EKEntityType) -> EKAuthorizationStatus
    private var lastEventsFetchDate: Date?
    private let reloadRefreshInterval: TimeInterval = 15
    private var eventStoreChangedObserver: NSObjectProtocol?
    private var pendingEventStoreRefreshTask: Task<Void, Never>?
    private var nextAllowedEventStoreRefresh: Date = .distantPast
    private var ignoreEventStoreChangesUntil: Date = .distantPast
    private let eventStoreChangeThrottle: TimeInterval = 20
    private let selfInducedChangeSuppression: TimeInterval = 6
    private let eventFetchLimiter = EventFetchLimiter()
    private var lastLockScreenEventsFetchDate: Date?
    private let lockScreenRefreshInterval: TimeInterval = 15

    var hasCalendarAccess: Bool { isAuthorized(calendarAuthorizationStatus) }
    var hasReminderAccess: Bool { isAuthorized(reminderAuthorizationStatus) }

    /// Settings can display permission state without requesting new access.
    func refreshAuthorizationStatus() {
        let calendar = authorizationStatus(.event)
        let reminders = authorizationStatus(.reminder)
        if calendarAuthorizationStatus != calendar { calendarAuthorizationStatus = calendar }
        if reminderAuthorizationStatus != reminders { reminderAuthorizationStatus = reminders }
    }

    init(
        calendarService: CalendarServiceProviding = CalendarService(),
        authorizationStatus: @escaping (EKEntityType) -> EKAuthorizationStatus = EKEventStore.authorizationStatus(for:)
    ) {
        self.calendarService = calendarService
        self.authorizationStatus = authorizationStatus
        currentWeekStartDate = CalendarManager.startOfDay(Date())
        refreshAuthorizationStatus()
        for key in [Defaults.Key<Bool>.showCalendar, .enableReminderLiveActivity,
                    .enableLauncher, .launcherShowCalendarWidget, .lockScreenShowCalendarEvent] {
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
        reconcileDemand()
    }

    deinit {
        if let observer = eventStoreChangedObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        pendingEventStoreRefreshTask?.cancel()
    }

    func setConsumer(_ consumer: Consumer, id: UUID, mounted: Bool) {
        if mounted { consumers[id] = consumer }
        else { consumers.removeValue(forKey: id) }
        reconcileDemand()
    }

    private func isWanted(_ consumer: Consumer) -> Bool {
        switch consumer {
        case .glance: return Defaults[.showCalendar]
        case .launcher: return Defaults[.enableLauncher] && Defaults[.launcherShowCalendarWidget]
        case .lockScreen, .lockScreenSettings: return Defaults[.lockScreenShowCalendarEvent]
        case .dashboard, .settings: return true
        }
    }

    private func reconcileDemand() {
        let owners = consumers.values.filter(isWanted)
        var wanted = Set<Scope>()
        if owners.contains(.glance) || Defaults[.enableReminderLiveActivity] { wanted.insert(.day) }
        if owners.contains(.launcher) || owners.contains(.dashboard) { wanted.insert(.upcoming) }
        if owners.contains(.lockScreen) { wanted.insert(.lockScreen) }
        if owners.contains(.settings) || owners.contains(.lockScreenSettings) { wanted.insert(.calendarLists) }
        if owners.contains(.settings) { wanted.insert(.reminderLists) }
        guard wanted != scopes else { return }

        generation = UUID()
        scopes = wanted
        pendingEventStoreRefreshTask?.cancel()
        pendingEventStoreRefreshTask = nil

        if !wanted.contains(.day) {
            if !events.isEmpty { events = [] }
            lastEventsFetchDate = nil
        }
        if !wanted.contains(.upcoming) {
            if !launcherEvents.isEmpty { launcherEvents = [] }
            lastLauncherEventsFetchDate = nil
        }
        if !wanted.contains(.lockScreen), lockScreenPreviewEvents == nil {
            if !lockScreenEvents.isEmpty { lockScreenEvents = [] }
            lastLockScreenEventsFetchDate = nil
        }

        if !wanted.contains(.reminderLists), !reminderLists.isEmpty { reminderLists = [] }
        if !wanted.contains(.calendarLists), !eventCalendars.isEmpty { eventCalendars = [] }
        if !wanted.contains(.calendarLists) || !wanted.contains(.reminderLists) {
            allCalendars = eventCalendars + reminderLists
            updateSelectedCalendars()
        }

        if !wanted.isEmpty {
            if eventStoreChangedObserver == nil { setupEventStoreChangedObserver() }
            scheduleEventStoreRefresh(after: 0, force: true)
        } else {
            if let observer = eventStoreChangedObserver {
                NotificationCenter.default.removeObserver(observer)
                eventStoreChangedObserver = nil
            }
            nextAllowedEventStoreRefresh = .distantPast
            ignoreEventStoreChangesUntil = .distantPast
        }
    }

    private func setupEventStoreChangedObserver() {
        eventStoreChangedObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // queue: .main / AppKit animation completion both run on the
            // main thread; assumeIsolated states that and traps if it ever
            // stops being true, rather than assuming it silently.
            MainActor.assumeIsolated {
                self?.handleEventStoreChanged()
            }
        }
    }

    private func handleEventStoreChanged() {
        guard !scopes.isEmpty else { return }
        lastLauncherEventsFetchDate = nil
        Logger.log("CalendarManager: Event store changed notification received", category: .lifecycle)
        let now = Date()
        guard now >= ignoreEventStoreChangesUntil else { return }

        if now < nextAllowedEventStoreRefresh {
            let delay = max(nextAllowedEventStoreRefresh.timeIntervalSince(now), 0.05)
            scheduleEventStoreRefresh(after: delay)
            return
        }

        nextAllowedEventStoreRefresh = now.addingTimeInterval(eventStoreChangeThrottle)
        scheduleEventStoreRefresh(after: 0)
    }

    private func scheduleEventStoreRefresh(after delay: TimeInterval, force: Bool = false) {
        guard !scopes.isEmpty else { return }
        pendingEventStoreRefreshTask?.cancel()
        let generation = generation
        pendingEventStoreRefreshTask = Task { [weak self] in
            if delay > 0 {
                do { try await Task.sleep(for: .seconds(delay)) }
                catch { return }
            }
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            await self.performEventStoreRefresh(force: force)
            if !Task.isCancelled, self.generation == generation {
                self.pendingEventStoreRefreshTask = nil
            }
        }
    }

    @MainActor
    private func performEventStoreRefresh(force: Bool) async {
        let generation = generation
        refreshAuthorizationStatus()
        await reloadCalendarAndReminderLists()
        guard !Task.isCancelled, self.generation == generation else { return }
        await updateLauncherEvents(force: force)
        await updateLockScreenEvents(force: true)
        await updateEvents(force: force)
        guard !Task.isCancelled, self.generation == generation else { return }
        nextAllowedEventStoreRefresh = Date().addingTimeInterval(eventStoreChangeThrottle)
        ignoreEventStoreChangesUntil = Date().addingTimeInterval(selfInducedChangeSuppression)
    }

    @MainActor
    private func reloadCalendarAndReminderLists() async {
        guard scopes.contains(.calendarLists), !Task.isCancelled else { return }
        let generation = generation
        let allCalendars = await calendarService.calendars(includeReminders: scopes.contains(.reminderLists))
        guard !Task.isCancelled, self.generation == generation else { return }
        eventCalendars = allCalendars.filter { !$0.isReminder }
        reminderLists = allCalendars.filter { $0.isReminder }
        self.allCalendars = allCalendars
        updateSelectedCalendars()
    }

    private func isAuthorized(_ status: EKAuthorizationStatus) -> Bool {
        switch status {
        case .authorized, .fullAccess:
            return true
        default:
            return false
        }
    }

    func checkCalendarAuthorization() async {
        let status = authorizationStatus(.event)
        calendarAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .event)
            calendarAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                scheduleEventStoreRefresh(after: 0, force: true)
            }
        case .restricted, .denied:
            NSLog("Calendar access denied or restricted")
        case .authorized, .fullAccess:
            scheduleEventStoreRefresh(after: 0, force: true)
        case .writeOnly:
            NSLog("Calendar write only")
        @unknown default:
            NSLog("Unknown calendar authorization status")
        }
    }

    func checkReminderAuthorization() async {
        let status = authorizationStatus(.reminder)
        reminderAuthorizationStatus = status

        switch status {
        case .notDetermined:
            let granted = await calendarService.requestAccess(to: .reminder)
            reminderAuthorizationStatus = granted ? .fullAccess : .denied
            if granted {
                scheduleEventStoreRefresh(after: 0, force: true)
            }
        case .restricted, .denied:
            NSLog("Reminder access denied or restricted")
        case .authorized, .fullAccess:
            scheduleEventStoreRefresh(after: 0, force: true)
        case .writeOnly:
            NSLog("Reminder write only")
        @unknown default:
            NSLog("Unknown reminder authorization status")
        }
    }

    func updateSelectedCalendars() {
        switch Defaults[.calendarSelectionState] {
        case .all:
            selectedCalendarIDs = Set(allCalendars.map { $0.id })
        case .selected(let identifiers):
            selectedCalendarIDs = identifiers
        }

    }

    func getCalendarSelected(_ calendar: CalendarModel) -> Bool {
        selectedCalendarIDs.contains(calendar.id)
    }

    func setCalendarSelected(_ calendar: CalendarModel, isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting([calendar.id])
                selectionState = .selected(identifiers)
            }
        case .selected(var identifiers):
            if isSelected {
                identifiers.insert(calendar.id)
            } else {
                identifiers.remove(calendar.id)
            }

            if identifiers.isEmpty || identifiers.count == allCalendars.count {
                selectionState = .all
            } else {
                selectionState = .selected(identifiers)
            }
        }

        Defaults[.calendarSelectionState] = selectionState
        lastLauncherEventsFetchDate = nil
        updateSelectedCalendars()
        scheduleEventStoreRefresh(after: 0, force: true)
    }

    static func startOfDay(_ date: Date) -> Date {
        Calendar.current.startOfDay(for: date)
    }

    func updateCurrentDate(_ date: Date) async {
        guard Defaults[.showCalendar], consumers.values.contains(.glance) else { return }
        currentWeekStartDate = Calendar.current.startOfDay(for: date)
        await updateEvents(force: true)
    }

    /// The launcher shows the next few events across the coming week, rather
    /// than inheriting the lock screen's short notification lookahead.
    func updateLauncherEvents(force: Bool = false) async {
        guard scopes.contains(.upcoming), !Task.isCancelled else { return }
        let generation = generation
        if !force, let last = lastLauncherEventsFetchDate,
           Date().timeIntervalSince(last) < 30 { return }
        guard hasCalendarAccess,
              let end = Calendar.current.date(byAdding: .day, value: 7, to: Date())
        else {
            launcherEvents = []
            return
        }
        let calendarIDs = selectedCalendarFilter
        let fetched = await calendarService.events(
            from: Date(), to: end, calendars: calendarIDs, includeReminders: false)
        guard !Task.isCancelled, self.generation == generation,
              calendarIDs == selectedCalendarFilter else { return }
        if launcherEvents != fetched { launcherEvents = fetched }
        lastLauncherEventsFetchDate = Date()
    }

    private var selectedCalendarFilter: Set<String>? {
        if case .selected(let identifiers) = Defaults[.calendarSelectionState] { return identifiers }
        return nil
    }

    func updateLockScreenEvents(force: Bool = false) async {
        guard !Task.isCancelled else { return }
        if let previewEvents = lockScreenPreviewEvents {
            if lockScreenEvents != previewEvents {
                withAnimation(.smooth(duration: 0.25)) {
                    lockScreenEvents = previewEvents
                }
            }
            lastLockScreenEventsFetchDate = Date()
            return
        }

        guard scopes.contains(.lockScreen), hasCalendarAccess else { return }
        let generation = generation
        let now = Date()

        if !force,
           let lastFetch = lastLockScreenEventsFetchDate,
           now.timeIntervalSince(lastFetch) < lockScreenRefreshInterval {
            return
        }

        let lookaheadRaw = Defaults[.lockScreenCalendarEventLookaheadWindow]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let isAllTimeLookahead =
            lookaheadRaw == "all_time" ||
            lookaheadRaw == "all time" ||
            lookaheadRaw == "alltime"

        let isRestOfDay =
            lookaheadRaw == "rest_of_day" ||
            lookaheadRaw == "rest of the day" ||
            lookaheadRaw == "restofday"

        func lookaheadMinutes(from raw: String) -> Int? {
            switch raw {
            case "15m", "15 min", "15 mins", "15min", "15mins": return 15
            case "30m", "30 min", "30 mins", "30min", "30mins": return 30
            case "1h", "1 hr", "1 hour", "1hour": return 60
            case "3h", "3 hr", "3 hours", "3hours": return 180
            case "6h", "6 hr", "6 hours", "6hours": return 360
            case "12h", "12 hr", "12 hours", "12hours": return 720
            default: return nil
            }
        }

        let calendar = Calendar.current
        let startOfToday = calendar.startOfDay(for: now)
        let startDate = calendar.date(byAdding: .day, value: -1, to: startOfToday) ?? startOfToday

        let endDate: Date
        if isAllTimeLookahead {
            endDate = calendar.date(byAdding: .day, value: 365, to: now) ?? now.addingTimeInterval(365 * 24 * 3600)
        } else if isRestOfDay {
            endDate = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? startOfToday.addingTimeInterval(24 * 3600)
        } else if let minutes = lookaheadMinutes(from: lookaheadRaw) {
            endDate = calendar.date(byAdding: .minute, value: minutes, to: now) ?? now.addingTimeInterval(TimeInterval(minutes * 60))
        } else {
            endDate = calendar.date(byAdding: .minute, value: 180, to: now) ?? now.addingTimeInterval(180 * 60)
        }

        let service = calendarService
        let fetched: [EventModel] = await eventFetchLimiter.run {
            guard !Task.isCancelled else { return [] }
            return await service.events(from: startDate, to: endDate, calendars: nil, includeReminders: true)
        }
        guard !Task.isCancelled, self.generation == generation, lockScreenPreviewEvents == nil else { return }

        if lockScreenEvents == fetched {
            lastLockScreenEventsFetchDate = Date()
            return
        }

        withAnimation(.smooth(duration: 0.25)) {
            lockScreenEvents = fetched
        }
        lastLockScreenEventsFetchDate = Date()
    }

    func setLockScreenPreviewEvents(_ events: [EventModel]?) {
        lockScreenPreviewEvents = events
        guard let events else {
            lockScreenEvents = []
            lastLockScreenEventsFetchDate = nil
            if scopes.contains(.lockScreen) { scheduleEventStoreRefresh(after: 0, force: true) }
            return
        }
        withAnimation(.smooth(duration: 0.25)) {
            lockScreenEvents = events
        }
        lastLockScreenEventsFetchDate = Date()
    }

    private func updateEvents(force: Bool = false) async {
        guard scopes.contains(.day), !Task.isCancelled else { return }
        let generation = generation
        let now = Date()
        if !force, let lastFetch = lastEventsFetchDate, now.timeIntervalSince(lastFetch) < reloadRefreshInterval {
            return
        }
        
        Logger.log("CalendarManager: Updating events (force: \(force))", category: .lifecycle)

        let calendarIDs = selectedCalendarFilter
        let startDate = currentWeekStartDate
        guard let endDate = Calendar.current.date(byAdding: .day, value: 1, to: currentWeekStartDate) else { return }
        let service = calendarService

        let events: [EventModel] = await eventFetchLimiter.run {
            guard !Task.isCancelled else { return [] }
            return await service.events(
                from: startDate,
                to: endDate,
                calendars: calendarIDs,
                includeReminders: true
            )
        }

        guard !Task.isCancelled, self.generation == generation,
              startDate == currentWeekStartDate, calendarIDs == selectedCalendarFilter else { return }
        if self.events != events { self.events = events }
        lastEventsFetchDate = Date()
    }

    func setCalendarsSelected(_ calendars: [CalendarModel], isSelected: Bool) async {
        var selectionState = Defaults[.calendarSelectionState]
        let ids = Set(calendars.map { $0.id })

        switch selectionState {
        case .all:
            if !isSelected {
                let identifiers = Set(allCalendars.map { $0.id }).subtracting(ids)
                selectionState = .selected(identifiers)
            }
        case .selected(var identifiers):
            if isSelected {
                identifiers.formUnion(ids)
            } else {
                identifiers.subtract(ids)
            }

            if identifiers.isEmpty || identifiers.count == allCalendars.count {
                selectionState = .all
            } else {
                selectionState = .selected(identifiers)
            }
        }

        Defaults[.calendarSelectionState] = selectionState
        updateSelectedCalendars()
        scheduleEventStoreRefresh(after: 0, force: true)
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {
        guard Defaults[.showCalendar], consumers.values.contains(.glance) else { return }
        await calendarService.setReminderCompleted(reminderID: reminderID, completed: completed)
        await updateEvents(force: true)
    }
}

// MARK: - Event Fetch Limiter

private actor EventFetchLimiter {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isRunning = false

    func run<T>(_ operation: @escaping @Sendable () async -> T) async -> T {
        await waitTurn()
        defer { resumeNext() }
        return await operation()
    }

    private func waitTurn() async {
        if !isRunning {
            isRunning = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func resumeNext() {
        if waiters.isEmpty {
            isRunning = false
            return
        }

        let continuation = waiters.removeFirst()
        continuation.resume()
    }
}

private struct CalendarConsumerModifier: ViewModifier {
    let consumer: CalendarManager.Consumer
    let enabled: Bool
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .onAppear { CalendarManager.shared.setConsumer(consumer, id: id, mounted: enabled) }
            .onChange(of: enabled) { _, enabled in
                CalendarManager.shared.setConsumer(consumer, id: id, mounted: enabled)
            }
            .onDisappear { CalendarManager.shared.setConsumer(consumer, id: id, mounted: false) }
    }
}

extension View {
    func calendarConsumer(_ consumer: CalendarManager.Consumer, enabled: Bool = true) -> some View {
        modifier(CalendarConsumerModifier(consumer: consumer, enabled: enabled))
    }
}
