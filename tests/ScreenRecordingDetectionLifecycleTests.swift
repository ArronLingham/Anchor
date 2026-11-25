import AppKit
import Foundation

enum Defaults {
    enum Key {
        case enableScreenRecordingDetection
        case waitInterval
    }

    static subscript(_ key: Key) -> Bool { true }
    static subscript(_ key: Key) -> Double { 0.02 }
}

enum AppRuntimeEnvironment {
    static let isUITesting = false
}

@MainActor
final class AnchorViewCoordinator {
    static let shared = AnchorViewCoordinator()
    struct Expansion {
        enum Kind { case battery, recording }
        var show = false
        var type = Kind.battery
    }
    var expandingView = Expansion()
}

@main
enum ScreenRecordingDetectionLifecycleTests {
    @MainActor
    static func main() async {
        let system = RegistrationFixture()
        let manager = ScreenRecordingManager(
            notifications: .init(add: system.add, remove: system.remove),
            isEnabled: { system.enabled },
            isBeingRecorded: {
                system.reads += 1
                return system.recording
            }
        )
        let coordinator = AnchorViewCoordinator.shared

        manager.startMonitoring()
        precondition(!manager.isMonitoring && system.registrations.isEmpty && system.reads == 0)
        system.enabled = true
        system.recording = true
        manager.startMonitoring()
        manager.startMonitoring()
        precondition(manager.isMonitoring && manager.isRecording && system.reads == 1)
        precondition(system.registrations.count == 2 && coordinator.expandingView.type == .recording)
        let firstGeneration = system.registrations[1502]!

        system.enabled = false
        manager.handleCaptureEvent(generation: firstGeneration)
        precondition(system.reads == 1)
        manager.stopMonitoring()
        precondition(system.registrations.isEmpty && !manager.isRecording && manager.isRecorderIdle)
        precondition(!coordinator.expandingView.show && manager.recordingDuration == 0)

        system.enabled = true
        system.recording = false
        manager.startMonitoring()
        let secondGeneration = system.registrations[1502]!
        precondition(firstGeneration != secondGeneration)
        system.recording = true
        manager.handleCaptureEvent(generation: firstGeneration)
        precondition(!manager.isRecording && system.reads == 2)
        manager.handleCaptureEvent(generation: secondGeneration)
        precondition(manager.isRecording && system.reads == 3)

        coordinator.expandingView = .init(show: true, type: .battery)
        system.failedRemoval = 1502
        manager.stopMonitoring()
        precondition(coordinator.expandingView.show && coordinator.expandingView.type == .battery)
        precondition(system.registrations == [1502: secondGeneration])
        system.failedRemoval = nil
        manager.startMonitoring()
        precondition(system.registrations.count == 2 && !system.registrations.values.contains(secondGeneration))

        system.recording = false
        manager.handleCaptureEvent(generation: system.registrations[1502]!)
        precondition(!manager.isRecording && !manager.isRecorderIdle)
        manager.stopMonitoring()
        try? await Task.sleep(for: .milliseconds(60))
        precondition(manager.isRecorderIdle && manager.recordingDuration == 0)
        precondition(system.registrations.isEmpty)
        print("Screen recording registration, stale callback, retry, and owned expansion checks passed")
    }
}

@MainActor
private final class RegistrationFixture {
    var enabled = false
    var recording = false
    var reads = 0
    var failedRemoval: Int32?
    var registrations: [Int32: UInt] = [:]

    func add(_ event: Int32, generation: UInt) -> Int32 {
        precondition(registrations[event] == nil)
        registrations[event] = generation
        return 0
    }

    func remove(_ event: Int32, generation: UInt) -> Int32 {
        precondition(registrations[event] == generation)
        guard event != failedRemoval else { return 1 }
        registrations.removeValue(forKey: event)
        return 0
    }
}
