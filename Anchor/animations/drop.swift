/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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
import Defaults
import SwiftUI


/// How the notch opens and closes.
public enum NotchAnimationProfile: String, CaseIterable, Defaults.Serializable {
    case bouncy, smooth, snappy, instant

    var label: String {
        switch self {
        case .bouncy: "Bouncy"
        case .smooth: "Smooth"
        case .snappy: "Snappy"
        case .instant: "Instant"
        }
    }

    var detail: String {
        switch self {
        case .bouncy: "Overshoots slightly and settles. The default."
        case .smooth: "Eases in and out with no overshoot."
        case .snappy: "Quick, with a small settle."
        case .instant: "No animation at all."
        }
    }

    var animation: Animation {
        switch self {
        case .bouncy: .spring(.bouncy(duration: 0.4))
        case .smooth: .smooth(duration: 0.35)
        case .snappy: .snappy(duration: 0.25)
        // `.linear(duration: 0)` rather than nil, so callers that pass this
        // into withAnimation still take the same path.
        case .instant: .linear(duration: 0)
        }
    }

    /// Opening is springier than closing throughout — a notch that overshoots
    /// on the way shut reads as a glitch rather than as bounce.
    ///
    /// `.bouncy` reproduces the values that were hardcoded in `ContentView`
    /// before the profiles existed, so the default behaviour is unchanged.
    var openAnimation: Animation {
        switch self {
        case .bouncy: .spring(response: 0.42, dampingFraction: 0.8, blendDuration: 0)
        case .smooth: .smooth(duration: 0.32)
        case .snappy: .snappy(duration: 0.22)
        case .instant: .linear(duration: 0)
        }
    }

    var closeAnimation: Animation {
        switch self {
        case .bouncy: .spring(response: 0.45, dampingFraction: 1.0, blendDuration: 0)
        case .smooth: .smooth(duration: 0.32)
        case .snappy: .snappy(duration: 0.22)
        case .instant: .linear(duration: 0)
        }
    }
}

public class AnchorAnimations {
    @Published var notchStyle: Style = .notch

    init() {
        self.notchStyle = .notch
    }

    /// The pill style predates the profiles and keeps its own curve; the
    /// profile picker only governs the notch.
    var animation: Animation {
        guard notchStyle == .notch else {
            return .timingCurve(0.16, 1, 0.3, 1, duration: 0.7)
        }
        return Defaults[.notchAnimationProfile].animation
    }

    // TODO: Move all animations to this file

}
