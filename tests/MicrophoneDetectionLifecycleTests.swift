import Combine
import CoreAudio
import Foundation

@main
enum MicrophoneDetectionLifecycleTests {
    @MainActor
    static func main() {
        let audio = AudioFixture()
        let monitor = MicrophoneMonitor(backend: audio.backend, isEnabled: { audio.enabled })
        let system = AudioObjectID(kAudioObjectSystemObject)

        monitor.startMonitoring()
        precondition(audio.observations.isEmpty && audio.reads.isEmpty && audio.routeReads == 0)

        audio.enabled = true
        monitor.startMonitoring()
        monitor.startMonitoring()
        precondition(audio.observations.count == 1 && !monitor.isMicActive)
        let firstRoute = audio.callback(for: system, property: kAudioHardwarePropertyDefaultInputDevice)

        audio.input = 10
        audio.running = [10]
        firstRoute()
        precondition(monitor.isMicActive && audio.observations.count == 2)
        let firstDevice = audio.callback(for: 10, property: kAudioDevicePropertyDeviceIsRunningSomewhere)

        // The device notification may run before the queued route notification.
        audio.input = 11
        firstDevice()
        precondition(!monitor.isMicActive && audio.observations.count == 2)
        let newDevice = audio.callback(for: 11, property: kAudioDevicePropertyDeviceIsRunningSomewhere)
        audio.running = [11]
        let readsBeforeOldDevice = audio.reads.count
        firstDevice()
        precondition(audio.reads.count == readsBeforeOldDevice && !monitor.isMicActive)
        newDevice()
        precondition(monitor.isMicActive)

        // The preference read revokes already-queued work even before teardown.
        audio.enabled = false
        let readsBeforeOff = audio.reads.count
        let routeReadsBeforeOff = audio.routeReads
        firstRoute()
        newDevice()
        precondition(audio.reads.count == readsBeforeOff && audio.routeReads == routeReadsBeforeOff)
        monitor.stopMonitoring()
        precondition(!monitor.isMicActive && audio.observations.isEmpty)

        audio.enabled = true
        monitor.startMonitoring()
        precondition(monitor.isMicActive && audio.observations.count == 2)
        let readsAfterOn = audio.reads.count
        let routeReadsAfterOn = audio.routeReads
        firstRoute()
        newDevice()
        precondition(audio.reads.count == readsAfterOn && audio.routeReads == routeReadsAfterOn)

        audio.input = kAudioObjectUnknown
        audio.callback(for: system, property: kAudioHardwarePropertyDefaultInputDevice)()
        precondition(!monitor.isMicActive && audio.observations.count == 1)
        monitor.stopMonitoring()
        precondition(audio.observations.isEmpty)
        print("Microphone demand, absent device, input handoff, and stale callback checks passed")
    }
}

@MainActor
private final class AudioFixture {
    struct Observation {
        let object: AudioObjectID
        let property: AudioObjectPropertySelector
        let callback: @MainActor () -> Void
    }

    var enabled = false
    var input = kAudioObjectUnknown
    var running: Set<AudioDeviceID> = []
    var observations: [UUID: Observation] = [:]
    var reads: [AudioDeviceID] = []
    var routeReads = 0

    var backend: MicrophoneMonitor.Backend {
        .init(
            defaultInput: {
                self.routeReads += 1
                return self.input
            },
            isRunning: { device in
                self.reads.append(device)
                return self.running.contains(device)
            },
            observe: { object, property, callback in
                let id = UUID()
                self.observations[id] = Observation(object: object, property: property, callback: callback)
                return AnyCancellable { self.observations.removeValue(forKey: id) }
            }
        )
    }

    func callback(for object: AudioObjectID, property: AudioObjectPropertySelector) -> @MainActor () -> Void {
        let listeners = observations.values.filter { $0.object == object && $0.property == property }
        precondition(listeners.count == 1)
        return listeners[0].callback
    }
}
