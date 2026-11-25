import Foundation

enum AppFeature {
    static let clipboardHistory = ClipboardFeature()
    final class ClipboardFeature { var isAvailable = true }
}

enum DefaultsKey {
    static let clipboardAutoClearOnDelay = "delay"
    static let clipboardAutoClearDelay = "seconds"
    static let clipboardAutoClearOnSleep = "sleep"
    static let clipboardAutoClearOnDisplaySleep = "display sleep"
    static let clipboardAutoClearOnScreenLock = "lock"
}

enum Defaults {
    static func sanitizedClipboardAutoClearDelay(_ entered: Int) -> Int { 30 }
}

enum UtilityPreferences {
    static let standard = PreferenceFixture()
    final class PreferenceFixture {
        var enabled: Set<String> = []
        func bool(forKey key: String) -> Bool { enabled.contains(key) }
        func integer(forKey key: String) -> Int { 30 }
    }
}

final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    func prepareOwnership() {}
}

enum ClipboardHistoryService {
    static var existing: Self? { nil }
    func ignoreNextChange(upTo changeCount: Int) {}
    func pasteboardWasCleared() {}
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

final class FixtureAccess {
    static let shared = FixtureAccess()
    var pending: [() -> Void] = []
    var timeout: (() -> Void)?
    var expired = false

    func async(_ work: @escaping () -> Void) { pending.append(work) }
    func async<T>(timeout: TimeInterval, _ work: @escaping (() -> Bool) -> T?,
                  then: @escaping (T?) -> Void, didFinish: @escaping (T?) -> Void) {
        precondition(self.timeout == nil)
        expired = false
        self.timeout = { self.expired = true; then(nil) }
        pending.append {
            let value = work { self.expired }
            didFinish(value)
            if !self.expired { then(value) }
            self.timeout = nil
        }
    }

    func deliver() { pending.removeFirst()() }
}

final class FixturePasteboard {
    static let shared = FixturePasteboard()
    private var count = 1
    var onRead: (() -> Void)?
    private(set) var clears = 0

    var changeCount: Int {
        let callback = onRead
        onRead = nil
        callback?()
        return count
    }

    func clearContents() -> Int {
        count += 1
        clears += 1
        return count
    }
    func copy() { count += 1 }
}

@main
enum UtilityClipboardAutoClearLifecycleTests {
    static func main() {
        let service = ClipboardAutoClearService.shared
        let board = FixturePasteboard.shared
        let lane = FixtureAccess.shared
        let prefs = UtilityPreferences.standard
        let workspace = FixtureWorkspace.shared.notificationCenter
        let sleep = FixtureWorkspace.willSleepNotification
        let lock = Notification.Name("com.apple.screenIsLocked")
        service.syncWithPreferences()
        precondition(workspace.observers.isEmpty && lane.pending.isEmpty)

        prefs.enabled = [DefaultsKey.clipboardAutoClearOnSleep, DefaultsKey.clipboardAutoClearOnScreenLock]
        service.syncWithPreferences()
        let first = workspace.observers.first!
        let lockObserver = DistributedFixtureNotificationCenter.center.observers.first!
        first.body(Notification(name: sleep))
        board.onRead = {
            prefs.enabled.remove(DefaultsKey.clipboardAutoClearOnSleep)
            service.syncWithPreferences()
        }
        lane.deliver()
        precondition(board.clears == 0 && workspace.observers.isEmpty)
        precondition(DistributedFixtureNotificationCenter.center.observers.first === lockObserver)

        prefs.enabled.insert(DefaultsKey.clipboardAutoClearOnSleep)
        service.syncWithPreferences()
        first.body(Notification(name: sleep))
        precondition(lane.pending.isEmpty)
        workspace.observers.first!.body(Notification(name: sleep))
        lockObserver.body(Notification(name: lock))
        lane.deliver()
        lane.deliver()
        precondition(board.clears == 1)

        board.copy()
        lockObserver.body(Notification(name: lock))
        prefs.enabled.remove(DefaultsKey.clipboardAutoClearOnScreenLock)
        // Even before the next settings reconciliation, no clear is allowed.
        lane.deliver()
        precondition(board.clears == 1)

        prefs.enabled = [DefaultsKey.clipboardAutoClearOnDelay]
        service.syncWithPreferences()
        precondition(lane.pending.count == 1)
        lane.timeout?()
        prefs.enabled.removeAll()
        service.syncWithPreferences()
        prefs.enabled = [DefaultsKey.clipboardAutoClearOnDelay]
        service.syncWithPreferences()
        service.tickForTest()
        precondition(lane.pending.count == 1)
        lane.deliver()
        service.tickForTest()
        precondition(lane.pending.count == 1)
        lane.deliver()
        precondition(board.clears == 1)
        prefs.enabled.removeAll()
        service.syncWithPreferences()
        print("Utility auto-clear checks the write boundary and bounds stalled reads")
    }
}
