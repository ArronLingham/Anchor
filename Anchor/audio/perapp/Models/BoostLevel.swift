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

/// Per-app volume boost multiplier
enum BoostLevel: Float, CaseIterable, Codable {
    case x1 = 1.0
    case x2 = 2.0
    case x3 = 3.0
    case x4 = 4.0

    var label: String {
        switch self {
        case .x1: "1x"
        case .x2: "2x"
        case .x3: "3x"
        case .x4: "4x"
        }
    }

    /// Next boost level (cycles: 1x → 2x → 3x → 4x → 1x)
    var next: BoostLevel {
        switch self {
        case .x1: .x2
        case .x2: .x3
        case .x3: .x4
        case .x4: .x1
        }
    }

    /// Whether this boost level amplifies above unity
    var isBoosted: Bool { self != .x1 }
}
