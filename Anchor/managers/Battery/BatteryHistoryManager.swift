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
import Defaults
import Foundation

/// A single battery reading.
struct BatterySample: Codable, Equatable {
    let at: Date
    let level: Float
    let charging: Bool
}

/// Battery level over the last 24 hours. Category 8.
///
/// Records nothing on a timer. `BatteryActivityManager` already owns an
/// `IOPSNotificationCreateRunLoopSource`, which the OS signals when the power
/// source actually changes, so this subscribes to that and writes a sample only
/// when the level or charging state moves. On a machine sitting at 100% plugged
/// in, that is zero samples per hour.
@MainActor
final class BatteryHistoryManager: ObservableObject {
    static let shared = BatteryHistoryManager()

    /// Oldest first. Capped by age, not by count — see `retention`.
    @Published private(set) var samples: [BatterySample] = []

    private let retention: TimeInterval = 24 * 60 * 60

    /// Enough to draw a smooth 24 h line without unbounded growth if something
    /// upstream ever starts chattering.
    private let maxSamples = 720

    private var observerID: Int?
    private var cancellables = Set<AnyCancellable>()
    private var saveWorkItem: DispatchWorkItem?

    private var storeURL: URL {
        AppSupportDirectory.root.appendingPathComponent("battery-history.json")
    }

    private init() {
        // Never block in a manager's init — see CLAUDE.md. Reading the store
        // touches disk, and subscribing reaches into IOKit.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.load()
            Defaults.publisher(.enableBatteryHistory)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncToSettings() }
                .store(in: &self.cancellables)
            self.syncToSettings()
        }
    }

    private func syncToSettings() {
        if Defaults[.enableBatteryHistory] { start() } else { stop() }
    }

    private func start() {
        guard observerID == nil else { return }
        let manager = BatteryActivityManager.shared
        observerID = manager.addObserver { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        // Seed with where we are now, so a fresh install draws something.
        let info = manager.initializeBatteryInfo()
        record(level: info.currentCapacity, charging: info.isCharging)
    }

    private func stop() {
        if let observerID {
            BatteryActivityManager.shared.removeObserver(byId: observerID)
        }
        observerID = nil
    }

    private func handle(_ event: BatteryActivityManager.BatteryEvent) {
        let last = samples.last
        switch event {
        case let .batteryLevelChanged(level):
            record(level: level, charging: last?.charging ?? false)
        case let .isChargingChanged(isCharging):
            record(level: last?.level ?? 0, charging: isCharging)
        case let .powerSourceChanged(isPluggedIn):
            record(level: last?.level ?? 0, charging: isPluggedIn)
        default:
            break
        }
    }

    private func record(level: Float, charging: Bool) {
        guard level > 0 else { return }
        let now = Date()

        // The OS can signal several times for one real change. Collapse a
        // repeat that says nothing new.
        if let last = samples.last,
           last.level == level,
           last.charging == charging,
           now.timeIntervalSince(last.at) < 60
        {
            return
        }

        samples.append(BatterySample(at: now, level: level, charging: charging))
        prune(now: now)
        scheduleSave()
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-retention)
        if let first = samples.first, first.at < cutoff {
            samples.removeAll { $0.at < cutoff }
        }
        if samples.count > maxSamples {
            samples.removeFirst(samples.count - maxSamples)
        }
    }

    /// Coalesced — a burst of events writes the file once.
    private func scheduleSave() {
        saveWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.save() }
        }
        saveWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
    }

    private func save() {
        let snapshot = samples
        let url = storeURL
        DispatchQueue.global(qos: .utility).async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? data.write(to: url, options: [.atomic])
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let decoded = try? JSONDecoder().decode([BatterySample].self, from: data)
        else { return }
        samples = decoded
        prune(now: Date())
    }

    /// Percentage points gained or lost over the recorded window.
    var netChange: Float? {
        guard let first = samples.first, let last = samples.last, samples.count > 1
        else { return nil }
        return last.level - first.level
    }
}
