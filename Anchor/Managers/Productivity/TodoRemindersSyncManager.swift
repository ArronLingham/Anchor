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
    private var store: EKEventStore?
    private var activeListID: String?
    private var generation = UUID()
    private var loadListsID: UUID?
    private var cancellables = Set<AnyCancellable>()
    private var syncObservers = Set<AnyCancellable>()
    private var scheduled: Task<Void, Never>?
    private struct FetchRequest {
        let id: UUID
        let handle: Any
        let continuation: CheckedContinuation<[EKReminder], Error>
    }
    private var fetchRequest: FetchRequest?
    private var repeatRequested = false
    private var applying = false
    private let checkpointURL = AppSupportDirectory.root.appendingPathComponent("todo-reminders-sync.json")

    private init() {
        guard !AppRuntimeEnvironment.isUITesting, UISnapshotHarness.requestedDirectory == nil else { return }
        Publishers.Merge3(
            Defaults.publisher(.enableTodoFeature, options: []).filter { $0.oldValue != $0.newValue }.map { !$0.newValue },
            Defaults.publisher(.todoRemindersSyncEnabled, options: []).filter { $0.oldValue != $0.newValue }.map { _ in false },
            Defaults.publisher(.todoRemindersListID, options: []).filter { $0.oldValue != $0.newValue }.map { _ in false }
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self] tasksWereDisabled in
            self?.reconcileSync(settingsChanged: true, tasksWereDisabled: tasksWereDisabled)
        }
        .store(in: &cancellables)
        reconcileSync()
    }

    private var configuredListID: String? {
        guard Defaults[.enableTodoFeature], Defaults[.todoRemindersSyncEnabled] else { return nil }
        let id = Defaults[.todoRemindersListID]
        return id.isEmpty ? nil : id
    }

    private func reconcileSync(settingsChanged: Bool = false, tasksWereDisabled: Bool = false) {
        if tasksWereDisabled || !Defaults[.enableTodoFeature] {
            loadListsID = nil
            if !lists.isEmpty { lists = [] }
        }
        let configured = configuredListID
        guard configured != activeListID || (settingsChanged && configured != nil) else { return }
        generation = UUID()
        scheduled?.cancel()
        scheduled = nil
        repeatRequested = false
        syncObservers.removeAll()
        cancelFetch()
        store = nil
        activeListID = configured
        guard configured != nil else { return }

        let store = EKEventStore()
        self.store = store
        TodoManager.shared.$items.dropFirst().sink { [weak self] _ in
            guard let self, !self.applying else { return }
            self.requestSync()
        }.store(in: &syncObservers)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &syncObservers)
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.requestSync() }.store(in: &syncObservers)
        requestSync()
    }

    func loadLists() async {
        guard Defaults[.enableTodoFeature] else { return }
        let token = UUID()
        loadListsID = token
        let store = self.store ?? EKEventStore()
        do {
            let granted = try await store.requestFullAccessToReminders()
            guard loadListsID == token, Defaults[.enableTodoFeature] else { return }
            guard granted else {
                status = "Allow Reminders access in System Settings → Privacy & Security → Reminders."
                return
            }
            lists = store.calendars(for: .reminder).filter { $0.allowsContentModifications }
                .map { List(id: $0.calendarIdentifier, name: "\($0.title) — \($0.source.title)") }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if lists.isEmpty { status = "Create an iCloud list in Reminders, then refresh the lists here." }
        } catch {
            guard loadListsID == token, Defaults[.enableTodoFeature] else { return }
            status = error.localizedDescription
        }
    }

    func requestSync() {
        guard let calendar = activeListID, calendar == configuredListID else { return }
        if isSyncing { repeatRequested = true; return }
        scheduled?.cancel()
        let token = generation
        scheduled = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, self.acceptsSync(token, calendar: calendar) else { return }
            self.scheduled = nil
            await syncNow()
        }
    }

    func syncNow() async {
        guard !isSyncing, let calendarID = activeListID, calendarID == configuredListID,
              let store else { return }
        let token = generation
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
            let reminders = try await fetchReminders(in: calendar, from: store)
            // Fetch is asynchronous: settings and tasks may change while waiting.
            guard acceptsSync(token, calendar: calendarID),
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
            guard acceptsSync(token, calendar: calendarID) else { return }
            store.reset()
            repeatRequested = false
            status = "Sync paused: \(error.localizedDescription) Your local tasks are kept."
        }
    }

    private func acceptsSync(_ token: UUID, calendar: String) -> Bool {
        generation == token && activeListID == calendar && configuredListID == calendar
    }

    private func fetchReminders(in calendar: EKCalendar, from store: EKEventStore) async throws -> [EKReminder] {
        let predicate = store.predicateForReminders(in: [calendar])
        return try await withCheckedThrowingContinuation { continuation in
            let id = UUID()
            let handle = store.fetchReminders(matching: predicate) { [weak self] result in
                Task { @MainActor [weak self] in self?.completeFetch(id, result: result) }
            }
            fetchRequest = FetchRequest(id: id, handle: handle, continuation: continuation)
        }
    }

    private func cancelFetch() {
        guard let request = fetchRequest else { return }
        fetchRequest = nil
        store?.cancelFetchRequest(request.handle)
        request.continuation.resume(throwing: CancellationError())
    }

    private func completeFetch(_ id: UUID, result: [EKReminder]?) {
        guard let request = fetchRequest, request.id == id else { return }
        fetchRequest = nil
        if let result { request.continuation.resume(returning: result) }
        else { request.continuation.resume(throwing: SyncError.fetchFailed) }
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
