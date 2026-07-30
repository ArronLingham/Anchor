/*
 * Atoll (DynamicIsland)
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

import Defaults
import Foundation

/// Frecency ranking — how often *and* how recently an app was launched.
///
/// Pure frequency is wrong: the app you opened 200 times last year should not
/// outrank the one you have opened twice today. Each launch is worth a weight
/// that decays with age, so the ordering follows what you are working on now.
final class LaunchHistory {
    static let shared = LaunchHistory()

    /// A launch this many days ago is worth half a launch today.
    private static let halfLifeDays: Double = 10

    private var counts: [String: Double]
    private var lastLaunched: [String: Date]
    private let queue = DispatchQueue(label: "com.anchor.launch-history")

    private init() {
        counts = Defaults[.launcherFrecencyScores]
        lastLaunched = Defaults[.launcherLastLaunched]
    }

    /// Records a launch. `identifier` is the app's bundle path.
    func recordLaunch(_ identifier: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let now = Date()
            // Decay the existing score to "now" before adding, so scores from
            // different eras are directly comparable.
            let decayed = self.decayedScore(for: identifier, at: now)
            self.counts[identifier] = decayed + 1
            self.lastLaunched[identifier] = now

            let snapshotCounts = self.counts
            let snapshotDates = self.lastLaunched
            DispatchQueue.main.async {
                Defaults[.launcherFrecencyScores] = snapshotCounts
                Defaults[.launcherLastLaunched] = snapshotDates
            }
        }
    }

    /// Current frecency weight, decayed to now. Zero for never-launched apps.
    func score(for identifier: String) -> Double {
        queue.sync { decayedScore(for: identifier, at: Date()) }
    }

    private func decayedScore(for identifier: String, at now: Date) -> Double {
        guard let raw = counts[identifier] else { return 0 }
        guard let last = lastLaunched[identifier] else { return raw }
        let ageDays = now.timeIntervalSince(last) / 86_400
        guard ageDays > 0 else { return raw }
        return raw * pow(0.5, ageDays / Self.halfLifeDays)
    }

    func reset() {
        queue.async { [weak self] in
            self?.counts = [:]
            self?.lastLaunched = [:]
            DispatchQueue.main.async {
                Defaults[.launcherFrecencyScores] = [:]
                Defaults[.launcherLastLaunched] = [:]
            }
        }
    }
}
