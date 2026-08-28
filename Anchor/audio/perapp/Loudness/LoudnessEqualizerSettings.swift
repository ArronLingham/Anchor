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

nonisolated struct LoudnessEqualizerSettings: Codable, Equatable, Sendable {
    var targetLoudnessDb: Float = -12
    var maxBoostDb: Float = 6
    var maxCutDb: Float = 4
    var compressionThresholdOffsetDb: Float = 6
    var compressionRatio: Float = 1.6
    var compressionKneeDb: Float = 8

    var analysisWindowMs: Float = 400
    var analysisHopMs: Float = 100

    var detectorAttackMs: Float = 25
    var detectorReleaseMs: Float = 600

    var gainAttackMs: Float = 250
    var gainReleaseMs: Float = 3000

    var noiseFloorThresholdDb: Float = -40
    var lowLevelMaxBoostDb: Float = 0.5

    var enabled: Bool = false
}
