import AppKit
import ApplicationServices
import Combine
import Defaults
import KeyboardShortcuts

/// Opt-in replacements for the two macOS navigation shortcuts. No system
/// preferences are changed: disabling Anchor restores the normal shortcuts.
/// The tap lives on the main run loop, so macOS's event-tap watchdog can let
/// keys through if the app stops responding. There is no idle polling.
@MainActor
final class SystemNavigationShortcutManager: ObservableObject {
    static let shared = SystemNavigationShortcutManager()

    @Published private(set) var isAvailable = false
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var subscriptions = Set<AnyCancellable>()
    private var swallowedKeys = NavigationKeyPresses()
    private var launcherGeneration = UUID()
    private var drainTimer: Timer?

    private static let recordedNames: [KeyboardShortcuts.Name] = [.toggleLauncher, .appSwitcher, .appSwitcherReverse]
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        let keys: [Defaults.Key<Bool>] = [
            .launcherUsesCommandSpace, .appSwitcherUsesCommandTab, .enableLauncher, .enableAppSwitcher, .enableShortcuts
        ]
        for key in keys {
            Defaults.publisher(key, options: []).sink { [weak self] change in
                let enabled = change.newValue
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.preferenceChanged(key, enabled: enabled) }
                } else {
                    DispatchQueue.main.async { self?.preferenceChanged(key, enabled: enabled) }
                }
            }.store(in: &subscriptions)
        }
        // Retry after the user returns from granting Accessibility access.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.sync() }.store(in: &subscriptions)
        sync()
    }

    private func preferenceChanged(_ key: Defaults.Key<Bool>, enabled: Bool) {
        guard started else { return }
        if key == .launcherUsesCommandSpace || key == .enableLauncher || key == .enableShortcuts {
            launcherGeneration = UUID()
        }
        if !enabled {
            if key == .enableAppSwitcher || key == .enableShortcuts {
                AppSwitcherPanelManager.shared.dismiss(activating: false)
                AppSwitcherManager.shared.stopTracking()
            } else if key == .appSwitcherUsesCommandTab {
                AppSwitcherPanelManager.shared.cancelSystemInvocation()
            }
        }
        sync()
    }

    private var launcherEnabled: Bool {
        Defaults[.enableShortcuts] && Defaults[.enableLauncher] && Defaults[.launcherUsesCommandSpace]
    }
    private var switcherEnabled: Bool {
        Defaults[.enableShortcuts] && Defaults[.enableAppSwitcher] && Defaults[.appSwitcherUsesCommandTab]
    }

    private var switcherWanted: Bool {
        Defaults[.enableShortcuts] && Defaults[.enableAppSwitcher]
    }

    private func sync() {
        guard started else { return }
        recordedShortcutsChanged()
        if switcherWanted {
            AppSwitcherManager.shared.startTracking()
        }
        syncTap()
    }

    private func syncTap() {
        guard launcherEnabled || switcherEnabled else {
            if swallowedKeys.isEmpty { stopTap() }
            else { watchForLostReleases() }
            return
        }
        drainTimer?.invalidate()
        drainTimer = nil
        guard tap == nil else { return }
        guard AXIsProcessTrusted() else { isAvailable = false; return }
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue)
            | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<SystemNavigationShortcutManager>.fromOpaque(context).takeUnretainedValue()
            return MainActor.assumeIsolated { manager.handle(type, event: event) }
        }
        guard let created = CGEvent.tapCreate(tap: .cghidEventTap, place: .headInsertEventTap,
            options: .defaultTap, eventsOfInterest: mask, callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            isAvailable = false
            return
        }
        tap = created
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0)
        if let source { CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes) }
        CGEvent.tapEnable(tap: created, enable: true)
        isAvailable = true
    }

    func stop() {
        subscriptions.removeAll()
        started = false
        launcherGeneration = UUID()
        Self.recordedNames.forEach { KeyboardShortcuts.disable($0) }
        AppSwitcherPanelManager.shared.dismiss(activating: false)
        AppSwitcherManager.shared.stopTracking()
        stopTap()
    }

    private func watchForLostReleases() {
        guard drainTimer == nil else { return }
        // If secure input hides a key-up from the tap, release the drained
        // registration once the physical key reports that it is no longer down.
        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.swallowedKeys.discardReleased { CGEventSource.keyState(.hidSystemState, key: $0) }
                self.syncTap()
            }
        }
        drainTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopTap() {
        drainTimer?.invalidate()
        drainTimer = nil
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowedKeys = NavigationKeyPresses()
        isAvailable = false
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeys = NavigationKeyPresses()
            AppSwitcherPanelManager.shared.dismiss(activating: false)
            if launcherEnabled || switcherEnabled {
                if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            } else {
                stopTap()
            }
            return Unmanaged.passUnretained(event)
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            guard swallowedKeys.release(key) else { return Unmanaged.passUnretained(event) }
            syncTap()
            return nil
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        if swallowedKeys.contains(key) { return nil }
        // Any repeat whose original press went to macOS stays with macOS.
        guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
              let action = SystemNavigationShortcut.action(keyCode: key,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                launcherEnabled: launcherEnabled, switcherEnabled: switcherEnabled)
        else { return Unmanaged.passUnretained(event) }

        switch action {
        case .launcher:
            let generation = launcherGeneration
            // Keep panel creation out of the tap callback.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.started, self.launcherEnabled,
                      self.launcherGeneration == generation else { return }
                LauncherPanelManager.shared.toggle()
            }
        case .switcher(let reverse):
            AppSwitcherPanelManager.shared.invoke(reverse: reverse, holding: .command, systemInvocation: true)
            guard AppSwitcherManager.shared.isVisible else { return Unmanaged.passUnretained(event) }
        }
        swallowedKeys.capture(key)
        return nil
    }

    /// The system replacements, not the recorded aliases, own the standard chords.
    private func canUseRecorded(_ name: KeyboardShortcuts.Name) -> Bool {
        guard Defaults[.enableShortcuts],
              name == .toggleLauncher ? Defaults[.enableLauncher] : Defaults[.enableAppSwitcher],
              let shortcut = KeyboardShortcuts.getShortcut(for: name) else { return false }
        return SystemNavigationShortcut.action(
            keyCode: UInt16(clamping: shortcut.carbonKeyCode), modifiers: shortcut.modifiers,
            launcherEnabled: true, switcherEnabled: true
        ) == nil
    }

    func recordedShortcutsChanged() {
        guard started else { return }
        // Re-enable remaining owners after disabling any aliases that share a key.
        for name in Self.recordedNames where !canUseRecorded(name) { KeyboardShortcuts.disable(name) }
        for name in Self.recordedNames where canUseRecorded(name) { KeyboardShortcuts.enable(name) }
    }

    func invokeRecorded(_ name: KeyboardShortcuts.Name) {
        guard started, canUseRecorded(name) else { return }
        if name == .toggleLauncher {
            LauncherPanelManager.shared.toggle()
        } else {
            let hold = KeyboardShortcuts.getShortcut(for: name)?.modifiers.intersection([.command, .option, .control]) ?? []
            AppSwitcherPanelManager.shared.invoke(reverse: name == .appSwitcherReverse, holding: hold)
        }
    }
}
