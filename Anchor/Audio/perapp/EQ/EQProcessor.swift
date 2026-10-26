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
import Accelerate

/// RT-safe 10-band graphic EQ processor using vDSP_biquad.
///
/// Subclass of `BiquadProcessor` — inherits delay buffer management, atomic setup swaps,
/// stereo biquad processing, and NaN safety. This class adds EQ-specific settings
/// management and coefficient computation.
final class EQProcessor: BiquadProcessor, @unchecked Sendable {

    /// Currently applied EQ settings (needed for sample rate recalculation)
    private var _currentSettings: EQSettings?
    private nonisolated(unsafe) var headroomTarget: Float = 1
    private var headroomCurrent: Float = 1

    /// Read-only access to current settings
    var currentSettings: EQSettings? { _currentSettings }

    init(sampleRate: Double, settings: EQSettings = .flat) {
        super.init(
            sampleRate: sampleRate,
            maxSections: EQSettings.bandCount,
            category: "EQProcessor",
            initiallyEnabled: true
        )
        updateSettings(settings)
        headroomCurrent = headroomTarget
    }

    // MARK: - Settings Update

    /// Update EQ settings (call from main thread).
    func updateSettings(_ settings: EQSettings) {
        let normalized = EQSettings(bandGains: settings.clampedGains, isEnabled: settings.isEnabled)
        setEnabled(normalized.isEnabled)
        let unchanged = _currentSettings?.bandGains == normalized.bandGains
        _currentSettings = normalized
        guard !unchanged else { return }

        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )

        headroomTarget = Self.headroomGain(coefficients: coefficients, sampleRate: sampleRate)

        let newSetup = coefficients.withUnsafeBufferPointer { ptr in
            vDSP_biquad_CreateSetup(ptr.baseAddress!, vDSP_Length(EQSettings.bandCount))
        }

        swapSetup(newSetup)

        // Note: Do NOT reset delay buffers here - the filter naturally adapts to new
        // coefficients using existing state, producing smooth transitions without clicks.
        // Delay buffers are only reset on init and sample rate changes.
    }

    // MARK: - BiquadProcessor Overrides

    override func recomputeCoefficients() -> (coefficients: [Double], sectionCount: Int)? {
        guard let settings = _currentSettings else { return nil }
        let coefficients = BiquadMath.coefficientsForAllBands(
            gains: settings.clampedGains,
            sampleRate: sampleRate
        )
        headroomTarget = Self.headroomGain(coefficients: coefficients, sampleRate: sampleRate)
        return (coefficients, EQSettings.bandCount)
    }
    /// Gain changes are smoothed per frame, keeping stereo channels coherent.
    override func preProcess(output: UnsafeMutablePointer<Float>, frameCount: Int) {
        let target = headroomTarget
        guard target != 1 || headroomCurrent != 1 else { return }
        let coefficient = Float(1 - exp(-1 / (sampleRate * 0.030)))
        var gain = headroomCurrent
        for frame in 0..<frameCount {
            gain += (target - gain) * coefficient
            output[frame * 2] *= gain
            output[frame * 2 + 1] *= gain
        }
        headroomCurrent = abs(gain - target) < 0.00001 ? target : gain
    }

    /// Estimate the peak of the full cascade on a dense logarithmic grid, with
    /// 0.5 dB margin when boosted. Computed only when settings/rate change.
    static func headroomGain(coefficients: [Double], sampleRate: Double) -> Float {
        guard sampleRate > 0, coefficients.count % 5 == 0 else { return 1 }
        var peak: Double = 1
        for bin in 0...1024 {
            let frequency = bin == 0 ? 0 : exp(log(sampleRate / 2) * Double(bin) / 1024)
            let w = 2 * Double.pi * frequency / sampleRate
            let c1 = cos(w), s1 = sin(w), c2 = cos(2 * w), s2 = sin(2 * w)
            var magnitude: Double = 1
            for index in stride(from: 0, to: coefficients.count, by: 5) {
                let b0 = coefficients[index], b1 = coefficients[index + 1], b2 = coefficients[index + 2]
                let a1 = coefficients[index + 3], a2 = coefficients[index + 4]
                let nr = b0 + b1 * c1 + b2 * c2, ni = b1 * s1 + b2 * s2
                let dr = 1 + a1 * c1 + a2 * c2, di = a1 * s1 + a2 * s2
                magnitude *= sqrt((nr * nr + ni * ni) / max(1e-20, dr * dr + di * di))
            }
            if magnitude.isFinite { peak = max(peak, magnitude) }
        }
        return peak > 1.001 ? Float(1 / (peak * pow(10, 0.5 / 20))) : 1
    }

}
