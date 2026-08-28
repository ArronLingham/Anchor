/*
 * Anchor
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * The per-app audio engine this drives is derived from FineTune
 * (github.com/ronitsingh10/FineTune), Copyright (C) 2026 Ronit Singh.
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
import AudioToolbox
import Combine
import Defaults
import Foundation

/// What Anchor is doing to one app's audio.
///
/// Keyed by bundle identifier rather than PID so it survives the app being
/// relaunched, which a PID does not.
struct PerAppAudioState: Codable, Equatable, Defaults.Serializable {
    var volume: Float = 1
    var isMuted: Bool = false
    var eqBandGains: [Float] = Array(repeating: 0, count: EQSettings.bandCount)
    var eqEnabled: Bool = false

    var eqSettings: EQSettings {
        EQSettings(bandGains: eqBandGains, isEnabled: eqEnabled)
    }

    /// Whether this state needs the engine at all.
    ///
    /// Anything that is exactly default is not worth a tap, an aggregate device
    /// and a real-time thread, so the engine is torn down rather than left
    /// running a no-op multiply.
    var needsProcessing: Bool {
        isMuted
            || abs(volume - 1) > 0.001
            || (eqEnabled && eqBandGains.contains { abs($0) > 0.01 })
    }
}

/// Per-app volume, mute and EQ.
///
/// ## How this works
///
/// CoreAudio has no per-process volume — `kAudioProcessProperty*` covers a
/// process's PID, bundle identifier, devices and whether it is running, and
/// nothing else. Gain therefore means: tap the process with
/// `muteBehavior = .mutedWhenTapped` so its audio stops reaching the device but
/// still reaches us, build a private aggregate device out of the real output
/// plus that tap, and run an IOProc that reads the tap and re-renders it.
///
/// The engine that does this is `ProcessTapController`, ported from FineTune.
/// An earlier hand-written attempt lived here and did not work; what it got
/// wrong is worth recording, because each mistake looked reasonable:
///
/// - **It tapped one process object, not all of them.** `AudioApp` carries
///   `processObjectIDs` — *plural*. Spotify and Chrome route audio through
///   helper processes, so a tap on the main process's single object taps a
///   process that is not making any sound.
/// - **It started the IOProc immediately.** An aggregate device is not ready
///   when `AudioHardwareCreateAggregateDevice` returns; the engine waits on
///   `waitUntilReady(timeout:)` first.
/// - **It omitted `kAudioAggregateDeviceTapAutoStartKey` and
///   `kAudioAggregateDeviceClockDeviceKey`.**
/// - **It applied gain instantly**, where the engine ramps over 30 ms — an
///   instant change on a live buffer is an audible click.
/// - **It ignored drift compensation.** The engine turns sub-tap drift
///   compensation *off* for Bluetooth outputs, where tap and output share a
///   clock; leaving it on makes the HAL insert or delete a sample every ~0.7 s,
///   which is the rhythmic crackle on calls.
///
/// ## Cost
///
/// Nothing runs until an app is muted, moved off 100%, or given an EQ curve.
/// Taps and aggregate devices are owned by this process, so if Anchor exits or
/// crashes every app returns to normal on its own.
@MainActor
final class PerAppAudioManager: ObservableObject {
    static let shared = PerAppAudioManager()

    /// Apps currently producing audio.
    @Published private(set) var apps: [AudioApp] = []

    /// What we are doing to each of them, keyed by `persistenceIdentifier`.
    @Published private(set) var states: [String: PerAppAudioState] = [:]

    /// Set when the engine could not start, so the UI can say so rather than
    /// showing a slider that silently does nothing.
    @Published private(set) var lastFailure: String?

    /// Whether macOS has granted audio capture. Without it a tap is created
    /// with `noErr` and an unusable ID, so this must be checked, not assumed.
    @Published private(set) var permission: AudioCapturePermissionStatus = .unknown

    private let processMonitor = AudioProcessMonitor()
    private let deviceMonitor = AudioDeviceMonitor()
    private let permissionChecker = AudioRecordingPermission()

    private var controllers: [pid_t: ProcessTapController] = [:]
    private var started = false

    private init() {
        states = Defaults[.perAppAudioStates]
    }

    // MARK: - Lifecycle

    /// Starts watching the audio process list. Cheap: CoreAudio property
    /// listeners, no timer.
    func start() {
        guard !started else { return }
        started = true

        deviceMonitor.start()

        processMonitor.onAppsChanged = { [weak self] apps in
            MainActor.assumeIsolated { self?.appsChanged(apps) }
        }
        processMonitor.start()

        permissionChecker.refreshStatus()
        permission = permissionChecker.status

        // A device change invalidates every aggregate device, since each was
        // built around whichever output was default at the time.
        deviceMonitor.onDeviceDisconnected = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rebuildAll() }
        }
        deviceMonitor.onDeviceConnected = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.rebuildAll() }
        }
    }

    func refresh() {
        start()
        permissionChecker.refreshStatus()
        permission = permissionChecker.status
    }

    func requestPermission() {
        permissionChecker.request()
    }

    private func appsChanged(_ newApps: [AudioApp]) {
        apps = newApps.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let live = Set(newApps.map(\.id))
        for pid in controllers.keys where !live.contains(pid) {
            controllers.removeValue(forKey: pid)?.invalidate()
        }

        // An app that has just appeared and has stored settings gets them back.
        for app in newApps where state(for: app).needsProcessing {
            syncController(for: app)
        }
    }

    // MARK: - Reading state

    func state(for app: AudioApp) -> PerAppAudioState {
        states[app.persistenceIdentifier] ?? PerAppAudioState()
    }

    func isMuted(_ pid: pid_t) -> Bool {
        guard let app = apps.first(where: { $0.id == pid }) else { return false }
        return state(for: app).isMuted
    }

    func volume(for app: AudioApp) -> Float { state(for: app).volume }

    func eq(for app: AudioApp) -> EQSettings { state(for: app).eqSettings }

    /// True while the engine is actually running for this app.
    func isEngaged(_ pid: pid_t) -> Bool { controllers[pid] != nil }

    /// Live output level, for the meter. Zero when nothing is engaged.
    func audioLevel(_ pid: pid_t) -> Float { controllers[pid]?.audioLevel ?? 0 }

    // MARK: - Writing state

    func setVolume(_ volume: Float, for app: AudioApp) {
        mutate(app) { $0.volume = max(0, min(2, volume)) }
    }

    func toggleMute(_ app: AudioApp) {
        mutate(app) { $0.isMuted.toggle() }
    }

    func setMuted(_ muted: Bool, for app: AudioApp) {
        mutate(app) { $0.isMuted = muted }
    }

    func setEQ(_ settings: EQSettings, for app: AudioApp) {
        mutate(app) {
            $0.eqBandGains = settings.bandGains
            $0.eqEnabled = settings.isEnabled
        }
    }

    func applyPreset(_ preset: EQPreset, to app: AudioApp) {
        mutate(app) {
            $0.eqBandGains = preset.settings.bandGains
            $0.eqEnabled = true
        }
    }

    /// Returns every app to normal. Called on quit — belt and braces, since
    /// macOS destroys our taps with the process anyway.
    func resetAll() {
        for (pid, controller) in controllers {
            controller.invalidate()
            controllers.removeValue(forKey: pid)
        }
    }

    /// Kept for the termination handler's existing call site.
    func unmuteAll() { resetAll() }

    private func mutate(_ app: AudioApp, _ change: (inout PerAppAudioState) -> Void) {
        var current = state(for: app)
        change(&current)

        if current == PerAppAudioState() {
            states.removeValue(forKey: app.persistenceIdentifier)
        } else {
            states[app.persistenceIdentifier] = current
        }
        Defaults[.perAppAudioStates] = states

        syncController(for: app)
    }

    // MARK: - Engine

    /// Brings the engine into line with the stored state for one app: starts
    /// it, updates it, or tears it down.
    private func syncController(for app: AudioApp) {
        let wanted = state(for: app)

        guard wanted.needsProcessing else {
            controllers.removeValue(forKey: app.id)?.invalidate()
            return
        }

        if let existing = controllers[app.id] {
            existing.volume = wanted.volume
            existing.isMuted = wanted.isMuted
            existing.updateEQSettings(wanted.eqSettings)
            return
        }

        guard let outputUID = currentOutputUID() else {
            lastFailure = String(localized: "No output device available")
            return
        }

        let controller = ProcessTapController(
            app: app,
            targetDeviceUID: outputUID,
            deviceMonitor: deviceMonitor,
            preferredTapSourceDeviceUID: outputUID)

        do {
            try controller.activate(initial: TapInitialState(eqSettings: wanted.eqSettings))
            controller.volume = wanted.volume
            controller.isMuted = wanted.isMuted
            controllers[app.id] = controller
            lastFailure = nil
        } catch {
            // Failing leaves the app on normal system audio at full volume.
            // Muted-with-nothing-replacing-it is the one outcome that would
            // read as broken hardware, so it is never a failure mode here.
            controller.invalidate()
            lastFailure = error.localizedDescription
            Logger.log(
                "Per-app audio engine failed for \(app.name): \(error.localizedDescription)",
                category: .error)
        }
    }

    /// Rebuilds every engaged app against the current output device.
    private func rebuildAll() {
        let engaged = Array(controllers.keys)
        for pid in engaged {
            controllers.removeValue(forKey: pid)?.invalidate()
        }
        for app in apps where state(for: app).needsProcessing {
            syncController(for: app)
        }
    }

    private func currentOutputUID() -> String? {
        guard let deviceID = try? AudioObjectID.readDefaultOutputDevice(),
              let uid = try? deviceID.readDeviceUID()
        else { return nil }
        return uid
    }
}
