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

import AppKit
import Combine
import CoreAudio
import Defaults
import Foundation

// MARK: - Pure decisions

/// Picks the next device when cycling with a shortcut.
///
/// Pure, so the wrap-around and the awkward cases — the current device having
/// been unplugged mid-cycle, a single device, an empty list — can be tested
/// without unplugging anything.
enum AudioDeviceCycle {

    /// The device after `current` in `devices`, wrapping at the end.
    ///
    /// Returns nil only when there is nothing to switch to. When `current` is
    /// not in the list at all — which happens when the active device was just
    /// unplugged and the list has already refreshed without it — the **first**
    /// device is returned rather than nil: the user pressed the key wanting a
    /// different output, and landing somewhere valid beats doing nothing.
    static func next<ID: Equatable>(after current: ID, in devices: [ID]) -> ID? {
        guard !devices.isEmpty else { return nil }
        // A single device is not a cycle. Returning it would fire a "switched
        // to X" HUD while nothing changed, which reads as a bug.
        guard devices.count > 1 else { return nil }
        guard let index = devices.firstIndex(of: current) else { return devices[0] }
        return devices[(index + 1) % devices.count]
    }

    /// The device before `current`, for a reverse binding.
    static func previous<ID: Equatable>(after current: ID, in devices: [ID]) -> ID? {
        guard !devices.isEmpty else { return nil }
        guard devices.count > 1 else { return nil }
        guard let index = devices.firstIndex(of: current) else { return devices[0] }
        return devices[(index - 1 + devices.count) % devices.count]
    }
}

/// Decides whether a pinned input device should be re-asserted.
///
/// macOS reassigns the default input whenever a device with a microphone
/// appears — plugging in a monitor, connecting AirPods, joining a call. For
/// anyone with a real microphone that is nearly always wrong, and it happens
/// silently mid-call.
///
/// Pure, because the failure this guards against is an **assertion loop**:
/// re-asserting in response to the change notification our own assertion
/// caused. The rules below are what stop that, and they are worth testing
/// without a USB microphone to hand.
struct InputPinDecision {
    /// How long after our own change to ignore further notifications. The HAL
    /// emits the change we just made, and reacting to it re-asserts forever.
    var settleSeconds: Double = 0.5
    /// Maximum re-assertions inside `burstWindowSeconds` before giving up. A
    /// device that refuses to stay selected — some virtual devices do — would
    /// otherwise be fought with indefinitely.
    var burstLimit: Int = 5
    var burstWindowSeconds: Double = 10

    struct State {
        /// The device the user pinned. Nil means the feature is off.
        var pinnedUID: String?
        /// What the system default actually is right now.
        var currentUID: String?
        /// Whether the pinned device is currently connected. Re-asserting a
        /// device that is not plugged in cannot succeed.
        var pinnedIsConnected: Bool
        /// Seconds since this manager last set the input device itself.
        var sinceOwnChange: Double
        /// Re-assertions already made inside the burst window.
        var recentAssertions: Int
    }

    func shouldReassert(_ state: State) -> Bool {
        // Feature off.
        guard let pinned = state.pinnedUID, !pinned.isEmpty else { return false }
        // Already correct — the overwhelmingly common case, and the one that
        // has to be cheap.
        if state.currentUID == pinned { return false }
        // Cannot select what is not attached. Unplugging the pinned microphone
        // should hand control back to macOS, not fight it.
        guard state.pinnedIsConnected else { return false }
        // Our own change echoing back.
        if state.sinceOwnChange < settleSeconds { return false }
        // Something is fighting us; stop rather than loop.
        if state.recentAssertions >= burstLimit { return false }
        return true
    }
}

// MARK: - Manager

/// Output-device cycling, input pinning and a global microphone mute.
///
/// ## Cost
///
/// Nothing periodic. Output cycling runs only on a keypress. Input pinning
/// listens for `kAudioHardwarePropertyDefaultInputDevice`, which the HAL posts
/// on change — there is no poll, per the project rule.
@MainActor
final class AudioDeviceToolsManager: ObservableObject {
    static let shared = AudioDeviceToolsManager()

    /// Whether every input device is currently muted, for the settings UI and
    /// the menu bar readout.
    @Published private(set) var allInputsMuted = false
    /// Input devices, for the pin picker.
    @Published private(set) var inputDevices: [(uid: String, name: String)] = []

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    private var pinDecision = InputPinDecision()
    private var lastOwnChange = Date.distantPast
    private var assertionTimestamps: [Date] = []
    private var listenerInstalled = false

    /// Mute states captured before muting everything, so unmute restores what
    /// the user had rather than blanket-unmuting a device they had muted
    /// themselves.
    private var muteStatesBeforeMuteAll: [AudioDeviceID: Bool] = [:]

    private init() {}

    func start() {
        guard !started else { return }
        started = true

        Defaults.publisher(.pinnedInputDeviceUID)
            .sink { [weak self] _ in
                Task { @MainActor in self?.syncInputPin() }
            }
            .store(in: &cancellables)

        refreshInputDevices()
        syncInputPin()
    }

    // MARK: Output cycling

    /// Moves the default output to the next device in the list.
    ///
    /// Deliberately does **not** call `refreshDevices()` first. That method
    /// dispatches to a background queue and assigns `devices` back on main, so
    /// reading `devices` on the following line returns the *previous* contents
    /// — the refresh would look like it was doing something and cycle stale
    /// data. `AudioRouteManager` already re-reads on every route-change
    /// notification, so the list is current; the only case it is not is before
    /// the first refresh has ever landed, which is handled by refreshing and
    /// returning rather than acting on an empty list.
    func cycleOutputDevice(reverse: Bool = false) {
        let route = AudioRouteManager.shared
        guard !route.devices.isEmpty else {
            route.refreshDevices()
            return
        }

        let ids = route.devices.map(\.id)
        let target = reverse
            ? AudioDeviceCycle.previous(after: route.activeDeviceID, in: ids)
            : AudioDeviceCycle.next(after: route.activeDeviceID, in: ids)

        guard let target, let device = route.devices.first(where: { $0.id == target }) else { return }
        route.select(device: device)
        // No HUD: `InlineHUD.Type2Name` derives its label from the type, not
        // from the title passed to `toggleSneakPeek`, so an arbitrary output
        // device name cannot reach the notch without changing that view. The
        // switch is audible, which is the feedback that matters; claiming a HUD
        // in Settings that never appears would be worse than claiming nothing.
        NSLog("AudioDeviceTools: output -> \(device.name)")
    }

    // MARK: Microphone mute

    /// Mutes or unmutes every input device at once.
    ///
    /// Every input, not just the default: a call app can be holding a device
    /// that is not the system default, and "mute all microphones" that leaves
    /// one live is worse than not offering it.
    func toggleMuteAllInputs() {
        allInputsMuted ? unmuteAllInputs() : muteAllInputs()
    }

    private func muteAllInputs() {
        muteStatesBeforeMuteAll.removeAll()
        var muted = 0
        for deviceID in inputDeviceIDs() {
            muteStatesBeforeMuteAll[deviceID] = deviceID.readInputMuteState()
            if deviceID.setInputMuteState(true) { muted += 1 }
        }
        // Only claim the state if something actually changed. A device that
        // exposes no mute property returns false, and reporting "muted" when
        // the microphone is still live is the one failure that matters here.
        guard muted > 0 else {
            NSLog("⚠️ AudioDeviceTools: no input device exposes a mute property")
            return
        }
        allInputsMuted = true
        announceMicMute(muted: true)
    }

    private func unmuteAllInputs() {
        for deviceID in inputDeviceIDs() {
            // Restore what was there before, so a device the user had muted
            // themselves stays muted.
            let previous = muteStatesBeforeMuteAll[deviceID] ?? false
            _ = deviceID.setInputMuteState(previous)
        }
        muteStatesBeforeMuteAll.removeAll()
        allInputsMuted = false
        announceMicMute(muted: false)
    }

    // MARK: Input pinning

    private func syncInputPin() {
        // The listener is installed on first use and then left in place.
        // `AudioObjectRemovePropertyListenerBlock` needs the *same* block
        // object it was given, which a closure capture cannot reproduce, so a
        // remove would silently fail and leave a listener the manager believed
        // was gone. Leaving it is honest and costs nothing: with no device
        // pinned the callback returns on `evaluatePin`'s first guard.
        guard !Defaults[.pinnedInputDeviceUID].isEmpty else { return }
        installInputListener()
        evaluatePin()
    }

    private func evaluatePin() {
        let pinned = Defaults[.pinnedInputDeviceUID]
        let current = (try? AudioObjectID.readDefaultInputDevice()).flatMap { try? $0.readDeviceUID() }
        let connected = inputDevices.contains { $0.uid == pinned }

        let cutoff = Date().addingTimeInterval(-pinDecision.burstWindowSeconds)
        assertionTimestamps.removeAll { $0 < cutoff }

        let state = InputPinDecision.State(
            pinnedUID: pinned.isEmpty ? nil : pinned,
            currentUID: current,
            pinnedIsConnected: connected,
            sinceOwnChange: Date().timeIntervalSince(lastOwnChange),
            recentAssertions: assertionTimestamps.count)

        guard pinDecision.shouldReassert(state) else { return }

        guard let target = inputDeviceIDs().first(where: {
            (try? $0.readDeviceUID()) == pinned
        }) else { return }

        do {
            try AudioObjectID.setDefaultInputDevice(target)
            lastOwnChange = Date()
            assertionTimestamps.append(lastOwnChange)
        } catch {
            NSLog("⚠️ AudioDeviceTools: could not pin input device: \(error)")
        }
    }

    // MARK: CoreAudio plumbing

    private func inputDeviceIDs() -> [AudioDeviceID] {
        guard let all = try? AudioObjectID.readDeviceList() else { return [] }
        return all.filter { deviceHasInputChannels($0) }
    }

    /// Whether a device can record. A device with no input streams is an
    /// output-only device and must not appear in a microphone list.
    private func deviceHasInputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &size) == noErr, size > 0
        else { return false }

        let buffer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { buffer.deallocate() }

        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, buffer) == noErr
        else { return false }

        let list = UnsafeMutableAudioBufferListPointer(
            buffer.assumingMemoryBound(to: AudioBufferList.self))
        return list.contains { $0.mNumberChannels > 0 }
    }

    func refreshInputDevices() {
        inputDevices = inputDeviceIDs().compactMap { deviceID in
            guard let uid = try? deviceID.readDeviceUID(),
                  let name = try? deviceID.readDeviceName()
            else { return nil }
            return (uid: uid, name: name)
        }
    }

    private func installInputListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true

        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            MainActor.assumeIsolated {
                self?.refreshInputDevices()
                self?.evaluatePin()
            }
        }
    }

    /// Shows the microphone HUD in the notch.
    ///
    /// Uses the existing `.mic` sneak-peek type, which `InlineHUD` already
    /// renders — a mic glyph that gains a slash when `value <= 0`. A *new*
    /// `SneakContentType` case would be worse than useless here: an unhandled
    /// type still wins the branch and then draws nothing, which CLAUDE.md
    /// records as a real bug already made once.
    private func announceMicMute(muted: Bool) {
        guard Defaults[.enableAudioDeviceHUD] else { return }
        AnchorViewCoordinator.shared.toggleSneakPeek(
            status: true, type: .mic, value: muted ? 0 : 1)
    }
}
