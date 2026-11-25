import Combine
import Foundation

final class SystemActivityGate {
    static let shared = SystemActivityGate()
    @Published var shouldSuspendBackgroundWork = false
}

final class BluetoothFixture {
    var deviceObservers: [NSObjectProtocol] = []
    var activitySubscription: AnyCancellable?
    var showsConnectionAlerts = false
    var tracksListeningMode = false
    var showsLockScreenBattery = false
    var stopped = false
    var needsDeviceSnapshot = true
    var cancellables = Set<AnyCancellable>()
    var connectionAlertGeneration = UUID()
    var hudBatteryWaitTasks: [UUID: Task<Void, Never>] = [:]
    var pollingTimer: Timer?
    var connectedDevices: [String] = []
    var lastConnectedDevice: String?
    var isBluetoothAudioConnected = false
    var silentSnapshots = 0
    var deviceChecks = 0
    var connectionEvents = 0
    var disconnectionEvents = 0
    var stopsBatteryRefresh = 0
    var isWatchingListeningMode = false
    var isStreamingListeningMode = false

    func checkInitialDevices() {
        silentSnapshots += 1
        connectedDevices = ["headphones"]
        lastConnectedDevice = connectedDevices.last
        isBluetoothAudioConnected = true
    }

    func checkForDeviceChanges() { deviceChecks += 1 }
    func checkForNewlyConnectedDevices() { connectionEvents += 1 }
    func updateConnectedDevices() { disconnectionEvents += 1 }
    func stopBatteryRefresh() { stopsBatteryRefresh += 1 }
    func refreshConnectedDeviceBatteries() {}
    func dismissBluetoothHUD(listeningMode: Bool) {}
    func setupAirPodsListeningModeObservers() { isWatchingListeningMode = true }
    func startListeningModeLogObserver() { isStreamingListeningMode = true }
    func stopListeningModeObservation() {
        isWatchingListeningMode = false
        isStreamingListeningMode = false
    }
}

@main
struct BluetoothAudioDemandTests {
    @MainActor
    static func main() {
        let gate = SystemActivityGate.shared
        let bluetooth = BluetoothFixture()
        bluetooth.setConnectionAlertsEnabled(false)
        bluetooth.setListeningModeEnabled(false)
        precondition(bluetooth.deviceObservers.isEmpty && bluetooth.activitySubscription == nil)
        precondition(bluetooth.pollingTimer == nil && bluetooth.silentSnapshots == 0)

        gate.shouldSuspendBackgroundWork = true
        bluetooth.setConnectionAlertsEnabled(true)
        precondition(bluetooth.deviceObservers.count == 2)
        precondition(bluetooth.pollingTimer == nil && bluetooth.silentSnapshots == 0)
        gate.shouldSuspendBackgroundWork = false
        precondition(bluetooth.silentSnapshots == 1 && bluetooth.deviceChecks == 0)
        precondition(bluetooth.pollingTimer?.timeInterval == 3)

        bluetooth.isBluetoothAudioConnected = false
        bluetooth.adjustPollingCadence()
        precondition(bluetooth.pollingTimer?.timeInterval == 15)
        gate.shouldSuspendBackgroundWork = true
        precondition(bluetooth.pollingTimer == nil)
        gate.shouldSuspendBackgroundWork = false
        precondition(bluetooth.deviceChecks == 1 && bluetooth.silentSnapshots == 1)

        bluetooth.setListeningModeEnabled(true)
        precondition(bluetooth.isWatchingListeningMode && bluetooth.isStreamingListeningMode)
        precondition(bluetooth.deviceObservers.count == 2)
        let batteryWait = Task<Void, Never> {
            try? await Task.sleep(for: .seconds(5))
        }
        bluetooth.hudBatteryWaitTasks[UUID()] = batteryWait
        let generation = bluetooth.connectionAlertGeneration
        let timer = bluetooth.pollingTimer
        bluetooth.setConnectionAlertsEnabled(false)
        precondition(bluetooth.connectionAlertGeneration != generation && batteryWait.isCancelled)
        precondition(bluetooth.hudBatteryWaitTasks.isEmpty && !bluetooth.needsBatteryRefresh)
        precondition(bluetooth.stopsBatteryRefresh > 0 && bluetooth.pollingTimer === timer)

        bluetooth.setLockScreenBatteryVisible(true)
        bluetooth.setListeningModeEnabled(false)
        precondition(bluetooth.needsBatteryRefresh && bluetooth.deviceObservers.count == 2)
        precondition(!bluetooth.isWatchingListeningMode && !bluetooth.isStreamingListeningMode)
        bluetooth.setLockScreenBatteryVisible(false)
        precondition(bluetooth.deviceObservers.isEmpty && bluetooth.activitySubscription == nil)
        precondition(timer?.isValid == false && bluetooth.pollingTimer == nil)
        precondition(bluetooth.connectedDevices.isEmpty && bluetooth.lastConnectedDevice == nil)

        gate.shouldSuspendBackgroundWork = true
        bluetooth.setLockScreenBatteryVisible(true)
        precondition(bluetooth.silentSnapshots == 2 && bluetooth.isBluetoothAudioConnected)
        precondition(bluetooth.pollingTimer == nil && bluetooth.deviceObservers.count == 2)
        bluetooth.setLockScreenBatteryVisible(false)
        gate.shouldSuspendBackgroundWork = false
        precondition(bluetooth.pollingTimer == nil && bluetooth.deviceChecks == 1)

        bluetooth.setConnectionAlertsEnabled(true)
        bluetooth.setListeningModeEnabled(true)
        bluetooth.setLockScreenBatteryVisible(true)
        bluetooth.stopMonitoring()
        bluetooth.setListeningModeEnabled(true)
        precondition(!bluetooth.isWatchingListeningMode && !bluetooth.isStreamingListeningMode)
        precondition(bluetooth.deviceObservers.isEmpty && bluetooth.pollingTimer == nil)

        let suppression = HUDSuppressionCoordinator.shared
        suppression.suppressVolumeHUD(for: 1.5, source: .bluetoothConnection)
        suppression.suppressVolumeHUD(for: 1.5, source: .airPodsListeningMode)
        suppression.releaseVolumeHUDSuppression(source: .bluetoothConnection)
        precondition(suppression.shouldSuppressVolumeHUD)
        suppression.releaseVolumeHUDSuppression(source: .airPodsListeningMode)
        precondition(!suppression.shouldSuppressVolumeHUD)
        print("Bluetooth audio demand lifecycle checks passed")
    }
}
