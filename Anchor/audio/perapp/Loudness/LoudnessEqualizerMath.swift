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

enum LoudnessEqualizerMath {
    static func dbToLinear(_ db: Float) -> Float {
        pow(10, db / 20)
    }

    static func linearToDb(_ linear: Float) -> Float {
        20 * log10(max(linear, 1e-9))
    }

    static func meanSquareToDb(_ meanSquare: Float) -> Float {
        10 * log10(max(meanSquare, 1e-12))
    }

    static func rmsFromMeanSquare(_ meanSquare: Float) -> Float {
        sqrt(max(meanSquare, 0))
    }

    static func clamp(_ value: Float, min: Float, max: Float) -> Float {
        Swift.min(Swift.max(value, min), max)
    }

    static func timeConstantCoefficient(timeMs: Float, stepMs: Float) -> Float {
        1 - exp(-stepMs / max(timeMs, 1e-6))
    }
}
