import Foundation

struct EKCalendar {}
struct EKReminder: Equatable { let id: Int }
final class EKEventStore {
    private(set) var callbacks: [([EKReminder]?) -> Void] = []
    private(set) var cancelled: [Int] = []
    func predicateForReminders(in calendars: [EKCalendar]) -> Int { calendars.count }
    func fetchReminders(matching predicate: Int, completion: @escaping ([EKReminder]?) -> Void) -> Any {
        callbacks.append(completion)
        return callbacks.count - 1
    }
    func cancelFetchRequest(_ handle: Any) { cancelled.append(handle as! Int) }
}

@MainActor
final class ReminderFixture {
    enum SyncError: Error { case fetchFailed }
    var generation = UUID()
    var activeListID: String? = "list"
    var configuredListID: String? = "list"
    var store: EKEventStore?
    var fetchRequest: FetchRequest?
}

@main
enum TodoRemindersDisableLifecycleTests {
    @MainActor
    static func main() async throws {
        let fixture = ReminderFixture()
        let store = EKEventStore()
        fixture.store = store
        let oldGeneration = fixture.generation
        let first = Task { try await fixture.fetchReminders(in: EKCalendar(), from: store) }
        while store.callbacks.isEmpty { await Task.yield() }
        precondition(fixture.acceptsSync(oldGeneration, calendar: "list"))
        fixture.configuredListID = nil
        precondition(!fixture.acceptsSync(oldGeneration, calendar: "list"))
        fixture.generation = UUID()
        fixture.cancelFetch()
        precondition(store.cancelled == [0])
        do {
            _ = try await first.value
            preconditionFailure("Cancellation must resolve the awaiting fetch")
        } catch is CancellationError {}

        fixture.configuredListID = "list"
        precondition(!fixture.acceptsSync(oldGeneration, calendar: "list"))
        let current = Task { try await fixture.fetchReminders(in: EKCalendar(), from: store) }
        while store.callbacks.count < 2 { await Task.yield() }
        store.callbacks[0]([EKReminder(id: 0)])
        store.callbacks[1]([EKReminder(id: 1)])
        let reminders = try await current.value
        precondition(reminders == [EKReminder(id: 1)] && fixture.fetchRequest == nil)
        print("Reminders fetch cancellation, stale delivery and re-enable checks passed")
    }
}
