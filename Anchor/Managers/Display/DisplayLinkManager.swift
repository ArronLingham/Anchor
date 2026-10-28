import AppKit
import Combine
import Defaults
import IOKit
import IOKit.ps

/// Companion lifecycle only. Synaptics owns pixels, permissions and USB video.
@MainActor
final class DisplayLinkManager: ObservableObject {
    static let shared = DisplayLinkManager()
    nonisolated static let bundleID = "com.displaylink.DisplayLinkUserAgent"

    @Published private(set) var snapshot = DisplayLinkSnapshot()
    @Published private(set) var launchError: String?
    @Published private(set) var monitoringWarning: String?
    @Published private(set) var launching = false

    private var started = false
    private var suspended = false
    private var wakeSettlesAt: TimeInterval = 0
    private var policy = DisplayLinkLaunchPolicy()
    private var pendingRefresh: Task<Void, Never>?
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var preferenceObserver: AnyCancellable?
    private var notificationPort: IONotificationPortRef?
    private var usbIterators: [io_iterator_t] = []
    private var powerSource: CFRunLoopSource?

    func start() {
        guard !started else { return }
        started = true
        suspended = false
        policy = DisplayLinkLaunchPolicy()
        monitoringWarning = nil
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in self?.scheduleRefresh() }
        observe(NotificationCenter.default, NSApplication.didBecomeActiveNotification) { [weak self] in self?.scheduleRefresh() }
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.didWakeNotification) { [weak self] in
            self?.suspended = false
            self?.wakeSettlesAt = ProcessInfo.processInfo.systemUptime + 3
            self?.policy.allowRetry()
            self?.scheduleRefresh(delay: 3)
        }
        observe(workspace, NSWorkspace.willSleepNotification) { [weak self] in
            self?.suspended = true
            self?.pendingRefresh?.cancel()
        }
        for event in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            let token = workspace.addObserver(forName: event, object: nil, queue: .main) { [weak self] notification in
                guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == Self.bundleID else { return }
                MainActor.assumeIsolated { self?.scheduleRefresh() }
            }
            observers.append((workspace, token))
        }
        preferenceObserver = Defaults.publisher(.startDisplayLinkWhenConnected, options: [])
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.policy.allowRetry()
                self?.scheduleRefresh()
            }
        installUSBNotifications()
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<DisplayLinkManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in manager.scheduleRefresh() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        scheduleRefresh()
    }

    func stop() {
        started = false
        pendingRefresh?.cancel()
        pendingRefresh = nil
        preferenceObserver = nil
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        for iterator in usbIterators { IOObjectRelease(iterator) }
        usbIterators.removeAll()
        if let notificationPort { IONotificationPortDestroy(notificationPort) }
        notificationPort = nil
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
    }

    func refresh() {
        guard !suspended else { return }
        let appURL = applicationURL()
        var next = DisplayLinkSnapshot()
        next.inspected = true
        next.usbDevices = DisplayLinkHardware.devices()
        next.appInstalled = appURL != nil
        next.appRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        next.appVersion = appURL.flatMap { Bundle(url: $0)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String }
        next.model = DisplayLinkHardware.modelIdentifier()
        next.screens = DisplayLinkHardware.screens()
        next.onACPower = DisplayLinkHardware.onACPower()
        next.lidClosed = DisplayLinkHardware.lidClosed()
        if next != snapshot { snapshot = next }
        if next.appRunning { launchError = nil }
        let mayStart = started && ProcessInfo.processInfo.systemUptime >= wakeSettlesAt && Defaults[.startDisplayLinkWhenConnected]
        if !launching && policy.shouldLaunch(next, enabled: mayStart) {
            openManager(activate: false)
        }
    }

    func openManager(activate: Bool = true) {
        guard !launching else { return }
        guard let url = applicationURL() else {
            launchError = "Install DisplayLink Manager from Synaptics, then check again."
            return
        }
        launching = true
        policy.recordAttempt()
        launchError = nil
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = activate
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { [weak self] _, error in
            Task { @MainActor in
                guard let self else { return }
                self.launching = false
                if let error { self.launchError = "Could not open DisplayLink Manager: \(error.localizedDescription)" }
                // No recursive retry on failure. Only a later attach/wake or
                // explicit Open action should try again.
                if self.started { self.scheduleRefresh() }
            }
        }
    }

    private func applicationURL() -> URL? {
        if let runningURL = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).first?.bundleURL { return runningURL }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private func scheduleRefresh(delay: Double = 1) {
        guard started, !suspended else { return }
        pendingRefresh?.cancel()
        let settleDelay = max(delay, wakeSettlesAt - ProcessInfo.processInfo.systemUptime)
        pendingRefresh = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(settleDelay)) } catch { return }
            guard let self, self.started, !self.suspended else { return }
            self.refresh()
        }
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in MainActor.assumeIsolated { action() } }
        observers.append((center, token))
    }

    private func installUSBNotifications() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else {
            monitoringWarning = "Automatic USB detection is unavailable. Use Check again after connecting."
            return
        }
        notificationPort = port
        IONotificationPortSetDispatchQueue(port, DispatchQueue.main)
        for event in [kIOFirstMatchNotification, kIOTerminatedNotification] {
            guard let matching = DisplayLinkHardware.matchingDevices() else { break }
            var iterator: io_iterator_t = 0
            let result = IOServiceAddMatchingNotification(port, event, matching, { context, iterator in
                while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
                guard let context else { return }
                let manager = Unmanaged<DisplayLinkManager>.fromOpaque(context).takeUnretainedValue()
                Task { @MainActor in manager.scheduleRefresh() }
            }, Unmanaged.passUnretained(self).toOpaque(), &iterator)
            guard result == KERN_SUCCESS else {
                if iterator != 0 { IOObjectRelease(iterator) }
                break
            }
            // The initial iterator must be drained to arm subsequent events.
            while case let entry = IOIteratorNext(iterator), entry != 0 { IOObjectRelease(entry) }
            usbIterators.append(iterator)
        }
        if usbIterators.count != 2 {
            monitoringWarning = "Automatic USB detection is incomplete. Use Check again after connecting."
        }
    }
}
