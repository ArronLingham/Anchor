import AnchorUtilities
import AppKit
import Combine
import Defaults

extension Notification.Name {
    static let utilityControlOwnershipChanged = Notification.Name("AnchorUtilityControlOwnershipChanged")
}

@MainActor
final class UtilityIntegration: ObservableObject {
    static let shared = UtilityIntegration()
    @Published private(set) var owners = Set<String>()
    private let savedChoicesKey = "Anchor.utilitySuspendedControls.v1"
    private var handover: UtilityOwnership
    private var changingOwnership = false
    private var subscription: AnyCancellable?
    private var started = false
    private var pausedInputUID: String? = UserDefaults.standard.string(forKey: "Anchor.utilityPausedInputUID")

    private static let controlKeys: [String: [Defaults.Key<Bool>]] = [
        "switcher": [.enableAppSwitcher],
        "scrollInverter": [.invertScrollVertical, .invertScrollHorizontal],
        "mouseNavigation": [.mouseSideButtonNavigation],
        "mouseButtonShortcuts": [.mouseSideButtonNavigation],
        "focusFollowsMouse": [.enableFocusFollowsMouse],
        "keyboardDebounce": [.enableKeyDebounce],
        "textSnippets": [.enableTextSnippets],
        "autoQuit": [.enableQuitOnLastWindowClose],
        "musicBlock": [.blockMediaAppAutoLaunch],
        "windowLayout": [.enableSnapZones],
        "diskImageInstaller": [.enableDiskImageInstaller],
        "clipboardHistory": [.enableClipboardManager, .autoClearClipboardEnabled, .autoClearClipboardOnLock],
        "urlCleaner": [.autoCleanCopiedURLs],
        "mixer": [.enablePerAppAudio],
        "notch": [.enableSystemHUD, .openNotchOnHover, .extendHoverArea],
        "lockScreenIsland": [.enableLockScreenMediaWidget, .enableLockScreenLiveActivity],
        "lockSounds": [.enableLockSounds],
    ]

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: "Anchor.utilitySuspendedControls.v1") ?? [:]
        handover = UtilityOwnership(paused: saved.compactMapValues { ($0 as? NSNumber)?.boolValue })
    }

    func start(delegate: AppDelegate) {
        guard !started else { return }
        started = true
        let workspace = UtilityWorkspace.shared
        workspace.onControlOwnershipChange = { [weak self, weak delegate] owners in
            MainActor.assumeIsolated {
                self?.apply(owners)
                delegate?.setUtilityIslandActive(owners.contains("notch"))
            }
        }
        workspace.onShowAnchorMenuIcon = { Defaults[.menubarIcon] = true }
        workspace.onOpenAnchorSettings = { SettingsWindowController.shared.showWindow() }
        workspace.onOpenFeatureLibrary = { SettingsWindowController.shared.showWindow(tab: .features) }
        workspace.onWindowActivityChange = { active in
            MainActor.assumeIsolated {
                AnchorApplicationPresentation.shared.setUtilityWindowsActive(active)
            }
        }
        workspace.onMicrophoneMuteChange = { muted in
            MainActor.assumeIsolated { AudioDeviceToolsManager.shared.updateGlobalMicrophoneMute(muted) }
        }
        subscription = NotificationCenter.default.publisher(for: UserDefaults.didChangeNotification,
                                                           object: UserDefaults.standard)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.nativePreferencesChanged() }
        workspace.start()
        // Also recovers choices left paused by a previous interrupted session
        // if the corresponding advanced feature has since been removed.
        apply(workspace.controlOwners)
        delegate.setUtilityIslandActive(workspace.controlOwners.contains("notch"))
    }

    func stop() {
        guard started else { return }
        started = false
        subscription = nil
        UtilityWorkspace.shared.stop()
    }

    private func apply(_ newOwners: Set<String>) {
        guard !changingOwnership else { return }
        changingOwnership = true
        defer { changingOwnership = false }
        let controls = Self.controlKeys.mapValues { $0.map(\.name) }
        let allKeys = Set(controls.values.flatMap { $0 })
        let current = Dictionary(uniqueKeysWithValues: allKeys.map {
            ($0, UserDefaults.standard.bool(forKey: $0))
        })
        let writes = handover.reconcile(owners: newOwners, controls: controls, current: current)
        for (key, value) in writes { UserDefaults.standard.set(value, forKey: key) }
        UserDefaults.standard.set(handover.paused, forKey: savedChoicesKey)
        if newOwners.contains("audioInput") {
            if pausedInputUID == nil {
                pausedInputUID = Defaults[.pinnedInputDeviceUID]
                UserDefaults.standard.set(pausedInputUID, forKey: "Anchor.utilityPausedInputUID")
            }
            Defaults[.pinnedInputDeviceUID] = ""
        } else if let previous = pausedInputUID {
            pausedInputUID = nil
            UserDefaults.standard.removeObject(forKey: "Anchor.utilityPausedInputUID")
            Defaults[.pinnedInputDeviceUID] = previous
        }

        if newOwners.contains("mixer"), !owners.contains("mixer") { PerAppAudioManager.shared.stop() }
        if newOwners.contains("clipboardHistory"), !owners.contains("clipboardHistory") {
            ClipboardManager.shared.stopMonitoring()
        } else if owners.contains("clipboardHistory"), !newOwners.contains("clipboardHistory"),
                  Defaults[.enableClipboardManager] {
            ClipboardManager.shared.startMonitoring()
        }
        owners = newOwners
        NotificationCenter.default.post(name: .utilityControlOwnershipChanged, object: nil)
    }

    /// Enabling a classic control is an explicit handback. It removes the
    /// advanced replacement first, then keeps the user's newly enabled choice.
    private func nativePreferencesChanged() {
        guard !changingOwnership else { return }
        if pausedInputUID != nil, !Defaults[.pinnedInputDeviceUID].isEmpty {
            pausedInputUID = Defaults[.pinnedInputDeviceUID]
            UserDefaults.standard.set(pausedInputUID, forKey: "Anchor.utilityPausedInputUID")
            UtilityWorkspace.shared.releaseInputOwnership()
        }
        let resumed = Set(handover.paused.keys.filter { UserDefaults.standard.bool(forKey: $0) })
        guard !resumed.isEmpty else { return }
        for key in resumed { handover.paused[key] = true }
        for owner in owners where Self.controlKeys[owner]?.contains(where: { resumed.contains($0.name) }) == true {
            UtilityWorkspace.shared.setAvailable(owner, false)
        }
    }
}
