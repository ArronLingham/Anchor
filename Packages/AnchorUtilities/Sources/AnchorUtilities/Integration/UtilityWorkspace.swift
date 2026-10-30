import AppKit
import Combine
import SwiftUI
import UserNotifications

public struct UtilityFeature: Identifiable, Equatable {
    public let id: String
    public let title: String
    public let summary: String
    public let symbol: String
    public let group: String
    public let isAvailable: Bool
    public var isEnabled: Bool { isAvailable }
    public let isActive: Bool
    public let isSupported: Bool
    public let unsupportedReason: String?
    public let canRun: Bool
}

/// The only boundary between Anchor and the native utility engines. No second
/// application delegate, updater, main menu, or executable owns app lifecycle.
public final class UtilityWorkspace: ObservableObject {
    public static let shared = UtilityWorkspace()
    @Published public private(set) var revision = 0
    @Published public private(set) var favorites: [String]
    @Published public private(set) var featureNotice: String?
    @Published public private(set) var featureToEnable: String?
    public var onControlOwnershipChange: ((Set<String>) -> Void)?
    @Published public var controlsVisible = false
    public var onOpenControls: (() -> Void)?
    public var onOpenIslandSettings: (() -> Void)?
    public var onOpenAnchorSettings: (() -> Void)?
    public var onOpenFeatureLibrary: (() -> Void)?
    public var onShowAnchorMenuIcon: (() -> Void)?
    public var onWindowActivityChange: ((Bool) -> Void)?
    public var onMicrophoneMuteChange: ((Bool) -> Void)?

    lazy var host = AppDelegate()
    private var started = false
    private var lastOwners = Set<String>()
    public var controlOwners: Set<String> { lastOwners }
    private var subscriptions = Set<AnyCancellable>()
    private var preferenceUpdate: DispatchWorkItem?

    private init() {
        UtilityPreferences.register()
        favorites = UtilityPreferences.standard.stringArray(forKey: "Anchor.favoriteFeatures")
            ?? ["commandBar", "screenshot", "screenRecorder", "scratchpad", "windowLayout", "mediaTools"]
    }

    /// Called at the beginning of Anchor's entry point, before any scene is
    /// created. Recovery children finish here without constructing Anchor UI.
    public static func prepareProcess() {
        SuperKeyMappingGuard.runIfRequestedAndExit()
        MouseAccelerationGuard.runIfRequestedAndExit()
    }

    public func start() {
        guard !started else { return }
        started = true
        LaunchAtLogin.repairAtStartup()
        // Anchor owns the one island. Keep imported choices, but retire its renderer.
        UtilityPreferences.standard.set(false, forKey: DefaultsKey.notchEnabled)
        GlobalShortcut.startObservingKeyboardLayout()
        NotchControlItem.keyboardLightIsSupported = { BrightnessService.keyboardLightIsSupported }
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.35)
        HorizontalWheelScrolling.install()
        MouseAccelerationService.recoverPendingAtLaunch()
        SystemShortcutTakeover.recoverIfNeeded(keeping: AppSwitcher.launchTakeoverIDs())
        LegacySpacesOrderRecovery.recoverIfNeeded()
        if Bundle.main.bundleIdentifier != nil, UNUserNotificationCenter.current().delegate == nil {
            UNUserNotificationCenter.current().delegate = host
        }
        prepareOwnership()
        BrightnessService.shared.restoreDisplaysLeftOff()
        KeepAwakeManager.shared.onSessionEnded = { reason in
            let s = L10n.shared.s
            switch reason {
            case .timer: Notifier.post(title: s.notifySessionEndedTitle, body: s.notifySessionEndedBody)
            case .battery: Notifier.post(title: s.notifyBatteryTitle, body: s.notifyBatteryBody)
            default: break
            }
        }
        HotkeyManager.shared.onActivate = { KeepAwakeManager.shared.toggle() }
        KeepAwakeManager.shared.recoverIfNeeded { KeepAwakeManager.shared.activateOnLaunchIfNeeded() }
        FanControlService.recoverIfNeeded()
        FeatureRuntime.shared.$revision.dropFirst().sink { [weak self] _ in
            self?.prepareOwnership()
            self?.revision += 1
            self?.host.syncStatusItems()
        }.store(in: &subscriptions)
        Permissions.shared.$accessibility.removeDuplicates().dropFirst().sink { _ in
            DispatchQueue.main.async { FeatureRuntime.shared.syncAtLaunch() }
        }.store(in: &subscriptions)
        Permissions.shared.$screenRecording.removeDuplicates().dropFirst().sink { _ in
            DispatchQueue.main.async { FeatureRuntime.shared.sync([.dockPreview, .screenRecorder, .notchWatch]) }
        }.store(in: &subscriptions)
        NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification,
                                             object: UtilityPreferences.standard)
            .sink { [weak self] _ in self?.schedulePreferenceUpdate() }
            .store(in: &subscriptions)
        FeatureRuntime.shared.syncAtLaunch()
        KeepAwakeManager.shared.$isActive.dropFirst().sink { [weak self] _ in
            self?.host.syncStatusItems()
        }.store(in: &subscriptions)
        host.syncStatusItems()
    }

    private func schedulePreferenceUpdate() {
        preferenceUpdate?.cancel()
        let work = DispatchWorkItem { [weak self] in
            FeatureRuntime.shared.reconcileAvailability()
            self?.prepareOwnership()
            self?.revision += 1
            self?.host.syncStatusItems()
        }
        preferenceUpdate = work
        DispatchQueue.main.async(execute: work)
    }

    /// Runs before a replacement engine starts, including settings edits made
    /// after its tile was added. A handover is synchronous on the main thread.
    func prepareOwnership() {
        let ids: Set<String> = [
            "switcher", "scrollInverter", "mouseNavigation", "mouseButtonShortcuts",
            "focusFollowsMouse", "keyboardDebounce", "textSnippets", "autoQuit",
            "musicBlock", "windowLayout", "diskImageInstaller", "clipboardHistory",
            "urlCleaner", "mixer", "notch", "brightness",
        ]
        var owners = Set(AppFeature.allCases.filter { feature in
            guard ids.contains(feature.rawValue), feature.isAvailable else { return false }
            switch feature {
            case .brightness:
                return UtilityPreferences.standard.bool(forKey: DefaultsKey.brightnessControlEnabled)
                    && (UtilityPreferences.standard.bool(forKey: DefaultsKey.brightnessKeysEnabled)
                        || UtilityPreferences.standard.bool(forKey: DefaultsKey.brightnessOSDEnabled)
                        || BrightnessSupport.KeyStep.sanitized(UtilityPreferences.standard.string(forKey: DefaultsKey.brightnessKeyStep)) != .standard)
            case .windowLayout:
                return [DefaultsKey.windowEdgeSnapEnabled, DefaultsKey.windowGestureEnabled,
                        DefaultsKey.windowLayoutShortcutsEnabled].contains {
                    UtilityPreferences.standard.bool(forKey: $0)
                }
            case .notch: return false
            default:
                return feature.enabledKeys.isEmpty || feature.enabledKeys.contains {
                    UtilityPreferences.standard.bool(forKey: $0)
                }
            }
        }.map(\.rawValue))
        if AppFeature.mixer.isAvailable,
           UtilityPreferences.standard.bool(forKey: DefaultsKey.preciseVolumeRollerEnabled) {
            owners.insert("volumeKeys")
        }
        if owners.contains("notch"), UtilityPreferences.standard.bool(forKey: DefaultsKey.notchLockScreen) {
            owners.insert("lockScreenIsland")
        }
        if owners.contains("notch"), UtilityPreferences.standard.bool(forKey: DefaultsKey.notchLockSounds) {
            owners.insert("lockSounds")
        }
        if (AppFeature.audioPriority.isAvailable && UtilityPreferences.standard.bool(forKey: DefaultsKey.audioPriorityInputEnabled))
            || (AppFeature.mixer.isAvailable && !(UtilityPreferences.standard.string(forKey: DefaultsKey.preferredInputDevice) ?? "").isEmpty) {
            owners.insert("audioInput")
        }
        owners.formUnion(Self.clipboardAutoClearOwners(
            available: AppFeature.clipboardHistory.isAvailable, defaults: UtilityPreferences.standard))
        guard owners != lastOwners else { return }
        lastOwners = owners
        onControlOwnershipChange?(owners)
    }

    public var features: [UtilityFeature] {
        let language = L10n.shared.language
        let s = L10n.shared.s
        let hub = FeatureStrings.hub(language)
        return AppFeature.allCases.filter { !$0.rawValue.hasPrefix("notch") }.map { feature in
            UtilityFeature(
                id: feature.rawValue, title: feature.hubTitle(s, hub: hub),
                summary: feature.hubDescription(hub), symbol: feature.symbolName,
                group: CommandBarCatalog.groupTitle(feature.group, hub: hub),
                isAvailable: feature.isAvailable,
                isActive: feature.isAvailable && (feature.enabledKeys.isEmpty
                    || feature.enabledKeys.contains { UtilityPreferences.standard.bool(forKey: $0) }),
                isSupported: feature.isHardwareSupported,
                unsupportedReason: feature.hardwareUnsupportedReason,
                canRun: Self.launchable.contains(feature.rawValue))
        }
    }

    public var commandBarShortcutHint: String {
        guard AppFeature.commandBar.isAvailable else { return "Command Bar is off — enable it in the library" }
        guard UtilityPreferences.standard.bool(forKey: DefaultsKey.commandBarShortcutEnabled) else { return "Command Bar shortcut is off" }
        if started, CommandBarService.shared.shortcutRegistrationFailed { return "Choose an available Command Bar shortcut" }
        return "Command Bar · " + GlobalShortcut.saved(for: DefaultsKey.commandBarShortcut,
                                                       fallback: .commandBarDefault).displayString
    }

    public func setEnabled(_ id: String, _ enabled: Bool) {
        guard let feature = AppFeature(rawValue: id) else { return }
        featureNotice = nil
        FeatureRuntime.shared.setAvailable([feature], enabled)
    }

    public func setAvailable(_ id: String, _ available: Bool) { setEnabled(id, available) }

    public func disableAllFeatures() {
        featureNotice = nil
        FeatureRuntime.shared.setAllAvailable(false)
    }

    public var needsRestartToUnload: Bool { FeatureRuntime.shared.needsRestartToUnload }
    public func restartToReleaseMemory() { FeatureRuntime.shared.relaunchApp() }
    public func clearFeatureNotice() { featureNotice = nil }
    func reportFeatureNotice(_ message: String) { featureNotice = message }

    func releaseDisabledFeatureViews(disabling: Bool) {
        guard started else { return }
        host.releaseInactiveViews(disabling: disabling)
    }

    public func consumeFeatureReveal(_ id: String) {
        if featureToEnable == id { featureToEnable = nil }
    }

    public func revealFeature(_ id: String) {
        featureToEnable = id
        showLibrary()
    }

    public func toggleFavorite(_ id: String) {
        guard AppFeature(rawValue: id) != nil else { return }
        if favorites.contains(id) { favorites.removeAll { $0 == id } }
        else { favorites.append(id) }
        UtilityPreferences.standard.set(favorites, forKey: "Anchor.favoriteFeatures")
    }

    public func showFeature(_ id: String) {
        if id == "notch", let onOpenIslandSettings { onOpenIslandSettings(); return }
        guard let feature = AppFeature(rawValue: id) else { return }
        if feature.isAvailable {
            SettingsRouter.shared.request(feature.settingsDestination)
        } else {
            SettingsRouter.shared.request(FeatureSettingsDestination(.features), targetFeature: feature)
        }
        host.openSettingsWindow()
    }

    public func showLibrary() {
        if let onOpenFeatureLibrary { onOpenFeatureLibrary(); return }
        showControls()
    }

    /// Shared by sidebar, search and panel deep links.
    @discardableResult
    func routeNativeSettingsPage(_ page: SettingsPage, hasSection: Bool = false) -> Bool {
        if page == .general, !hasSection, let open = onOpenAnchorSettings { open(); return true }
        if page == .features, let open = onOpenFeatureLibrary { open(); return true }
        if page == .notch || page == .notchMascot, let open = onOpenIslandSettings { open(); return true }
        return false
    }

    public func showControls() {
        SettingsRouter.shared.request(FeatureSettingsDestination(.quickTools))
        host.openSettingsWindow()
    }

    public func showPanel() { start(); host.showPanel() }

    public func releaseInputOwnership() {
        UtilityPreferences.standard.set(false, forKey: DefaultsKey.audioPriorityInputEnabled)
        UtilityPreferences.standard.set("", forKey: DefaultsKey.preferredInputDevice)
        prepareOwnership()
        AudioInputDeviceManager.shared.syncWithPreferences()
    }

    /// Hand back the delay without disabling utility history or other triggers.
    public func releaseClipboardAutoClearOwnership(_ owner: String) {
        guard Self.releaseClipboardAutoClearOwnership(owner, defaults: UtilityPreferences.standard) else { return }
        prepareOwnership()
        ClipboardAutoClearService.shared.syncWithPreferences()
    }

    static func clipboardAutoClearOwners(available: Bool, defaults: UserDefaults) -> Set<String> {
        guard available else { return [] }
        let triggers = [
            (DefaultsKey.clipboardAutoClearOnDelay, "clipboardAutoClearDelay"),
            (DefaultsKey.clipboardAutoClearOnSleep, "clipboardAutoClearSleep"),
            (DefaultsKey.clipboardAutoClearOnDisplaySleep, "clipboardAutoClearDisplaySleep"),
            (DefaultsKey.clipboardAutoClearOnScreenLock, "clipboardAutoClearLock")
        ]
        return Set(triggers.compactMap { defaults.bool(forKey: $0.0) ? $0.1 : nil })
    }

    @discardableResult
    static func releaseClipboardAutoClearOwnership(_ owner: String, defaults: UserDefaults) -> Bool {
        guard owner == "clipboardAutoClearDelay" else { return false }
        defaults.set(false, forKey: DefaultsKey.clipboardAutoClearOnDelay)
        return true
    }

    public func setGlobalMicrophoneMuted(_ muted: Bool) {
        guard AppFeature.micMute.isAvailable else { revealFeature("micMute"); return }
        start()
        MicMuteService.shared.setMuted(muted)
    }

    public func run(_ id: String) {
        guard let feature = AppFeature(rawValue: id), feature.isHardwareSupported else { return }
        guard feature.isAvailable else { revealFeature(id); return }
        // Favorites for background controls configure them; adding a favorite
        // must not silently enable an input hook or change a system setting.
        guard Self.launchable.contains(id) else { showFeature(id); return }
        start()
        switch feature {
        case .commandBar: CommandBarService.shared.toggle()
        case .quickLauncher: QuickLauncherService.shared.show()
        case .screenshot: ScreenCaptureService.shared.capture(initial: .screenshot)
        case .screenRecorder: ScreenCaptureService.shared.capture(initial: .recording)
        case .screenOCR: ScreenCaptureService.shared.capture(initial: .text)
        case .colorPicker: ColorSamplerService.shared.pick()
        case .cameraPreview: CameraPreviewService.shared.show()
        case .scratchpad: ScratchpadService.shared.show()
        case .keepAwake: KeepAwakeManager.shared.toggle()
        case .micMute: MicMuteService.shared.toggle()
        case .clipboardHistory: ClipboardHistoryService.shared.showHistoryWindow()
        case .shelf: ShelfService.shared.toggle()
        case .cleaningMode: CleaningModeManager.shared.activate()
        default: showFeature(id)
        }
    }

    private static let launchable: Set<String> = [
        "commandBar", "quickLauncher", "screenshot", "screenRecorder", "screenOCR",
        "colorPicker", "cameraPreview", "scratchpad", "keepAwake", "micMute",
        "clipboardHistory", "shelf", "cleaningMode",
    ]

    public func stop() {
        guard started else { return }
        started = false
        preferenceUpdate?.cancel()
        subscriptions.removeAll()
        host.closeWindows()
        if AppFeature.commandBar.isAvailable { CommandBarService.shared.restoreBorrowedInputSource() }
        if AppFeature.notch.isAvailable { NotchService.shared.stop(restoreCapture: false) }
        if AppFeature.brightness.isAvailable { BrightnessService.shared.restoreDisplaysBeforeTermination() }
        if AppFeature.extraBrightness.isAvailable { ExtraBrightnessService.shared.stop() }
        if AppFeature.windowLayout.isAvailable { WindowLayoutService.shared.suspend() }
        if AppFeature.switcher.isAvailable { AppSwitcher.shared.suspend() }
        if AppFeature.focusFollowsMouse.isAvailable { FocusFollowsMouseService.shared.stop() }
        if AppFeature.keyboardDebounce.isAvailable { KeyboardDebounceService.shared.suspend() }
        if AppFeature.superKey.isAvailable { SuperKeyService.shared.suspend() }
        if AppFeature.textSnippets.isAvailable { TextSnippetService.shared.suspend() }
        if AppFeature.mouseButtonShortcuts.isAvailable { MouseButtonShortcutService.shared.suspend() }
        if AppFeature.middleClick.isAvailable { MiddleClickService.shared.suspend() }
        if [.scrollInverter, .linearScroll, .scrollHorizontal].contains(where: { (feature: AppFeature) in feature.isAvailable }) {
            ScrollInverter.shared.suspend()
        }
        if AppFeature.smoothScroll.isAvailable { SmoothScrollService.shared.suspend() }
        if AppFeature.mouseNavigation.isAvailable { MouseNavigationService.shared.suspend() }
        if AppFeature.mouseClickDebounce.isAvailable { MouseClickDebounceService.shared.suspend() }
        if AppFeature.mouseAcceleration.isAvailable || MouseAccelerationRecovery.hasPendingEntries() {
            MouseAccelerationService.shared.stop()
        }
        if AppFeature.dockPreview.isAvailable { DockPreviewService.shared.stop() }
        if AppFeature.windowMaximizer.isAvailable { WindowMaximizer.shared.stop() }
        if AppFeature.urlCleaner.isAvailable { URLCleanerService.shared.stop() }
        if AppFeature.mixer.isAvailable { PreciseVolumeRollerService.shared.stop() }
        if AppFeature.mixer.isAvailable { AppVolumeMixer.shared.stopAll() }
        if AppFeature.audioPriority.isAvailable || AppFeature.mixer.isAvailable { AudioInputDeviceManager.shared.stop() }
        if AppFeature.soundOutputSwitcher.isAvailable { SoundOutputSwitcher.shared.stop() }
        if AppFeature.scratchpad.isAvailable { ScratchpadService.shared.suspend() }
        ClipboardHistoryService.existing?.flushBeforeTermination()
        if AppFeature.keepAwake.isAvailable { KeepAwakeManager.shared.deactivate(reason: .quit) }
        FanControlService.restoreBeforeTerminationIfNeeded()
        SystemShortcutTakeover.restoreAll()
    }
}

public struct UtilityControlsView: View {
    public init() {}
    public var body: some View {
        SettingsView().defaultAppStorage(UtilityPreferences.standard)
            .onAppear {
                SettingsWindowVisibility.shared.set(true)
                SecureInputMonitor.shared.setSettingsWindowOpen(true)
            }
            .onDisappear {
                SettingsWindowVisibility.shared.set(false)
                SecureInputMonitor.shared.setSettingsWindowOpen(false)
            }
    }
}
