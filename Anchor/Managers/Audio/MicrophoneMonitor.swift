/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import Combine
import CoreAudio
import Foundation

/// Observes whether the default input device is in use. This does not open an audio stream.
@MainActor
final class MicrophoneMonitor: ObservableObject {
    struct Backend {
        var defaultInput: () -> AudioDeviceID
        var isRunning: (AudioDeviceID) -> Bool
        var observe: (AudioObjectID, AudioObjectPropertySelector, @escaping @MainActor () -> Void) -> AnyCancellable?
    }

    @Published private(set) var isMicActive = false

    private let backend: Backend
    private let isEnabled: () -> Bool
    private var session: UUID?
    private var inputObservation: AnyCancellable?
    private var deviceObservation: AnyCancellable?
    private var observedDevice: AudioDeviceID = kAudioObjectUnknown
    private var deviceSession = UUID()

    init(backend: Backend? = nil, isEnabled: @escaping () -> Bool) {
        self.backend = backend ?? Self.coreAudio
        self.isEnabled = isEnabled
    }

    func startMonitoring() {
        guard session == nil, isEnabled() else { return }
        let session = UUID()
        self.session = session
        // Keep watching the route even when there is no default input yet.
        inputObservation = backend.observe(
            AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice
        ) { [weak self] in
            guard let self, self.session == session, self.isEnabled() else { return }
            self.refreshInputDevice()
        }
        refreshInputDevice()
    }

    func stopMonitoring() {
        session = nil
        deviceSession = UUID()
        inputObservation = nil
        deviceObservation = nil
        observedDevice = kAudioObjectUnknown
        setActive(false)
    }

    private func refreshInputDevice() {
        let device = backend.defaultInput()
        if observedDevice != device || deviceObservation == nil {
            let deviceSession = UUID()
            self.deviceSession = deviceSession
            deviceObservation = nil
            observedDevice = device
            if device != kAudioObjectUnknown {
                deviceObservation = backend.observe(device, kAudioDevicePropertyDeviceIsRunningSomewhere) { [weak self] in
                    guard let self, self.deviceSession == deviceSession, self.isEnabled() else { return }
                    // A route event and a device event can arrive in either order.
                    if self.backend.defaultInput() == device {
                        self.setActive(self.backend.isRunning(device))
                    } else {
                        self.refreshInputDevice()
                    }
                }
            }
        }
        setActive(device != kAudioObjectUnknown && backend.isRunning(device))
    }

    private func setActive(_ active: Bool) {
        if isMicActive != active { isMicActive = active }
    }

    private static var coreAudio: Backend {
        Backend(
            defaultInput: {
                read(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultInputDevice)
                    ?? kAudioObjectUnknown
            },
            isRunning: { device in
                (read(device, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0
            },
            observe: { object, selector, onChange in
                var address = property(selector)
                let queue = DispatchQueue.main
                let listener: AudioObjectPropertyListenerBlock = { _, _ in
                    MainActor.assumeIsolated { onChange() }
                }
                guard AudioObjectHasProperty(object, &address) else { return nil }
                let added = AudioObjectAddPropertyListenerBlock(object, &address, queue, listener)
                guard added == noErr else {
                    NSLog("Microphone detection: could not observe audio object \(object) (\(added))")
                    return nil
                }
                return AnyCancellable {
                    var address = property(selector)
                    let removed = AudioObjectRemovePropertyListenerBlock(object, &address, queue, listener)
                    // The HAL drops a device's properties when the device disappears.
                    if removed != noErr && removed != kAudioHardwareBadObjectError
                        && removed != kAudioHardwareUnknownPropertyError {
                        NSLog("Microphone detection: could not remove listener for audio object \(object) (\(removed))")
                    }
                }
            }
        )
    }

    nonisolated private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    nonisolated private static func read(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout.size(ofValue: value))
        let status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value)
        return status == noErr ? value : nil
    }
}
