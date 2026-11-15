// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import Foundation

/// A single pending record covers every device touched by one mute sweep.
/// It is deliberately separate from exported settings: device ownership and
/// an interrupted hardware write must not migrate to a different Mac.
struct MicMuteWriteAhead {
    struct Entry: Codable, Equatable {
        enum Kind: String, Codable { case muteSwitch, volume, restoreSwitch, restoreVolume }
        let uid: String
        let kind: Kind
        let volume: Double?
        let channels: [String: Double]
    }

    struct Record: Codable, Equatable {
        let version: Int
        var entries: [Entry]
    }

    enum LoadResult {
        case none
        case valid(Record)
        case invalid
    }

    let defaults: UserDefaults
    let key: String
    let synchronize: () -> Bool

    init(defaults: UserDefaults, key: String, synchronize: (() -> Bool)? = nil) {
        self.defaults = defaults
        self.key = key
        self.synchronize = synchronize ?? { defaults.synchronize() }
    }

    private static func valid(_ entry: Entry) -> Bool {
        !entry.uid.isEmpty &&
            (entry.volume.map { $0.isFinite && (0...1).contains($0) } ?? true) &&
            entry.channels.values.allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    func load() -> LoadResult {
        guard let raw = defaults.object(forKey: key) else { return .none }
        guard let data = raw as? Data,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.version == 1, !record.entries.isEmpty,
              record.entries.allSatisfy(Self.valid) else { return .invalid }
        return .valid(record)
    }

    /// Must succeed before the corresponding device write is attempted.
    func append(_ entry: Entry) -> Bool {
        guard Self.valid(entry) else { return false }
        let previous: Record
        switch load() {
        case .none: previous = Record(version: 1, entries: [])
        case .valid(let record): previous = record
        case .invalid: return false
        }
        var next = previous
        next.entries.append(entry)
        guard let data = try? JSONEncoder().encode(next) else { return false }
        defaults.set(data, forKey: key)
        return synchronize() && defaults.data(forKey: key) == data
    }

    /// Keep the pending record until all three legacy recovery values have
    /// been synchronized and read back. A failed checkpoint blocks further
    /// device writes and leaves the record for manual review.
    func checkpoint(volumes: [String: Double], channels: [String: [String: Double]],
                    devices: [String]) -> Bool {
        guard let pending = defaults.data(forKey: key), case .valid = load() else { return false }
        defaults.set(volumes, forKey: DefaultsKey.micMuteSavedVolumes)
        defaults.set(channels, forKey: DefaultsKey.micMuteSavedChannelVolumes)
        defaults.set(devices, forKey: DefaultsKey.micMuteMutedDevices)
        guard synchronize(),
              defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) as? [String: Double] == volumes,
              defaults.dictionary(forKey: DefaultsKey.micMuteSavedChannelVolumes) as? [String: [String: Double]] == channels,
              defaults.stringArray(forKey: DefaultsKey.micMuteMutedDevices) == devices else { return false }
        defaults.removeObject(forKey: key)
        guard synchronize(), defaults.object(forKey: key) == nil else {
            defaults.set(pending, forKey: key)
            _ = synchronize()
            return false
        }
        return true
    }

    /// Called only after the user confirms they checked the inputs. This
    /// discards recovery records for affected devices without changing audio.
    /// An unreadable record cannot identify its devices, so all microphone
    /// recovery claims must be discarded after that explicit confirmation.
    func discardAfterUserCheck() -> Bool {
        let raw = defaults.object(forKey: key)
        var volumes = defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) as? [String: Double] ?? [:]
        var channels = defaults.dictionary(forKey: DefaultsKey.micMuteSavedChannelVolumes) as? [String: [String: Double]] ?? [:]
        let recordedDevices = defaults.stringArray(forKey: DefaultsKey.micMuteMutedDevices) ?? []
        let ids: Set<String>
        switch load() {
        case .none: return true
        case .valid(let record): ids = Set(record.entries.map(\.uid))
        case .invalid: ids = Set(recordedDevices).union(volumes.keys).union(channels.keys)
        }
        let devices = recordedDevices.filter { !ids.contains($0) }
        for uid in ids { volumes.removeValue(forKey: uid); channels.removeValue(forKey: uid) }
        defaults.set(volumes, forKey: DefaultsKey.micMuteSavedVolumes)
        defaults.set(channels, forKey: DefaultsKey.micMuteSavedChannelVolumes)
        defaults.set(devices, forKey: DefaultsKey.micMuteMutedDevices)
        defaults.set(false, forKey: DefaultsKey.micMuteActive)
        guard synchronize(),
              defaults.dictionary(forKey: DefaultsKey.micMuteSavedVolumes) as? [String: Double] == volumes,
              defaults.dictionary(forKey: DefaultsKey.micMuteSavedChannelVolumes) as? [String: [String: Double]] == channels,
              defaults.stringArray(forKey: DefaultsKey.micMuteMutedDevices) == devices,
              !defaults.bool(forKey: DefaultsKey.micMuteActive) else { return false }
        defaults.removeObject(forKey: key)
        guard synchronize(), defaults.object(forKey: key) == nil else {
            if let raw { defaults.set(raw, forKey: key); _ = synchronize() }
            return false
        }
        return true
    }
}
