import AnchorUtilities
import AppKit
import Combine
import Defaults
import SwiftUI

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
    private var islandSubscription: AnyCancellable?
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
        "clipboardHistory": [.enableClipboardManager],
        "clipboardAutoClearDelay": [.autoClearClipboardEnabled],
        "urlCleaner": [.autoCleanCopiedURLs],
        "mixer": [.enablePerAppAudio],
        "notch": [.enableSystemHUD, .openNotchOnHover, .extendHoverArea],
        "lockScreenIsland": [.enableLockScreenMediaWidget, .enableLockScreenLiveActivity],
        "lockSounds": [.enableLockSounds],
    ]

    private static let migratedControlKeys: [String: [Defaults.Key<Bool>]] = {
        var keys = UtilityIntegration.controlKeys
        keys.removeValue(forKey: "textSnippets")
        return keys
    }()

    private var activeControlKeys: [String: [Defaults.Key<Bool>]] {
        UserDefaults.standard.bool(forKey: "Anchor.legacySnippetsMigrated.v1")
            ? Self.migratedControlKeys : Self.controlKeys
    }

    private init() {
        let saved = UserDefaults.standard.dictionary(forKey: "Anchor.utilitySuspendedControls.v1") ?? [:]
        handover = UtilityOwnership(paused: saved.compactMapValues { ($0 as? NSNumber)?.boolValue })
    }

    func start(delegate: AppDelegate) {
        guard !started else { return }
        started = true
        let workspace = UtilityWorkspace.shared
        migrateLegacySnippetsIfNeeded(workspace)
        workspace.onControlOwnershipChange = { [weak self, weak delegate] owners in
            MainActor.assumeIsolated {
                self?.apply(owners)
                delegate?.setUtilityIslandActive(owners.contains("notch"))
            }
        }
        workspace.onShowAnchorMenuIcon = { Defaults[.menubarIcon] = true }
        workspace.onOpenControls = {
            SettingsWindowController.shared.showWindow(tab: .features)
            workspace.controlsVisible = true
        }
        workspace.onOpenAnchorSettings = { SettingsWindowController.shared.showWindow(tab: .general) }
        workspace.onOpenIslandSettings = {
            SettingsWindowController.shared.showWindow(tab: .general,
                highlightID: SettingsTab.general.highlightID(for: "Dynamic Island"))
        }
        islandSubscription = Defaults.publisher(.enableDynamicIsland, options: [])
            .sink { [weak delegate] _ in
                Task { @MainActor in delegate?.setUtilityIslandActive(false) }
            }
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

    private func migrateLegacySnippetsIfNeeded(_ workspace: UtilityWorkspace) {
        let marker = "Anchor.legacySnippetsMigrated.v1"
        guard !UserDefaults.standard.bool(forKey: marker) else { return }
        let old = Defaults[.textSnippets]
        if let raw = UserDefaults.standard.object(forKey: Defaults.Keys.textSnippets.name) {
            // If Defaults could not decode the saved value, do not interpret it
            // as an empty list and retire its editor.
            guard let stored = raw as? [Any], stored.count == old.count else { return }
        }
        let entries = old.map { LegacyAnchorSnippet(id: $0.id, trigger: $0.trigger,
                                                      replacement: $0.expansion,
                                                      immediate: $0.expandImmediately) }
        let previouslyEnabled = Defaults[.enableTextSnippets]
            || handover.paused[Defaults.Keys.enableTextSnippets.name] == true
        guard workspace.migrateLegacySnippets(entries, wasEnabled: previouslyEnabled) else { return }
        UserDefaults.standard.set(previouslyEnabled, forKey: "Anchor.legacySnippetsEnabledBackup.v1")
        handover.paused.removeValue(forKey: Defaults.Keys.enableTextSnippets.name)
        UserDefaults.standard.set(handover.paused, forKey: savedChoicesKey)
        Defaults[.enableTextSnippets] = false
        UserDefaults.standard.set(true, forKey: marker)
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
        let controls = activeControlKeys.mapValues { $0.map(\.name) }
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
        owners = newOwners
        ClipboardToolsManager.shared.syncPasteboardWatch()
        ClipboardToolsManager.shared.syncSystemTriggers()
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
        for owner in owners where activeControlKeys[owner]?.contains(where: { resumed.contains($0.name) }) == true {
            switch owner {
            case "clipboardAutoClearDelay":
                UtilityWorkspace.shared.releaseClipboardAutoClearOwnership(owner)
            default:
                UtilityWorkspace.shared.setAvailable(owner, false)
            }
        }
    }
}
