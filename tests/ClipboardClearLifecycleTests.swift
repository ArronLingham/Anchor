import Combine
import Foundation

enum Defaults {
    struct Key<Value> { let name: String; let defaults: Value }
    struct Change<Value> { let newValue: Value }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()

    static subscript<Value>(key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.defaults }
        set { values[key.name] = newValue; changes.send((key.name, newValue)) }
    }

    static func publisher<Value>(_ key: Key<Value>, options: [String] = []) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }.compactMap { ($0.1 as? Value).map(Change.init) }.eraseToAnyPublisher()
    }
}

extension Defaults.Key where Value == Bool {
    static let enableClipboardManager = Self(name: "history", defaults: false)
    static let autoCleanCopiedURLs = Self(name: "clean URLs", defaults: false)
    static let autoClearClipboardOnLock = Self(name: "clear on lock", defaults: false)
    static let autoClearClipboardEnabled = Self(name: "clear on delay", defaults: false)
}

extension Defaults.Key where Value == Int {
    static let autoClearClipboardSeconds = Self(name: "delay", defaults: 90)
}

final class ClipboardManager {
    static let shared = ClipboardManager()
    private(set) static var created = 0
    private init() { Self.created += 1 }

    var isMonitoring = false
    func startMonitoring() { isMonitoring = true }
    func stopMonitoring() { isMonitoring = false }
    func ignoreChangeCount(_ count: Int) {}
}

@MainActor
final class UtilityIntegration {
    static let shared = UtilityIntegration()
    var owners: Set<String> = []
}

final class FixtureNotificationCenter {
    final class Observer: NSObject {
        let name: Notification.Name?
        let body: (Notification) -> Void
        init(_ name: Notification.Name?, _ body: @escaping (Notification) -> Void) {
            self.name = name
            self.body = body
        }
    }

    var observers: [Observer] = []
    func addObserver(forName name: Notification.Name?, object: Any?, queue: OperationQueue?,
                     using handler: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let observer = Observer(name, handler)
        observers.append(observer)
        return observer
    }
    func removeObserver(_ observer: NSObjectProtocol) { observers.removeAll { $0 === observer } }
    func observer(_ name: Notification.Name) -> Observer { observers.first { $0.name == name }! }
}

enum DistributedFixtureNotificationCenter {
    static let center = FixtureNotificationCenter()
    static func `default`() -> FixtureNotificationCenter { center }
}

final class FixtureWorkspace {
    static let shared = FixtureWorkspace()
    static let willSleepNotification = Notification.Name("sleep")
    static let screensDidSleepNotification = Notification.Name("display sleep")
    let notificationCenter = FixtureNotificationCenter()
}

final class FixturePasteboard {
    static let general = FixturePasteboard()
    private var count = 0
    private(set) var clearCalls = 0
    var onRead: (() -> Void)?

    var changeCount: Int {
        let callback = onRead
        onRead = nil
        callback?()
        return count
    }
    func copy() { count += 1 }
    func clearContents() { clearCalls += 1; count += 1 }
}

@main
enum ClipboardClearLifecycleTests {
    @MainActor
    static func main() async {
        let tools = ClipboardToolsManager.shared
        let pasteboard = FixturePasteboard.general
        let workspace = FixtureWorkspace.shared.notificationCenter
        let utility = UtilityIntegration.shared
        let sleep = FixtureWorkspace.willSleepNotification
        let lock = Notification.Name("com.apple.screenIsLocked")
        tools.start()
        precondition(workspace.observers.isEmpty && ClipboardManager.created == 0)

        Defaults[.autoClearClipboardOnLock] = true
        await settle()
        let sleepObserver = workspace.observer(sleep)
        let lockObserver = DistributedFixtureNotificationCenter.center.observer(lock)
        sleepObserver.body(Notification(name: sleep))
        precondition(pasteboard.clearCalls == 1 && ClipboardManager.created == 0)

        pasteboard.copy()
        utility.owners = ["clipboardAutoClearSleep"]
        sleepObserver.body(Notification(name: sleep))
        tools.syncSystemTriggers()
        precondition(pasteboard.clearCalls == 1 && workspace.observers.count == 1)
        precondition(DistributedFixtureNotificationCenter.center.observer(lock) === lockObserver)

        utility.owners = []
        tools.syncSystemTriggers()
        sleepObserver.body(Notification(name: sleep))
        precondition(pasteboard.clearCalls == 1)
        Defaults[.autoClearClipboardOnLock] = false
        Defaults[.autoClearClipboardOnLock] = true
        lockObserver.body(Notification(name: lock))
        precondition(pasteboard.clearCalls == 1)
        await settle()

        let newLock = DistributedFixtureNotificationCenter.center.observer(lock)
        pasteboard.onRead = { Defaults[.autoClearClipboardOnLock] = false }
        newLock.body(Notification(name: lock))
        precondition(pasteboard.clearCalls == 1)
        await settle()
        precondition(workspace.observers.isEmpty && DistributedFixtureNotificationCenter.center.observers.isEmpty)

        Defaults[.autoCleanCopiedURLs] = true
        Defaults[.autoClearClipboardEnabled] = true
        await settle()
        precondition(ClipboardManager.shared.isMonitoring)
        tools.noteClipboardChanged()
        let staleDelay = tools.timerForTest!
        Defaults[.autoClearClipboardEnabled] = false
        Defaults[.autoClearClipboardEnabled] = true
        staleDelay.fire()
        precondition(pasteboard.clearCalls == 1)
        await settle()

        tools.noteClipboardChanged()
        pasteboard.copy()
        tools.timerForTest!.fire()
        precondition(pasteboard.clearCalls == 1)
        tools.noteClipboardChanged()
        tools.timerForTest!.fire()
        precondition(pasteboard.clearCalls == 2)

        tools.noteClipboardChanged()
        let pendingDelay = tools.timerForTest!
        utility.owners = ["clipboardAutoClearDelay"]
        tools.syncPasteboardWatch()
        precondition(!pendingDelay.isValid && ClipboardManager.shared.isMonitoring)
        Defaults[.enableClipboardManager] = true
        Defaults[.autoCleanCopiedURLs] = false
        await settle()
        precondition(ClipboardManager.shared.isMonitoring)
        Defaults[.enableClipboardManager] = false
        await settle()
        precondition(!ClipboardManager.shared.isMonitoring)
        print("Clipboard clear ownership, retired callbacks, and watcher demand passed")
    }

    private static func settle() async { try? await Task.sleep(for: .milliseconds(25)) }
}
