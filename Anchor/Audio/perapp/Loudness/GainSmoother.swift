/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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

import Foundation

/// Smooths gain changes using asymmetric attack/release time constants.
/// Ticks once per analysis hop. RT-safe — no allocations in `process`.
final class GainSmoother: @unchecked Sendable {
    private var settings: LoudnessEqualizerSettings
    private var attackCoeff: Float
    private var releaseCoeff: Float
    private(set) var currentGainDb: Float = 0

    init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
        self.settings = settings
        let hopMs = settings.analysisHopMs
        self.attackCoeff  = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: settings.gainAttackMs,  stepMs: hopMs)
        self.releaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: settings.gainReleaseMs, stepMs: hopMs)
    }

    /// Reset smoother to a known initial gain.
    func reset(initialGainDb: Float = 0) {
        currentGainDb = initialGainDb
    }

    /// Advance one hop toward `targetGainDb`. Returns the current smoothed gain.
    func process(targetGainDb: Float) -> Float {
        // Attack: target < current means gain is being reduced (signal got louder) — use faster coeff
        // Release: target >= current means gain is recovering — use slower coeff
        let coeff: Float = targetGainDb < currentGainDb ? attackCoeff : releaseCoeff
        currentGainDb += coeff * (targetGainDb - currentGainDb)
        return currentGainDb
    }
}
