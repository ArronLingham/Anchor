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
import CoreAudio
import Foundation

/// One app that is currently producing audio.
struct AudioApp: Identifiable, Equatable {
    var id: pid_t { pid }
    let pid: pid_t
    let objectID: AudioObjectID
    let name: String
    let bundleID: String?
    let isPlaying: Bool
}

/// Per-app mute. Part of category 5.
///
/// **This is mute, not a volume slider, and the difference is deliberate.**
/// A `CATapDescription` with `muteBehavior = .muted` silences a process's
/// output, which is all that is needed here. Arbitrary *gain* would mean
/// muting the app, capturing its stream through an aggregate device, applying
/// a multiplier and re-rendering it to the output device from a real-time
/// IOProc — an audio engine sitting permanently in the path of the user's
/// sound, where a mistake is distortion or silence rather than a visual bug.
/// That is not something to land unverified.
///
/// Nothing runs until the user mutes something. A tap is created on mute and
/// destroyed on unmute, and taps are owned by this process — if Anchor exits or
/// crashes, the OS tears them down and audio comes back on its own.
@MainActor
final class PerAppAudioManager: ObservableObject {
    static let shared = PerAppAudioManager()

    @Published private(set) var apps: [AudioApp] = []

    /// PIDs currently muted, each with the tap holding it muted.
    @Published private(set) var mutedPIDs: Set<pid_t> = []
    private var taps: [pid_t: AudioObjectID] = [:]

    private var listenerInstalled = false

    private init() {}

    // MARK: - Enumeration

    /// Refreshes the app list. Called when the picker opens and when CoreAudio
    /// says the process list changed — never on a timer.
    func refresh() {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr
        else { return }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { apps = []; return }

        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr
        else { return }

        var found: [AudioApp] = []
        for object in ids {
            guard let pid = Self.pid(of: object),
                  let app = NSRunningApplication(processIdentifier: pid),
                  let name = app.localizedName
            else { continue }

            // Helper processes share their parent's name and would appear as
            // duplicates; the audio object for the helper is the one that
            // actually plays, so keep whichever is currently outputting.
            let playing = Self.isRunningOutput(object)
            if let existing = found.firstIndex(where: { $0.name == name }) {
                if playing && !found[existing].isPlaying {
                    found[existing] = AudioApp(
                        pid: pid, objectID: object, name: name,
                        bundleID: app.bundleIdentifier, isPlaying: true)
                }
                continue
            }
            found.append(AudioApp(
                pid: pid, objectID: object, name: name,
                bundleID: app.bundleIdentifier, isPlaying: playing))
        }

        // Playing first, then alphabetical — the thing you want to mute is
        // almost always the thing making noise.
        apps = found.sorted {
            $0.isPlaying == $1.isPlaying
                ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                : $0.isPlaying
        }

        reconcileMutes()
        installListenerIfNeeded()
    }

    /// Drops taps whose app has exited, so a quit app does not leak a tap or
    /// stay listed as muted for ever.
    private func reconcileMutes() {
        let live = Set(apps.map(\.pid))
        for pid in mutedPIDs where !live.contains(pid) {
            destroyTap(for: pid)
        }
    }

    private func installListenerIfNeeded() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &address, DispatchQueue.main
        ) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Muting

    func isMuted(_ pid: pid_t) -> Bool { mutedPIDs.contains(pid) }

    func toggleMute(_ app: AudioApp) {
        if mutedPIDs.contains(app.pid) {
            destroyTap(for: app.pid)
        } else {
            createMuteTap(for: app)
        }
    }

    /// Releases every mute. Called on quit — belt and braces, since the OS
    /// destroys our taps anyway when the process goes.
    func unmuteAll() {
        for pid in mutedPIDs { destroyTap(for: pid) }
    }

    private func createMuteTap(for app: AudioApp) {
        let description = CATapDescription()
        description.processes = [app.objectID]
        description.muteBehavior = .muted
        description.isPrivate = true
        description.name = "Anchor mute — \(app.name)"

        var tapID = AudioObjectID(kAudioObjectUnknown)
        let status = AudioHardwareCreateProcessTap(description, &tapID)
        guard status == noErr, tapID != AudioObjectID(kAudioObjectUnknown) else {
            Logger.log(
                "Per-app mute failed for \(app.name): OSStatus \(status)", category: .lifecycle)
            return
        }
        taps[app.pid] = tapID
        mutedPIDs.insert(app.pid)
    }

    private func destroyTap(for pid: pid_t) {
        if let tapID = taps[pid] {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr {
                Logger.log("Per-app unmute failed: OSStatus \(status)", category: .lifecycle)
            }
        }
        taps.removeValue(forKey: pid)
        mutedPIDs.remove(pid)
    }

    // MARK: - CoreAudio helpers

    private static func pid(of object: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return nil }
        return value
    }

    private static func isRunningOutput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr
        else { return false }
        return value != 0
    }
}
