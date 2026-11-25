import Foundation

enum Defaults {
    enum Key { case enableRealTimeWaveform }
    private static let lock = NSLock()
    private static var enabled = false
    static subscript(key: Key) -> Bool {
        get { lock.withLock { enabled } }
        set { lock.withLock { enabled = newValue } }
    }
}

final class NSRunningApplication: NSObject {
    let bundleIdentifier: String?
    init(_ bundleIdentifier: String?) { self.bundleIdentifier = bundleIdentifier }
}

final class NSWorkspace {
    static let shared = NSWorkspace()
    static let didLaunchApplicationNotification = Notification.Name("launch")
    static let didTerminateApplicationNotification = Notification.Name("terminate")
    static let applicationUserInfoKey = "app"

    final class Center {
        final class Observer: NSObject {
            let callback: (Notification) -> Void
            init(_ callback: @escaping (Notification) -> Void) { self.callback = callback }
        }
        var observers: [Notification.Name: Observer] = [:]
        func addObserver(forName name: Notification.Name, object: Any?, queue: OperationQueue?,
                         using callback: @escaping (Notification) -> Void) -> NSObjectProtocol {
            precondition(observers[name] == nil)
            let observer = Observer(callback)
            observers[name] = observer
            return observer
        }
        func removeObserver(_ token: NSObjectProtocol) {
            observers = observers.filter { $0.value !== token }
        }
    }
    let notificationCenter = Center()
}

final class WaveformFixture {
    var consumerCount = 0
    var isSuspended = true
    var observationGeneration = UUID()
    var targetAppObservers: [NSObjectProtocol] = []
    var pendingRestartWorkItem: DispatchWorkItem?
    let targetBundleIDs = ["com.apple.Music"]
    let audioQueue = DispatchQueue(label: "waveform-fixture")
    var starts = 0
    var stops = 0
    var targetIsAvailable = false
    var captureIsRunning = false

    func startCaptureSync() {
        starts += 1
        captureIsRunning = targetIsAvailable
    }

    func stopCaptureSync() {
        if captureIsRunning { stops += 1 }
        captureIsRunning = false
    }

    func flush() { audioQueue.sync {} }
}

@main
struct WaveformCaptureLifecycleTests {
    static func main() {
        let tap = WaveformFixture()
        let workspace = NSWorkspace.shared.notificationCenter
        tap.acquire()
        tap.flush()
        precondition(workspace.observers.isEmpty && tap.starts == 0)

        Defaults[.enableRealTimeWaveform] = true
        tap.setEnabled(true)
        tap.flush()
        precondition(workspace.observers.count == 2 && tap.starts == 1 && !tap.captureIsRunning)
        tap.acquire()
        tap.release()
        tap.flush()
        precondition(tap.consumerCount == 1 && tap.starts == 1 && workspace.observers.count == 2)

        let name = NSWorkspace.didTerminateApplicationNotification
        let handler = workspace.observers[name]!.callback
        handler(Notification(name: name, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication("other")]))
        tap.flush()
        precondition(tap.pendingRestartWorkItem == nil)
        let event = Notification(name: name, userInfo: [NSWorkspace.applicationUserInfoKey: NSRunningApplication("com.apple.Music")])
        handler(event)
        tap.flush()
        let scheduled = tap.pendingRestartWorkItem
        precondition(scheduled?.isCancelled == false)

        Defaults[.enableRealTimeWaveform] = false
        tap.setEnabled(false)
        tap.flush()
        precondition(scheduled?.isCancelled == true && tap.pendingRestartWorkItem == nil)
        precondition(workspace.observers.isEmpty && !tap.captureIsRunning)

        tap.targetIsAvailable = true
        Defaults[.enableRealTimeWaveform] = true
        tap.setEnabled(true)
        tap.flush()
        handler(event)
        tap.flush()
        precondition(tap.starts == 2 && tap.captureIsRunning && workspace.observers.count == 2)
        precondition(tap.pendingRestartWorkItem == nil)

        workspace.observers[name]!.callback(event)
        tap.flush()
        let finalRestart = tap.pendingRestartWorkItem
        precondition(finalRestart?.isCancelled == false)
        tap.release()
        tap.flush()
        precondition(workspace.observers.isEmpty && tap.stops == 1 && finalRestart?.isCancelled == true)

        tap.acquire()
        tap.flush()
        tap.stopCapture()
        precondition(workspace.observers.isEmpty && !tap.captureIsRunning && tap.stops == 2)
        print("Waveform observer demand, shared consumers, and stale restarts passed")
    }
}
