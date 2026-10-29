import AppKit
import ApplicationServices
import Combine
import Defaults
import CoreAudio
import IOKit.pwr_mgt
import SwiftUI

@MainActor
private final class DashboardActivity: ObservableObject {
    @Published var isActive = false
}

private struct DashboardRootView: View {
    @ObservedObject var activity: DashboardActivity
    let hardware: DashboardHardwareState
    let section: DashboardSection
    let onSectionChange: (DashboardSection) -> Void
    var body: some View {
        DashboardView(hardware: hardware, section: section, onSectionChange: onSectionChange)
            .environment(\.dashboardIsActive, activity.isActive)
    }
}

@MainActor
final class DashboardWindowController: NSWindowController, NSWindowDelegate {
    static let shared = DashboardWindowController()
    let hardware = DashboardHardwareState()
    private var previousApp: NSRunningApplication?
    private var lockObserver: NSObjectProtocol?
    private let activity = DashboardActivity()
    private var selectedSection: DashboardSection = .overview
    private var contentInstalled = false

    private init() {
        super.init(window: nil)
        lockObserver = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in self?.hideAndReleaseContent() } }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func toggle() { window?.isVisible == true ? window?.close() : show() }

    func show() {
        if let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier { previousApp = app }
        if window == nil {
            let created = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 780),
                styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            created.title = "Anchor Dashboard"; created.titlebarAppearsTransparent = true
            created.titleVisibility = .hidden
            created.appearance = NSAppearance(named: .darkAqua)
            created.isReleasedWhenClosed = false; created.minSize = NSSize(width: 620, height: 540)
            created.delegate = self
            created.setFrameAutosaveName("AnchorDashboard")
            if !created.setFrameUsingName("AnchorDashboard") { created.center() }
            ScreenCaptureVisibilityManager.shared.register(created, scope: .panelsOnly)
            window = created
        }
        installContentIfNeeded()
        if let window {
            AnchorApplicationPresentation.shared.register(window)
            if window.isMiniaturized { window.deminiaturize(nil) }
        }
        activity.isActive = true
        hardware.start()
        window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if let window { AnchorApplicationPresentation.shared.register(window) }
        updateActivity()
    }
    func windowWillClose(_ notification: Notification) {
        activity.isActive = false
        hardware.stop()
        // A closed NSWindow retains its content. Release observations, decoded
        // images, and view-owned sampling leases instead of retaining the UI.
        window?.contentView = nil
        contentInstalled = false
        if let window { AnchorApplicationPresentation.shared.unregister(window) }
    }

    func windowDidMiniaturize(_ notification: Notification) { updateActivity() }
    func windowDidDeminiaturize(_ notification: Notification) { updateActivity() }
    func windowDidChangeOcclusionState(_ notification: Notification) { updateActivity() }

    private func updateActivity() {
        let active = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        if activity.isActive != active { activity.isActive = active }
        if active { hardware.start() } else { hardware.stop() }
    }

    private func installContentIfNeeded() {
        guard let window, !contentInstalled else { return }
        window.contentView = NSHostingView(rootView: DashboardRootView(activity: activity, hardware: hardware,
            section: selectedSection, onSectionChange: { [weak self] in self?.selectedSection = $0 }))
        contentInstalled = true
    }

    private func hideAndReleaseContent() {
        activity.isActive = false
        window?.orderOut(nil)
        hardware.stop()
        window?.contentView = nil
        contentInstalled = false
        if let window { AnchorApplicationPresentation.shared.unregister(window) }
    }

    #if DEBUG
    func reviewResourceLifecycle(into directory: URL) async {
        var checks: [String] = []
        func check(_ name: String, _ passed: Bool) { checks.append("\(passed ? "PASS" : "FAIL"): \(name)") }
        selectedSection = .system
        show()
        try? await Task.sleep(for: .milliseconds(600))
        check("dashboard content installed", contentInstalled)
        check("system card acquires shared sampler", SystemStatsManager.shared.isSampling)
        window?.miniaturize(nil)
        try? await Task.sleep(for: .milliseconds(600))
        check("minimizing parks shared sampler", !SystemStatsManager.shared.isSampling)
        check("minimizing retains view content", contentInstalled)
        show()
        try? await Task.sleep(for: .milliseconds(600))
        check("restoring resumes shared sampler", SystemStatsManager.shared.isSampling)
        window?.close()
        try? await Task.sleep(for: .milliseconds(300))
        check("closing releases content", !contentInstalled && window?.contentView == nil)
        check("closing releases shared sampler", !SystemStatsManager.shared.isSampling)
        show()
        try? await Task.sleep(for: .milliseconds(600))
        check("reopening restores section", selectedSection == .system && SystemStatsManager.shared.isSampling)
        hideAndReleaseContent()
        try? await Task.sleep(for: .milliseconds(300))
        check("hiding releases content and sampler", !contentInstalled && !SystemStatsManager.shared.isSampling)
        try? checks.joined(separator: "\n").write(to: directory.appendingPathComponent("dashboard-lifecycle.txt"),
            atomically: true, encoding: .utf8)
    }
    #endif

    func arrangePreviousWindow(_ zone: SnapZoneManager.Zone) {
        guard AXIsProcessTrusted() else { hardware.message = "Allow Accessibility in Anchor’s settings to arrange windows."; return }
        guard let app = previousApp, !app.isTerminated else { hardware.message = "Open the dashboard while another app is active to arrange its window."; return }
        hideAndReleaseContent()
        app.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { SnapZoneManager.shared.apply(zone) }
    }

    static func openNotch(_ view: NotchViews) {
        switch view {
        case .todo: Defaults[.enableTodoFeature] = true
        case .notes: Defaults[.enableNotes] = true
        case .terminal: Defaults[.enableTerminalFeature] = true
        default: break
        }
        AnchorViewCoordinator.shared.currentView = view
        AppDelegate.shared?.vm.open()
    }
}

/// Subscribes to existing hardware notifications while the dashboard is visible.
/// It deliberately leaves the HUD controllers' callback slots alone.
@MainActor
final class DashboardHardwareState: ObservableObject {
    struct Display: Identifiable, Equatable { var id: CGDirectDisplayID; var name: String; var screen: NSScreen }
    @Published private(set) var volume = 0.0
    @Published private(set) var isMuted = false
    @Published private(set) var canSetVolume = false
    @Published private(set) var canMute = false
    @Published private(set) var brightness = 0.5
    @Published private(set) var canSetBrightness = false
    @Published private(set) var displays: [Display] = []
    @Published var selectedDisplayID = CGMainDisplayID() {
        didSet { if oldValue != selectedDisplayID { refreshBrightness() } }
    }
    @Published var message: String?
    private var cancellables = Set<AnyCancellable>()

    func start() {
        guard cancellables.isEmpty else { return }
        let center = NotificationCenter.default
        center.publisher(for: .systemVolumeDidChange).receive(on: RunLoop.main)
            .sink { [weak self] notification in
                // The audio controller already read these values. Do not repeat
                // its CoreAudio queries or enumerate displays for a volume tick.
                if let value = notification.userInfo?["value"] as? Float,
                   let muted = notification.userInfo?["muted"] as? Bool {
                    self?.updateAudioLevel(Double(value), muted: muted)
                } else {
                    self?.refreshAudioLevel()
                }
            }
            .store(in: &cancellables)
        center.publisher(for: .systemAudioRouteDidChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshAudioCapabilities(); self?.refreshAudioLevel() }
            .store(in: &cancellables)
        center.publisher(for: .systemBrightnessDidChange).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshBrightness() }
            .store(in: &cancellables)
        center.publisher(for: NSApplication.didChangeScreenParametersNotification).receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refreshDisplays() }
            .store(in: &cancellables)
        refresh()
    }
    func stop() { cancellables.removeAll() }

    func refresh() {
        refreshAudioCapabilities()
        refreshAudioLevel()
        refreshDisplays()
    }

    private func refreshAudioLevel() {
        let controller = SystemVolumeController.shared
        updateAudioLevel(Double(controller.currentVolume), muted: controller.isMuted)
    }

    private func updateAudioLevel(_ raw: Double, muted: Bool) {
        let value = raw.isFinite ? min(1, max(0, raw)) : 0
        if volume != value { volume = value }
        if isMuted != muted { isMuted = muted }
    }

    private func refreshAudioCapabilities() {
        var device: AudioDeviceID = 0
        var defaultAddress = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var deviceSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &defaultAddress, 0, nil, &deviceSize, &device)
        let volumeWritable = supportsWrite(device, selector: kAudioDevicePropertyVolumeScalar)
        let muteWritable = supportsWrite(device, selector: kAudioDevicePropertyMute)
        if canSetVolume != volumeWritable { canSetVolume = volumeWritable }
        if canMute != muteWritable { canMute = muteWritable }
    }

    private func refreshDisplays() {
        let connected = NSScreen.screens.compactMap { screen -> Display? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }
            return Display(id: id, name: screen.localizedName, screen: screen)
        }
        if displays != connected { displays = connected }
        if !connected.contains(where: { $0.id == selectedDisplayID }), let first = connected.first {
            selectedDisplayID = first.id
        } else {
            refreshBrightness()
        }
    }

    private func supportsWrite(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> Bool {
        for element in [kAudioObjectPropertyElementMain, 1, 2] as [UInt32] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
            var writable = DarwinBoolean(false)
            if AudioObjectIsPropertySettable(device, &address, &writable) == noErr && writable.boolValue { return true }
        }
        return false
    }

    private func refreshBrightness() {
        guard let result = DisplayServicesDynamic.shared.getBrightness(displayID: selectedDisplayID),
              result.status == 0, result.value.isFinite else {
            if canSetBrightness { canSetBrightness = false }
            return
        }
        if !canSetBrightness { canSetBrightness = true }
        let value = Double(min(1, max(0, result.value)))
        if brightness != value { brightness = value }
    }
    func setVolume(_ value: Double) {
        guard canSetVolume, value.isFinite else { return }
        let clamped = Double(Float(min(1, max(0, value))))
        guard volume != clamped else { return }
        volume = clamped
        SystemVolumeController.shared.setVolume(Float(clamped))
    }
    func toggleMute() {
        guard canMute else { return }
        SystemVolumeController.shared.toggleMute()
        refreshAudioLevel()
    }
    func setBrightness(_ value: Double) {
        guard canSetBrightness, value.isFinite,
              let display = displays.first(where: { $0.id == selectedDisplayID }) else { return }
        let clamped = Double(Float(min(1, max(0, value))))
        guard brightness != clamped else { return }
        brightness = clamped
        SystemBrightnessController.shared.setBrightnessImmediate(Float(clamped), for: display.screen)
    }

    func report(_ result: QuickToggles.Outcome) {
        switch result { case .success(let text): message = text; case .failure(let text): message = text }
    }
}

@MainActor
final class KeepAwakeManager: ObservableObject {
    static let shared = KeepAwakeManager()
    @Published private(set) var isEnabled = false
    @Published private(set) var error: String?
    private var assertion: IOPMAssertionID = 0
    private var expiry: DispatchWorkItem?

    func toggle() {
        if isEnabled { stop(); return }
        let status = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn), "Anchor dashboard keep awake" as CFString, &assertion)
        guard status == kIOReturnSuccess else { error = "Could not prevent idle sleep."; return }
        isEnabled = true; error = nil
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        expiry = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 3600, execute: work)
    }
    func stop() {
        expiry?.cancel(); expiry = nil
        if isEnabled { IOPMAssertionRelease(assertion) }
        assertion = 0; isEnabled = false
    }
}
