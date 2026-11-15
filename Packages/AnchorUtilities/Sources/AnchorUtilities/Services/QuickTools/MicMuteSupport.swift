// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// The decisions behind a global microphone mute, kept apart from the audio
/// calls so they can be pinned down by tests: which devices the mute has to
/// reach, which ones it must never touch, and how a device gets its level back.
enum MicMuteSupport {
    /// The app's own private aggregate devices: the mixer's, the island's
    /// level reader's and the recorder's. Each carries a tapped app's audio,
    /// not a microphone, and muting one would silence the very thing it is
    /// rendering or reading; a private aggregate is still listed to the
    /// process that created it, so every device list skips them by name.
    static let ownDeviceNames: Set<String> = ["Anchor Mixer", "Anchor AirPlay", "Anchor Island Levels",
                                              "Anchor Recorder"]

    /// The level a device falls back to when nothing was ever saved for it:
    /// loud enough to be usable, quiet enough not to startle.
    static let fallbackVolume: Float = 0.75

    static func isOwnDevice(name: String) -> Bool {
        ownDeviceNames.contains(name)
    }

    /// A level worth remembering. Saving a zero would make the unmute restore
    /// silence, which is how a re-applied mute could strand a microphone.
    static func shouldSaveVolume(_ volume: Float?) -> Bool {
        guard let volume else { return false }
        return volume > 0.01
    }

    /// Individual channels may deliberately be silent even when the device
    /// as a whole is not. Preserve zero rather than replacing it with the
    /// device's fallback level when restoring the channel balance.
    static func shouldSaveChannelVolume(_ volume: Float) -> Bool {
        volume.isFinite && (0...1).contains(volume)
    }

    /// When a master exists, treat its zero as device silence. Without one,
    /// every inspected channel must be readable and silent before treating the
    /// device as already muted by someone else.
    static func volumeIsSilent(hasMaster: Bool, master: Float?, channels: [Float?]) -> Bool {
        func silent(_ value: Float?) -> Bool {
            guard let value, shouldSaveChannelVolume(value) else { return false }
            return value <= 0.01
        }
        if hasMaster { return silent(master) }
        return !channels.isEmpty && channels.allSatisfy(silent)
    }

    static func volumeRestoreMayWrite(elements: [(UInt32, Float?)], channels: [String: Double]) -> Bool {
        guard !elements.isEmpty else { return false }
        return elements.allSatisfy { element, value in
            (element == 0 || channels[String(element)] != nil) &&
                (value.map { $0.isFinite && $0 >= 0 && $0 <= 0.01 } ?? false)
        }
    }

    static func volumeSnapshotMatches(elements: [(UInt32, Float?)], volume: Float?,
                                      channels: [String: Double]) -> Bool {
        guard !elements.isEmpty else { return false }
        return elements.allSatisfy { element, current in
            guard let current, shouldSaveChannelVolume(current) else { return false }
            let saved = element == 0 ? volume.map(Double.init) : channels[String(element)]
            guard let saved, saved.isFinite, (0...1).contains(saved) else { return false }
            return abs(Double(current) - saved) <= 0.01
        }
    }

    static func volumeToRestore(uid: String,
                                saved: [String: Double],
                                legacy: Double) -> Float {
        if let value = saved[uid], value > 0.01 { return Float(value) }
        if legacy > 0.01 { return Float(legacy) }
        return fallbackVolume
    }

    static func needsRecoveryAtLaunch(featureAvailable: Bool, recorded: [String]?) -> Bool {
        !featureAvailable && !(recorded ?? []).isEmpty
    }

    static func hasUntrackedActiveMute(active: Bool, recorded: [String]?) -> Bool {
        active && recorded == nil
    }

    static func needsDeviceListeners(featureAvailable: Bool, wantsMute: Bool, hasClaims: Bool) -> Bool {
        (featureAvailable && wantsMute) || hasClaims
    }

    /// Automatic recovery must never infer ownership from a missing legacy record.
    /// The old all-device fallback is reserved for an explicit user unmute.
    static func claimsForSweep(recorded: [String]?, muted: Bool, explicitUnmute: Bool) -> [String]? {
        if !muted && !explicitUnmute { return recorded ?? [] }
        return recorded
    }

    /// Which devices an unmute has to touch. Normally only the ones this app
    /// muted, so a microphone the user silenced in System Settings stays
    /// silenced. With no record at all (settings restored onto another Mac, or
    /// a state from before this was tracked) every present device is restored:
    /// leaving someone muted with no way back is the worse failure. An empty
    /// record is different from a missing one: it means the sweep ran and
    /// every device was already silent by the user's own hand, so there is
    /// nothing this app is allowed to open.
    static func restoreTargets(recorded: [String]?, present: [String]) -> [String] {
        guard let recorded else { return present }
        let wanted = Set(recorded)
        return present.filter { wanted.contains($0) }
    }

    /// The claims a sweep carries forward untouched: the devices this app
    /// silenced that are not here right now. A headset unplugged while muted
    /// comes back still silenced, and it is still this app's to release;
    /// dropping the claim would leave it muted with nothing left to unmute it.
    static func absentClaims(recorded: [String]?, present: [String]) -> [String] {
        let here = Set(present)
        return (recorded ?? []).filter { !here.contains($0) }
    }
}
