import Combine
import Foundation

enum Defaults {
    enum Key { case enableCapsLockIndicator, enableBatteryHistory }
    struct Change { let newValue: Bool }
    private static var values: [Key: Bool] = [:]
    private static let changes = PassthroughSubject<(Key, Bool), Never>()
    static subscript(key: Key) -> Bool {
        get { values[key] ?? false }
        set { values[key] = newValue; changes.send((key, newValue)) }
    }
    static func publisher(_ key: Key, options: [Int]) -> AnyPublisher<Change, Never> {
        changes.filter { $0.0 == key }.map { Change(newValue: $0.1) }.eraseToAnyPublisher()
    }
}

struct FixtureEvent {
    enum EventType { case flagsChanged }
    enum Modifier { case capsLock }
    let modifierFlags: Set<Modifier>
    static var modifierFlags: Set<Modifier> = []
    static var globals: [(FixtureEvent) -> Void] = []
    static var removed = 0
    static func addLocalMonitorForEvents(matching: EventType, handler: (FixtureEvent) -> FixtureEvent?) -> Any? { 1 }
    static func addGlobalMonitorForEvents(matching: EventType, handler: @escaping (FixtureEvent) -> Void) -> Any? {
        globals.append(handler)
        return globals.count + 1
    }
    static func removeMonitor(_ monitor: Any) { removed += 1 }
}

@MainActor
final class AnchorViewCoordinator {
    enum Kind { case capsLock, volume }
    struct Peek { var show = false; var type = Kind.volume }
    static let shared = AnchorViewCoordinator()
    var sneakPeek = Peek()
    func toggleSneakPeek(status: Bool, type: Kind, duration: Double, value: Double, icon: String) {
        sneakPeek = Peek(show: status, type: type)
    }
}

@MainActor
final class BatteryActivityManager {
    enum BatteryEvent { case batteryLevelChanged(Float), isChargingChanged(Bool), powerSourceChanged(Bool), other }
    static let shared = BatteryActivityManager()
    var observations: [(BatteryEvent) -> Void] = []
    var removed: [Int] = []
    func addObserver(_ body: @escaping (BatteryEvent) -> Void) -> Int {
        observations.append(body)
        return observations.count
    }
    func removeObserver(byId id: Int) { removed.append(id) }
    func initializeBatteryInfo() -> (currentCapacity: Float, isCharging: Bool) { (70, false) }
}

@MainActor
final class BatteryFixture {
    var observerID: Int?
    var observerGeneration = UUID()
    var saveWorkItem: DispatchWorkItem?
    var samples: [(level: Float, charging: Bool)] = []
    var saved = 0
    func save() { saved += 1 }
    func record(level: Float, charging: Bool) { samples.append((level, charging)) }
}

@MainActor
final class FullscreenFixture {
    var generation = UUID()
    var wantsMonitoring = true
    var scan: DispatchWorkItem?
    var observers: [(NotificationCenter, NSObjectProtocol)] = []
    var fullscreenStatus = ["display": true]
    var queued: [DispatchWorkItem] = []
    var scans = 0
    func enqueue(_ work: DispatchWorkItem) { queued.append(work) }
    func updateFullScreenStatus() { scans += 1 }
}

@main
enum HostObservationDisableLifecycleTests {
    @MainActor
    static func main() async {
        let caps = CapsLockManager.shared
        let coordinator = AnchorViewCoordinator.shared
        precondition(FixtureEvent.globals.isEmpty)
        Defaults[.enableCapsLockIndicator] = true
        await waitUntil { FixtureEvent.globals.count == 1 }
        FixtureEvent.globals[0](FixtureEvent(modifierFlags: [.capsLock]))
        await waitUntil { caps.isCapsLockActive }
        precondition(coordinator.sneakPeek.show && coordinator.sneakPeek.type == .capsLock)
        Defaults[.enableCapsLockIndicator] = false
        await waitUntil { FixtureEvent.removed == 2 }
        precondition(!caps.isCapsLockActive && !coordinator.sneakPeek.show)
        coordinator.sneakPeek = .init(show: true, type: .volume)
        Defaults[.enableCapsLockIndicator] = true
        await waitUntil { FixtureEvent.globals.count == 2 }
        FixtureEvent.globals[0](FixtureEvent(modifierFlags: [.capsLock]))
        await Task.yield()
        precondition(!caps.isCapsLockActive && coordinator.sneakPeek.show && coordinator.sneakPeek.type == .volume)

        let battery = BatteryFixture()
        Defaults[.enableBatteryHistory] = true
        battery.start()
        let oldBattery = battery.observerGeneration
        battery.saveWorkItem = DispatchWorkItem {}
        Defaults[.enableBatteryHistory] = false
        battery.handle(.batteryLevelChanged(80), generation: oldBattery)
        battery.stop()
        precondition(battery.samples.map(\.level) == [70] && battery.saved == 1)
        Defaults[.enableBatteryHistory] = true
        battery.start()
        battery.handle(.batteryLevelChanged(80), generation: oldBattery)
        battery.handle(.batteryLevelChanged(85), generation: battery.observerGeneration)
        precondition(battery.samples.map(\.level) == [70, 70, 85])

        let fullscreen = FullscreenFixture()
        let oldFullscreen = fullscreen.generation
        fullscreen.scheduleScan(generation: oldFullscreen)
        fullscreen.scheduleScan(generation: oldFullscreen)
        for work in fullscreen.queued { work.perform() }
        precondition(fullscreen.scans == 1)
        fullscreen.scheduleScan(generation: oldFullscreen)
        fullscreen.stopMonitoring()
        fullscreen.queued.last?.perform()
        fullscreen.scheduleScan(generation: oldFullscreen)
        precondition(fullscreen.scans == 1 && fullscreen.fullscreenStatus.isEmpty)
        fullscreen.scheduleScan(generation: fullscreen.generation)
        fullscreen.queued.last?.perform()
        precondition(fullscreen.scans == 2)
        print("Caps Lock monitoring, battery sample and fullscreen scan disablement checks passed")
    }

    @MainActor
    private static func waitUntil(_ ready: () -> Bool) async {
        for _ in 0..<400 {
            if ready() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Observation fixture did not reach the expected state")
    }
}
