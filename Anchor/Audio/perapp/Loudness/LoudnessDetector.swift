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

/// Measures signal loudness using a ring-buffer RMS estimator and applies
/// asymmetric attack/release envelope smoothing in the dB domain.
///
/// Thread-safety: all mutation must occur on a single real-time audio thread.
/// The class is marked @unchecked Sendable because its mutable state is
/// exclusively owned by that thread.
final class LoudnessDetector: @unchecked Sendable {

    // MARK: - Private state

    private var settings: LoudnessEqualizerSettings
    private var sampleRate: Float

    // Ring buffer (stores squared samples)
    private var ringBuffer: [Float]
    private var writeIndex: Int = 0
    private var hopCounter: Int = 0
    private var runningSquareSum: Float = 0

    // Derived sizes
    private var windowSamples: Int
    private var inverseWindowSamples: Float
    private var hopSamples: Int

    // Envelope coefficients
    private var attackCoeff: Float
    private var releaseCoeff: Float

    // Smoothed level in dB
    private var smoothedLevel: Float = -120.0

    // MARK: - Init

    init(settings: LoudnessEqualizerSettings, sampleRate: Float) {
        self.settings = settings
        self.sampleRate = sampleRate

        let ws = Int(settings.analysisWindowMs / 1000 * sampleRate)
        windowSamples = max(ws, 1)
        inverseWindowSamples = 1.0 / Float(windowSamples)

        let hs = Int(settings.analysisHopMs / 1000 * sampleRate)
        hopSamples = max(hs, 1)

        ringBuffer = [Float](repeating: 0, count: windowSamples)

        attackCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: settings.detectorAttackMs,
            stepMs: settings.analysisHopMs
        )
        releaseCoeff = LoudnessEqualizerMath.timeConstantCoefficient(
            timeMs: settings.detectorReleaseMs,
            stepMs: settings.analysisHopMs
        )
    }

    // MARK: - Real-time ingest

    /// Ingest one K-weighted sample. Returns a new smoothed level (dB) when a
    /// hop boundary is reached, otherwise returns nil.
    /// RT-safe: no allocations, no logging, no ObjC.
    func ingest(weightedSample: Float) -> Float? {
        // Update running sum: subtract old squared value, store new squared value, add it
        runningSquareSum -= ringBuffer[writeIndex]
        ringBuffer[writeIndex] = weightedSample * weightedSample
        runningSquareSum += ringBuffer[writeIndex]

        writeIndex += 1
        if writeIndex == windowSamples {
            writeIndex = 0
        }

        hopCounter += 1
        if hopCounter >= hopSamples {
            hopCounter = 0
            let meanSquare = runningSquareSum * inverseWindowSamples
            let levelDb = LoudnessEqualizerMath.meanSquareToDb(meanSquare)
            return updateEnvelope(with: levelDb)
        }
        return nil
    }

    // MARK: - Envelope smoothing

    /// Apply asymmetric attack/release smoothing. Returns the updated smoothed level.
    func updateEnvelope(with measuredLevelDb: Float) -> Float {
        let coeff: Float
        if measuredLevelDb > smoothedLevel {
            coeff = attackCoeff
        } else {
            coeff = releaseCoeff
        }
        smoothedLevel += coeff * (measuredLevelDb - smoothedLevel)
        return smoothedLevel
    }

    // MARK: - Reset

    func reset() {
        for i in 0..<ringBuffer.count {
            ringBuffer[i] = 0
        }
        writeIndex = 0
        hopCounter = 0
        runningSquareSum = 0
        smoothedLevel = -120.0
    }
}
