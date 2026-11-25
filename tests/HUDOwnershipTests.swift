import AppKit
import Combine

@main
enum HUDOwnershipTests {
    @MainActor
    static func main() async {
        let coordinator = AnchorViewCoordinator()
        let manager = SystemHUDManager.shared
        manager.setup(coordinator: coordinator)
        precondition(SystemChangesObserver.created == 0 && SystemOSDManager.calls == [false])

        Defaults[.enableThirdPartyDDCIntegration] = true
        Defaults[.thirdPartyDDCProvider] = .lunar
        Defaults[.treatFunctionKeysAsBrightness] = true
        LunarManager.shared.isRunning = true
        await settle()
        precondition(SystemChangesObserver.created == 0 && SystemOSDManager.calls == [false])

        Defaults[.enableCircularHUD] = true
        await settle()
        precondition(SystemChangesObserver.applied == .volume)
        precondition(SystemOSDManager.calls == [false])
        manager.present(type: .brightness, value: 0.5)
        precondition(CircularHUDWindowManager.shared.presented == [.brightness])
        Defaults[.enableBrightnessHUD] = false
        manager.present(type: .brightness, value: 0.75)
        precondition(CircularHUDWindowManager.shared.presented == [.brightness])
        await settle()
        precondition(CircularHUDWindowManager.shared.dismissed == [.brightness])

        LunarManager.shared.isRunning = false
        Defaults[.enableBrightnessHUD] = true
        await settle()
        precondition(SystemChangesObserver.applied == .all && SystemOSDManager.calls == [false])
        SystemChangesObserver.tapAvailable = true
        NotificationCenter.default.post(name: .mediaKeyInterceptionAvailabilityDidChange, object: nil)
        await settle()
        precondition(SystemOSDManager.calls == [false, true])

        UtilityWorkspace.shared.controlOwners = ["volumeKeys"]
        NotificationCenter.default.post(name: .utilityControlOwnershipChanged, object: nil)
        await settle()
        precondition(SystemChangesObserver.applied == [.brightness, .backlight])
        precondition(SystemOSDManager.calls == [false, true, false])

        Defaults[.enableCircularHUD] = false
        Defaults[.enableExternalVolumeControlListener] = true
        await settle()
        precondition(SystemChangesObserver.applied.isEmpty && SystemChangesObserver.stopped == 1)
        precondition(SystemOSDManager.calls == [false, true, false])
        let retiredDisplays: HUDControls = CircularHUDWindowManager.shared.dismissedAfterOff
        precondition(retiredDisplays == .all)
        let tap = MediaKeyInterceptor.shared
        let mediaCommands = MediaCommandFixture()
        tap.delegate = mediaCommands
        tap.dispatchMuteCommand()
        tap.invalidatePendingCommands()
        tap.dispatchMuteCommand()
        await settle()
        precondition(mediaCommands.muteCommands == 1)
        print("HUD ownership, partial replacement, last-owner release, and stale media keys checks passed")
    }

    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(25))
    }
}

enum Defaults {
    struct Key<Value> {
        let name: String
        let initial: Value
    }
    struct Change<Value> { let newValue: Value }
    enum Provider { case betterDisplay, lunar }
    private static var values: [String: Any] = [:]
    private static let changes = PassthroughSubject<(String, Any), Never>()
    static subscript<Value>(_ key: Key<Value>) -> Value {
        get { values[key.name] as? Value ?? key.initial }
        set { values[key.name] = newValue; changes.send((key.name, newValue)) }
    }
    static func publisher<Value>(_ key: Key<Value>, options: [String]) -> AnyPublisher<Change<Value>, Never> {
        changes.filter { $0.0 == key.name }
            .compactMap { ($0.1 as? Value).map { Change(newValue: $0) } }.eraseToAnyPublisher()
    }
}

extension Defaults.Key where Value == Bool {
    static var enableSystemHUD: Self { Self(name: "notch", initial: false) }
    static var enableCustomOSD: Self { Self(name: "floating", initial: false) }
    static var enableVerticalHUD: Self { Self(name: "vertical", initial: false) }
    static var enableCircularHUD: Self { Self(name: "circle", initial: false) }
    static var enableVolumeHUD: Self { Self(name: "volume", initial: true) }
    static var enableBrightnessHUD: Self { Self(name: "brightness", initial: true) }
    static var enableKeyboardBacklightHUD: Self { Self(name: "backlight", initial: true) }
    static var enableOSDVolume: Self { Self(name: "osdVolume", initial: true) }
    static var enableOSDBrightness: Self { Self(name: "osdBrightness", initial: true) }
    static var enableOSDKeyboardBacklight: Self { Self(name: "osdBacklight", initial: true) }
    static var treatFunctionKeysAsVolume: Self { Self(name: "functionVolume", initial: false) }
    static var treatFunctionKeysAsBrightness: Self { Self(name: "functionBrightness", initial: false) }
    static var enableThirdPartyDDCIntegration: Self { Self(name: "ddc", initial: false) }
    static var enableExternalVolumeControlListener: Self { Self(name: "externalVolume", initial: false) }
}
extension Defaults.Key where Value == Defaults.Provider {
    static var thirdPartyDDCProvider: Self { .init(name: "provider", initial: .betterDisplay) }
}

final class BetterDisplayManager {
    static let shared = BetterDisplayManager()
    @Published var isRunning = false
    static func checkRunning() -> Bool { shared.isRunning }
}

final class LunarManager {
    static let shared = LunarManager()
    @Published var isRunning = false
    static func checkRunning() -> Bool { shared.isRunning }
}

final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    var controlOwners = Set<String>()
}

extension Notification.Name {
    static let utilityControlOwnershipChanged = Self("test-owner")
}

final class SystemChangesObserver {
    static var created = 0
    static var stopped = 0
    static var applied: HUDControls = []
    static var tapAvailable = false
    var isInterceptionAvailable: Bool { Self.tapAvailable }
    init() { Self.created += 1 }
    func invalidatePendingDeliveries() {}
    func update(controls: HUDControls) { Self.applied = controls }
    func stopObserving() { Self.applied = []; Self.stopped += 1 }
}

enum SystemOSDManager {
    static var calls: [Bool] = []
    static func disableSystemHUD() { calls.append(true) }
    static func enableSystemHUD() { calls.append(false) }
    static func suppressNativeOSDNow() {}
}

enum SneakContentType { case volume, brightness, contrast, backlight, reminder }
final class AnchorViewCoordinator {
    var sneakPeek = (show: false, type: SneakContentType.reminder)
    func toggleSneakPeek(status: Bool, type: SneakContentType, value: CGFloat = 0, icon: String = "",
                         onScreen screen: NSScreen? = nil, shouldDeliver: (() -> Bool)? = nil) {}
}

final class CircularHUDWindowManager {
    static let shared = CircularHUDWindowManager()
    var presented: [SneakContentType] = []
    var dismissed: HUDControls = []
    var dismissedAfterOff: HUDControls = []
    func show(type: SneakContentType, value: CGFloat, icon: String, onScreen screen: NSScreen?) { presented.append(type) }
    func dismiss(_ controls: HUDControls) {
        if Defaults[.enableCircularHUD] { dismissed.formUnion(controls) }
        else { dismissedAfterOff.formUnion(controls) }
    }
}

typealias VerticalHUDWindowManager = CircularHUDWindowManager
typealias CustomOSDWindowManager = CircularHUDWindowManager
enum HUDSuppressionCoordinator {
    static let shared = (shouldSuppressVolumeHUD: false, unused: false)
}

enum AppRuntimeEnvironment {
    static let isUITesting = true
}

final class MediaCommandFixture: MediaKeyInterceptorDelegate {
    var muteCommands = 0
    func mediaKeyInterceptorDidToggleMute(_ interceptor: MediaKeyInterceptor) { muteCommands += 1 }
    func mediaKeyInterceptor(_ interceptor: MediaKeyInterceptor, didReceiveVolumeCommand direction: MediaKeyDirection,
                             step: MediaKeyStep, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {}
    func mediaKeyInterceptor(_ interceptor: MediaKeyInterceptor, didReceiveBrightnessCommand direction: MediaKeyDirection,
                             step: MediaKeyStep, isRepeat: Bool, modifiers: NSEvent.ModifierFlags) {}
}
