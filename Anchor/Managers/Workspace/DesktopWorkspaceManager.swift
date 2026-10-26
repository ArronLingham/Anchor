import AppKit
import ApplicationServices
import Combine
import IOKit.ps

@MainActor
final class DesktopWorkspaceManager: ObservableObject {
    static let shared = DesktopWorkspaceManager()
    static let storageKey = "Anchor.desktopWorkspace.v1"
    private let preferences: UserDefaults

    @Published var configuration: DesktopWorkspaceConfiguration {
        didSet {
            do {
                let data = try JSONEncoder().encode(configuration)
                preferences.set(data, forKey: Self.storageKey)
                if oldValue.docks != configuration.docks { dockController?.reconcile() }
                if started && (oldValue.automationEnabled != configuration.automationEnabled || oldValue.modes.map(\.rule) != configuration.modes.map(\.rule) || oldValue.modes.map(\.id) != configuration.modes.map(\.id)) {
                    scheduleEnvironmentCheck()
                }
            } catch { status = "Could not save workspace: \(error.localizedDescription)" }
        }
    }
    @Published private(set) var activeModeID: UUID?
    @Published private(set) var applying = false
    @Published var status = "Choose a mode, or save your current layout."
    @Published private(set) var issues: [String] = []
    @Published private(set) var manualHold = false
    @Published private(set) var environment = WorkspaceEnvironment(externalDisplayIDs: [], onAC: false, charging: false)
    @Published private(set) var runningBundleIDs: Set<String> = []
    private var automation = WorkspaceAutomationState()
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private var powerSource: CFRunLoopSource?
    private var environmentWork: DispatchWorkItem?
    private var applyTask: Task<Void, Never>?
    private var dockController: DesktopDockController?
    private var started = false

    init(preferences: UserDefaults = .standard) {
        self.preferences = preferences
        if let data = preferences.data(forKey: Self.storageKey) {
            do { configuration = try JSONDecoder().decode(DesktopWorkspaceConfiguration.self, from: data) }
            catch {
                configuration = DesktopWorkspaceConfiguration()
                status = "Saved workspaces could not be read. Your original data is preserved until you edit a workspace."
            }
        } else { configuration = DesktopWorkspaceConfiguration() }
    }

    func start() {
        guard !started else { return }
        started = true
        dockController = DesktopDockController(manager: self)
        dockController?.reconcile()
        observe(.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.dockController?.reconcile()
            self?.scheduleEnvironmentCheck()
        }
        observe(NSWorkspace.shared.notificationCenter, NSWorkspace.didWakeNotification) { [weak self] in self?.scheduleEnvironmentCheck() }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            observe(NSWorkspace.shared.notificationCenter, name) { [weak self] in self?.refreshRunningApps() }
        }
        if let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let manager = Unmanaged<DesktopWorkspaceManager>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in manager.scheduleEnvironmentCheck() }
        }, Unmanaged.passUnretained(self).toOpaque())?.takeRetainedValue() {
            powerSource = source
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
        refreshRunningApps()
        scheduleEnvironmentCheck()
    }

    func stop() {
        applyTask?.cancel()
        environmentWork?.cancel()
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .commonModes) }
        powerSource = nil
        dockController?.closeAll()
        dockController = nil
        started = false
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, action: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observers.append((center, token))
    }

    private func refreshRunningApps() {
        runningBundleIDs = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    }

    func scheduleEnvironmentCheck() {
        guard started else { return }
        environmentWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.evaluateEnvironment() }
        environmentWork = work
        // USB-C power and display changes arrive separately. Wait for the setup to settle.
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func evaluateEnvironment() {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sourceType = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as [CFTypeRef]
        let charging = sources.contains { source in
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any] else { return false }
            return description[kIOPSIsChargingKey] as? Bool ?? false
        }
        let displays = NSScreen.screens.filter {
            guard let number = $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(number.uint32Value) == 0
        }
        environment = WorkspaceEnvironment(externalDisplayIDs: Set(displays.map { LauncherWidgetProfile.screenID($0) }),
                                           onAC: sourceType == kIOPSACPowerValue, charging: charging)
        guard !applying else { return }
        let next = automation.decide(configuration: configuration, environment: environment)
        manualHold = automation.manualHold
        if let next { apply(next, manually: false) }
    }

    func resumeAutomation() {
        automation.resume()
        manualHold = false
        scheduleEnvironmentCheck()
    }

    func apply(_ id: UUID, manually: Bool = true) {
        guard !applying, let mode = configuration.modes.first(where: { $0.id == id }) else { return }
        if manually { automation.holdManually(); manualHold = true }
        applying = true
        issues = []
        status = "Applying \(mode.name)…"
        applyTask = Task { @MainActor in
            defer { applying = false; scheduleEnvironmentCheck() }
            guard !Task.isCancelled else { return }
            var problems: [String] = []
            let required = mode.apps + mode.windows.map(\.app)
            let wanted = Set(required.map(\.bundleID))
            for app in mode.quitApps where !wanted.contains(app.bundleID) && app.bundleID != Bundle.main.bundleIdentifier && app.bundleID != "com.apple.finder" {
                for running in NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID) {
                    if !running.terminate() { problems.append("\(app.name): declined the quit request.") }
                }
            }
            var launched = Set<String>()
            for app in required where launched.insert(app.bundleID).inserted {
                guard !Task.isCancelled else { return }
                let running = NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID)
                if !running.isEmpty {
                    for instance in running { _ = instance.unhide() }
                    continue
                }
                guard let url = app.applicationURL else { problems.append("\(app.name): app is no longer installed."); continue }
                let options = NSWorkspace.OpenConfiguration()
                options.activates = false
                do { _ = try await NSWorkspace.shared.openApplication(at: url, configuration: options) }
                catch { problems.append("\(app.name): could not open (\(error.localizedDescription)).") }
            }
            guard !Task.isCancelled else { return }
            if let volume = mode.volume {
                SystemVolumeController.shared.setVolume(Float(volume))
                if abs(Double(SystemVolumeController.shared.currentVolume) - volume) > 0.08 {
                    problems.append("The current audio device did not accept the saved volume.")
                }
            }
            if let brightness = mode.brightness {
                let builtIn = NSScreen.screens.first {
                    let id = ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                    return CGDisplayIsBuiltin(id) != 0
                }
                if let builtIn { SystemBrightnessController.shared.setBrightnessImmediate(Float(brightness), for: builtIn) }
                else { problems.append("Built-in display brightness is unavailable in this setup.") }
            }
            if let ids = mode.visibleDockIDs {
                for index in configuration.docks.indices { configuration.docks[index].enabled = ids.contains(configuration.docks[index].id) }
            }
            if !mode.windows.isEmpty {
                if !WorkspaceWindows.permitted { problems.append("Allow Anchor in System Settings → Privacy & Security → Accessibility to arrange windows.") }
                else {
                    var remaining = mode.windows
                    var used: [String: [AXUIElement]] = [:]
                    for _ in 0..<12 {
                        guard !Task.isCancelled else { return }
                        let result = WorkspaceWindows.restore(remaining, used: &used)
                        remaining = result.pending
                        problems += result.issues
                        if remaining.isEmpty { break }
                        try? await Task.sleep(for: .milliseconds(650))
                    }
                    problems += remaining.map { "\($0.app.name): no matching open window. Open its document, then apply again." }
                }
            }
            guard !Task.isCancelled else { return }
            let shortcut = mode.shortcutName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !shortcut.isEmpty {
                status = "Running Shortcut for \(mode.name)…"
                if let error = await Self.runShortcut(shortcut) { problems.append(error) }
            }
            if !mode.quitApps.isEmpty { try? await Task.sleep(for: .milliseconds(400)) }
            // A save dialog can keep an app alive even after terminate() accepts the request.
            for app in mode.quitApps where !wanted.contains(app.bundleID) && app.bundleID != Bundle.main.bundleIdentifier && app.bundleID != "com.apple.finder" {
                if !NSRunningApplication.runningApplications(withBundleIdentifier: app.bundleID).isEmpty {
                    problems.append("\(app.name) is still open; it may need you to save work.")
                }
            }
            guard !Task.isCancelled else { return }
            activeModeID = mode.id
            issues = Array(Set(problems)).sorted()
            status = issues.isEmpty ? "\(mode.name) applied." : "\(mode.name) applied with \(issues.count) item(s) to review."
        }
    }

    func cancelApply() {
        applyTask?.cancel()
        status = "Stopped applying. Changes already made remain in place."
    }

    private static func runShortcut(_ name: String) async -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() }
        catch { return "Could not run Shortcut ‘\(name)’." }
        // No shell interpolation. Bound the wait and keep Anchor responsive while it runs.
        for _ in 0..<240 {
            if !process.isRunning {
                return process.terminationStatus == 0 ? nil : "Shortcut ‘\(name)’ did not complete successfully."
            }
            if Task.isCancelled { process.terminate(); return "Shortcut canceled." }
            try? await Task.sleep(for: .milliseconds(500))
        }
        if process.isRunning { process.terminate() }
        return "Shortcut ‘\(name)’ exceeded two minutes. Check it in Shortcuts."
    }

    func captureLayout(for id: UUID) {
        guard WorkspaceWindows.permitted else {
            WorkspaceWindows.requestAccess()
            status = "Grant Accessibility access, then capture the layout again."
            return
        }
        guard let index = configuration.modes.firstIndex(where: { $0.id == id }) else { return }
        let windows = WorkspaceWindows.capture()
        guard !windows.isEmpty else { status = "No standard windows found. Existing layout was kept."; return }
        configuration.modes[index].windows = windows
        var apps = configuration.modes[index].apps
        for window in windows where !apps.contains(where: { $0.bundleID == window.app.bundleID }) { apps.append(window.app) }
        configuration.modes[index].apps = apps
        status = "Saved \(windows.count) windows for \(configuration.modes[index].name)."
    }

    func chooseApps(_ completion: ([WorkspaceApp]) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose apps"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.treatsFilePackagesAsDirectories = false
        guard panel.runModal() == .OK else { return }
        completion(panel.urls.compactMap { WorkspaceApp(url: $0) })
    }

    func launch(_ app: WorkspaceApp) {
        guard let url = app.applicationURL else { status = "\(app.name) is no longer installed."; return }
        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { _, error in
            if let error { Task { @MainActor in self.status = error.localizedDescription } }
        }
    }

    func addDockApp(_ app: WorkspaceApp, to id: UUID) {
        guard let index = configuration.docks.firstIndex(where: { $0.id == id }),
              !configuration.docks[index].apps.contains(where: { $0.bundleID == app.bundleID }) else { return }
        configuration.docks[index].apps.append(app)
    }

    func recordDockPosition(_ id: UUID, frame: CGRect) {
        guard let index = configuration.docks.firstIndex(where: { $0.id == id }),
              let screen = NSScreen.screens.first(where: { $0.frame.contains(CGPoint(x: frame.midX, y: frame.midY)) }) else { return }
        let bounds = screen.visibleFrame.insetBy(dx: 8, dy: 8)
        configuration.docks[index].displayID = LauncherWidgetProfile.screenID(screen)
        configuration.docks[index].x = max(0, min(1, (frame.minX - bounds.minX) / max(1, bounds.width - frame.width)))
        configuration.docks[index].y = max(0, min(1, (frame.minY - bounds.minY) / max(1, bounds.height - frame.height)))
    }
}
