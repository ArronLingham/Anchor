import Combine
import EventKit
import SwiftUI

enum Defaults {
    struct Key<Value> {
        let name: String
        let initialValue: Value
    }

    struct Change<Value> { let newValue: Value }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()

    static subscript<Value>(_ key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.initialValue }
        set { values[key.name] = newValue; changes.send((key.name, newValue)) }
    }

    static func publisher<Value>(_ key: Key<Value>, options: [String]) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }
            .compactMap { ($0.1 as? Value).map { Change(newValue: $0) } }
            .eraseToAnyPublisher()
    }
}

enum CalendarSelection { case all, selected(Set<String>) }
extension Defaults.Key where Value == Bool {
    static var showCalendar: Self { .init(name: "glance", initialValue: true) }
    static var enableReminderLiveActivity: Self { .init(name: "activity", initialValue: false) }
    static var enableLauncher: Self { .init(name: "launcher", initialValue: true) }
    static var launcherShowCalendarWidget: Self { .init(name: "calendarWidget", initialValue: true) }
    static var lockScreenShowCalendarEvent: Self { .init(name: "lockCalendar", initialValue: true) }
}
extension Defaults.Key where Value == CalendarSelection {
    static var calendarSelectionState: Self { .init(name: "selection", initialValue: .all) }
}
extension Defaults.Key where Value == String {
    static var lockScreenCalendarEventLookaheadWindow: Self { .init(name: "lookahead", initialValue: "3h") }
}

struct CalendarModel { let id: String; let isReminder: Bool }
struct EventModel: Equatable { let id: String }
enum Logger {
    enum Category { case lifecycle }
    static func log(_ message: String, category: Category) {}
}

protocol CalendarServiceProviding {
    func calendars(includeReminders: Bool) async -> [CalendarModel]
    func events(from start: Date, to end: Date, calendars: Set<String>?, includeReminders: Bool) async -> [EventModel]
    func requestAccess(to entity: EKEntityType) async -> Bool
    func setReminderCompleted(reminderID: String, completed: Bool) async
}

final class CalendarService: CalendarServiceProviding {
    func calendars(includeReminders: Bool) async -> [CalendarModel] { [] }
    func events(from start: Date, to end: Date, calendars: Set<String>?, includeReminders: Bool) async -> [EventModel] { [] }
    func requestAccess(to entity: EKEntityType) async -> Bool { false }
    func setReminderCompleted(reminderID: String, completed: Bool) async {}
}

actor CalendarFixture: CalendarServiceProviding {
    struct Query {
        let scope: String
        let continuation: CheckedContinuation<[EventModel], Never>
    }
    private(set) var reads = [Bool]()
    private(set) var prompts = 0
    private(set) var requested: [String] = []
    private var pending: [Query] = []

    func calendars(includeReminders: Bool) async -> [CalendarModel] {
        reads.append(includeReminders)
        return [.init(id: "event-calendar", isReminder: false)]
    }

    func events(from start: Date, to end: Date, calendars: Set<String>?, includeReminders: Bool) async -> [EventModel] {
        let scope = includeReminders ? (end.timeIntervalSince(start) <= 90_000 ? "day" : "lock") : "upcoming"
        requested.append(scope)
        return await withCheckedContinuation { pending.append(Query(scope: scope, continuation: $0)) }
    }

    func complete(_ scope: String, event: String) {
        guard let index = pending.firstIndex(where: { $0.scope == scope }) else {
            preconditionFailure("No pending \(scope) read")
        }
        pending.remove(at: index).continuation.resume(returning: [EventModel(id: event)])
    }

    func requestAccess(to entity: EKEntityType) async -> Bool {
        prompts += 1
        return true
    }

    func setReminderCompleted(reminderID: String, completed: Bool) async {}
}

@main
enum CalendarDemandTests {
    @MainActor
    static func main() async {
        let service = CalendarFixture()
        let manager = CalendarManager(calendarService: service, authorizationStatus: { _ in .fullAccess })
        let dashboard = UUID()
        let launcher = UUID()
        let glance = UUID()
        let lock = UUID()

        await manager.updateLauncherEvents()
        await manager.updateLockScreenEvents()
        let idleReads = await service.reads
        precondition(idleReads.isEmpty)

        manager.setConsumer(.launcher, id: launcher, mounted: true)
        await wait { await service.requested == ["upcoming"] }
        manager.setConsumer(.dashboard, id: dashboard, mounted: true)
        Defaults[.launcherShowCalendarWidget] = false
        await service.complete("upcoming", event: "dashboard retains demand")
        await wait { manager.launcherEvents.map(\.id) == ["dashboard retains demand"] }
        manager.setConsumer(.dashboard, id: dashboard, mounted: false)
        precondition(manager.launcherEvents.isEmpty && manager.eventCalendars.isEmpty)

        Defaults[.launcherShowCalendarWidget] = true
        await wait { await service.requested.count == 2 }
        Defaults[.launcherShowCalendarWidget] = false
        Defaults[.launcherShowCalendarWidget] = true
        await wait { await service.requested.count == 3 }
        await service.complete("upcoming", event: "retired")
        try? await Task.sleep(for: .milliseconds(20))
        precondition(manager.launcherEvents.isEmpty)
        await service.complete("upcoming", event: "current")
        await wait { manager.launcherEvents.map(\.id) == ["current"] }
        manager.setConsumer(.launcher, id: launcher, mounted: false)

        manager.setLockScreenPreviewEvents([.init(id: "preview")])
        precondition(manager.lockScreenEvents.map(\.id) == ["preview"])
        manager.setLockScreenPreviewEvents(nil)
        precondition(manager.lockScreenEvents.isEmpty)
        manager.setConsumer(.lockScreen, id: lock, mounted: true)
        await wait { await service.requested.last == "lock" }
        Defaults[.lockScreenShowCalendarEvent] = false
        await service.complete("lock", event: "retired lock screen")
        try? await Task.sleep(for: .milliseconds(20))
        precondition(manager.lockScreenEvents.isEmpty)
        manager.setConsumer(.lockScreen, id: lock, mounted: false)

        manager.setConsumer(.glance, id: glance, mounted: true)
        await wait { await service.requested.last == "day" }
        Defaults[.enableReminderLiveActivity] = true
        Defaults[.showCalendar] = false
        await service.complete("day", event: "activity retains demand")
        await wait { manager.events.map(\.id) == ["activity retains demand"] }
        Defaults[.enableReminderLiveActivity] = false
        precondition(manager.events.isEmpty && manager.eventCalendars.isEmpty)
        let listReads = await service.reads
        precondition(listReads.isEmpty, "Rendering events does not reload calendar or reminder lists")
        let settings = UUID()
        Defaults[.lockScreenShowCalendarEvent] = true
        manager.setConsumer(.lockScreenSettings, id: settings, mounted: true)
        await wait { await service.reads == [false] }
        manager.setConsumer(.lockScreenSettings, id: settings, mounted: false)
        manager.setConsumer(.settings, id: settings, mounted: true)
        await wait { await service.reads == [false, true] }
        manager.setConsumer(.settings, id: settings, mounted: false)
        let prompts = await service.prompts
        precondition(prompts == 0)
        let store = ReminderStoreFixture()
        let fetch = Task { await store.anchorFetchReminders(matching: NSPredicate(value: true)) }
        await wait { store.completion != nil }
        fetch.cancel()
        let cancelled = await fetch.value
        precondition(cancelled.isEmpty && store.cancelCount == 1)
        store.completion?([])
        try? await Task.sleep(for: .milliseconds(20))
        precondition(store.cancelCount == 1)
        print("Calendar demand, independent consumers, synthetic preview, and EventKit cancellation checks passed")
    }

    @MainActor
    private static func wait(_ ready: () async -> Bool) async {
        for _ in 0..<250 {
            if await ready() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Calendar demand fixture timed out")
    }
}

private final class ReminderStoreFixture: EKEventStore {
    let token = NSObject()
    var completion: (([EKReminder]?) -> Void)?
    var cancelCount = 0

    override func fetchReminders(
        matching predicate: NSPredicate, completion: @escaping ([EKReminder]?) -> Void
    ) -> Any {
        self.completion = completion
        return token
    }

    override func cancelFetchRequest(_ fetchIdentifier: Any) {
        precondition(fetchIdentifier as AnyObject === token)
        cancelCount += 1
    }
}
