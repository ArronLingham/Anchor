import AppKit
import Combine
import CryptoKit
import Defaults
import EventKit
import Foundation

/// Two-way access through Apple's Reminders app, including iPhone. Only the
/// explicitly chosen list is touched. A disk checkpoint keeps offline edits
/// distinct from unchanged values, and failed sync never clears the local list.
@MainActor
final class TodoRemindersSyncManager: ObservableObject {
    static let shared = TodoRemindersSyncManager()
    struct List: Identifiable {
        let id: String
        let name: String
    }
    private typealias Checkpoint = TodoSyncMerge.Checkpoint
    @Published private(set) var lists: [List] = []
    @Published private(set) var isSyncing = false
    @Published private(set) var status = "Choose a Reminders list to use on your iPhone."
    @Published private(set) var lastSync: Date?
    private let store = EKEventStore()
    private var cancellables = Set<AnyCancellable>()
    private var scheduled: Task<Void, Never>?
    private var repeatRequested = false
    private var applying = false
    private let checkpointURL = AppSupportDirectory.root.appendingPathComponent("todo-reminders-sync.json")

    private init() {
        guard !AppRuntimeEnvironment.isUITesting, UISnapshotHarness.requestedDirectory == nil else { return }
        TodoManager.shared.$items.dropFirst().sink { [weak self] _ in
            guard let self, !self.applying else { return }
            self.requestSync()
        }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &cancellables)
        Defaults.publisher(.todoRemindersSyncEnabled).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &cancellables)
        Defaults.publisher(.todoRemindersListID).receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &cancellables)
        requestSync()
    }

    func loadLists() async {
        do {
            guard try await store.requestFullAccessToReminders() else {
                status = "Allow Reminders access in System Settings → Privacy & Security → Reminders."
                return
            }
            lists = store.calendars(for: .reminder).filter { $0.allowsContentModifications }
                .map { List(id: $0.calendarIdentifier, name: "\($0.title) — \($0.source.title)") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if lists.isEmpty { status = "Create an iCloud list in Reminders, then refresh the lists here." }
        } catch { status = error.localizedDescription }
    }

    func requestSync() {
        guard Defaults[.todoRemindersSyncEnabled], !Defaults[.todoRemindersListID].isEmpty else { return }
        if isSyncing { repeatRequested = true; return }
        scheduled?.cancel()
        scheduled = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await syncNow()
        }
    }

    func syncNow() async {
        guard !isSyncing, Defaults[.todoRemindersSyncEnabled] else { return }
        let calendarID = Defaults[.todoRemindersListID]
        guard !calendarID.isEmpty else { return }
        guard !TodoManager.shared.storageNeedsRecovery, TodoManager.shared.storageError == nil else {
            status = "Resolve the local storage error before syncing."
            return
        }
        isSyncing = true
        repeatRequested = false
        defer {
            isSyncing = false
            if repeatRequested { requestSync() }
        }
        do {
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                status = "Choose Load Reminders Lists to allow access."
                return
            }
            guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
                status = "The selected list is unavailable. Choose a list again; your local tasks are safe."
                return
            }
            var checkpoint = Checkpoint(calendarID: calendarID)
            if FileManager.default.fileExists(atPath: checkpointURL.path) {
                let saved = try JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: checkpointURL))
                if saved.calendarID == calendarID { checkpoint = saved }
            }
            let predicate = store.predicateForReminders(in: [calendar])
            let reminders: [EKReminder] = try await withCheckedThrowingContinuation { continuation in
                store.fetchReminders(matching: predicate) { result in
                    if let result { continuation.resume(returning: result) }
                    else { continuation.resume(throwing: SyncError.fetchFailed) }
                }
            }
            // Fetch is asynchronous: settings and tasks may change while waiting.
            guard Defaults[.todoRemindersSyncEnabled], Defaults[.todoRemindersListID] == calendarID,
                  !TodoManager.shared.storageNeedsRecovery, TodoManager.shared.storageError == nil else { return }
            let remote = try reminders.map { reminder in
                let key = checkpoint.remoteIDs.first(where: { $0.value == reminder.calendarItemIdentifier })?.key
                let id = key.flatMap(UUID.init(uuidString:)) ?? Self.localID(for: reminder)
                return TodoSyncMerge.Remote(id: reminder.calendarItemIdentifier, item: try Self.item(from: reminder, id: id))
            }
            let plan = try TodoSyncMerge.plan(local: TodoManager.shared.items, remote: remote, checkpoint: checkpoint)
            var next = plan.checkpoint
            let byRemoteID = Dictionary(reminders.map { ($0.calendarItemIdentifier, $0) }, uniquingKeysWith: { first, _ in first })
            var saved: [(EKReminder, TodoItem)] = []

            // Persist phone edits before committing outbound changes. There are
            // no suspension points between this snapshot and the local save.
            applying = true
            defer { applying = false }
            try TodoManager.shared.applySyncedItems(plan.items)
            for item in plan.writes {
                let remoteID = next.remoteIDs[item.id.uuidString]
                let reminder = remoteID.flatMap { byRemoteID[$0] } ?? EKReminder(eventStore: store)
                if remoteID == nil {
                    reminder.calendar = calendar
                    reminder.url = URL(string: "anchor-todo://task/\(item.id.uuidString)")
                }
                Self.apply(item, to: reminder)
                try store.save(reminder, commit: false)
                saved.append((reminder, item))
            }
            for id in plan.deletes {
                if let reminder = byRemoteID[id] { try store.remove(reminder, commit: false) }
            }
            if !saved.isEmpty || !plan.deletes.isEmpty { try store.commit() }
            for (reminder, item) in saved { next.remoteIDs[item.id.uuidString] = reminder.calendarItemIdentifier }
            let data = try JSONEncoder().encode(next)
            try data.write(to: checkpointURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: checkpointURL)
            defer { try? handle.close() }
            try handle.synchronize()
            lastSync = Date()
            status = "Synced with \(calendar.title). Use this list in Reminders on your iPhone."
        } catch {
            store.reset()
            repeatRequested = false
            status = "Sync paused: \(error.localizedDescription) Your local tasks are kept."
        }
    }

    private enum SyncError: LocalizedError {
        case fetchFailed, emptyTitle
        var errorDescription: String? {
            switch self {
            case .fetchFailed: return "Reminders did not return a list. Try again."
            case .emptyTitle: return "A reminder has no title. Give it a title in Reminders, then sync again."
            }
        }
    }

    private static func localID(for reminder: EKReminder) -> UUID {
        if let url = reminder.url, url.scheme == "anchor-todo", url.host == "task",
           let id = UUID(uuidString: url.lastPathComponent) { return id }
        // Deterministic import identity survives a crash before writing the checkpoint.
        let bytes = Array(SHA256.hash(data: Data(reminder.calendarItemIdentifier.utf8)).prefix(16))
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    private static func item(from reminder: EKReminder, id: UUID) throws -> TodoItem {
        let title = (reminder.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw SyncError.emptyTitle }
        var due: Date?
        if var components = reminder.dueDateComponents {
            components.calendar = components.calendar ?? Calendar.current
            if components.hour == nil { components.hour = 23; components.minute = 59; components.second = 59 }
            due = components.date
        }
        let priority = reminder.priority == 0 ? 0 : (reminder.priority <= 4 ? 3 : (reminder.priority == 5 ? 2 : 1))
        return TodoItem(id: id, title: title, isDone: reminder.isCompleted,
                        createdAt: reminder.creationDate ?? Date(), completedAt: reminder.completionDate,
                        dueDate: due, priority: priority)
    }

    private static func apply(_ item: TodoItem, to reminder: EKReminder) {
        reminder.title = item.title
        reminder.priority = [0, 9, 5, 1][max(0, min(3, item.priority))]
        reminder.dueDateComponents = item.dueDate.map {
            Calendar.current.dateComponents([.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: $0)
        }
        reminder.isCompleted = item.isDone
        reminder.completionDate = item.isDone ? item.completedAt : nil
    }
}
