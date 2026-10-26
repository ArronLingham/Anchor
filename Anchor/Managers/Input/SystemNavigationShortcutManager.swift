import AppKit
import ApplicationServices
import Combine
import Defaults

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
    private var swallowedKeys = Set<UInt16>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        for publisher in [Defaults.publisher(.launcherUsesCommandSpace).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.appSwitcherUsesCommandTab).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.enableLauncher).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.enableAppSwitcher).map { _ in () }.eraseToAnyPublisher(),
                          Defaults.publisher(.enableShortcuts).map { _ in () }.eraseToAnyPublisher()] {
            publisher.sink { [weak self] in
                Task { @MainActor in self?.sync() }
            }.store(in: &subscriptions)
        }
        // Retry after the user returns from granting Accessibility access.
        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in self?.sync() }.store(in: &subscriptions)
        sync()
    }

    private var launcherEnabled: Bool {
        Defaults[.enableShortcuts] && Defaults[.enableLauncher] && Defaults[.launcherUsesCommandSpace]
    }
    private var switcherEnabled: Bool {
        Defaults[.enableShortcuts] && Defaults[.enableAppSwitcher] && Defaults[.appSwitcherUsesCommandTab]
    }

    private func sync() {
        guard launcherEnabled || switcherEnabled else {
            stopTap()
            return
        }
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
        stopTap()
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
        swallowedKeys.removeAll()
        isAvailable = false
    }

    private func handle(_ type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            swallowedKeys.removeAll()
            AppSwitcherPanelManager.shared.dismiss(activating: false)
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let key = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedKeys.remove(key) != nil ? nil : Unmanaged.passUnretained(event)
        }
        guard type == .keyDown,
              let action = SystemNavigationShortcut.action(keyCode: key,
                modifiers: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)),
                launcherEnabled: launcherEnabled, switcherEnabled: switcherEnabled)
        else { return Unmanaged.passUnretained(event) }

        switch action {
        case .launcher:
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 {
                // Building the view can do disk work. Keep it out of the tap callback.
                DispatchQueue.main.async { LauncherPanelManager.shared.toggle() }
            }
        case .switcher(let reverse):
            AppSwitcherPanelManager.shared.invoke(reverse: reverse, holding: .command)
            guard AppSwitcherManager.shared.isVisible else { return Unmanaged.passUnretained(event) }
        }
        swallowedKeys.insert(key)
        return nil
    }
}
