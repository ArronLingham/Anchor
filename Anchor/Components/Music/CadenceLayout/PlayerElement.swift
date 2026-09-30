/*
 * Cadence
 * Copyright (C) 2026 Cadence Contributors
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

import CoreGraphics
import Foundation

// This file is deliberately free of SwiftUI, AppKit and Defaults so that it and
// `GridSolver` compile standalone under `swiftc` in `tests/`. Anything that
// needs to *draw* an element belongs in `PlayerSurfaceView`, not here.

/// Everything a user can place on a surface.
///
/// This supersedes Anchor's `MusicControlButton`, which was a fixed array of
/// five *buttons* on one globally-shared key. Title, artist, progress and the
/// artwork were not in that enum at all — they were hardcoded `VStack` children
/// on every surface, which is why "add and remove anything I want, separately
/// per surface" could not be built on it.
public enum PlayerElement: String, CaseIterable, Codable, Sendable {
    // Artwork. `artwork` covers both the album cover and the vinyl record; which
    // one is drawn is an `ArtworkStyle` on the placement, not a separate case,
    // so cover-vs-vinyl is one decision that works identically on all four
    // surfaces rather than four loose global booleans.
    case artwork

    // Text
    case title
    case artist
    case album

    // Transport
    case playPause
    case next
    case previous
    case seekBackward
    case seekForward

    // Modes
    case shuffle
    case repeatMode

    // Progress and time
    case progressBar
    case timeElapsed
    case timeRemaining
    /// One readout that flips between elapsed and remaining when clicked.
    case trackTimeToggle

    // Audio
    case outputDevice
    case airPlay
    case volumeSlider
    case visualizer

    // Extras
    case lyrics
    case appIcon
    case explicitBadge
    /// Wall clock. Independent of playback.
    case clock
    /// Countdown timer. Independent of playback.
    case timer
}

// MARK: - Metrics

/// How much grid an element wants, and how it behaves when there is more or
/// less room than that.
///
/// Sizes are expressed in *cells* horizontally and in points vertically. A
/// button is a fixed square whatever the cell width; artwork is square and so
/// its height follows its width; text and progress are a fixed height and
/// absorb whatever width they are given.
public struct ElementMetrics: Sendable {
    /// Fewest columns this element can be drawn in without becoming useless.
    public let minSpan: Int
    /// What it takes when nothing is competing for the room.
    public let preferredSpan: Int
    /// `true` for text and progress, which look right at any width. `false` for
    /// buttons and badges, which have an intrinsic size and should be centred
    /// in their cell rather than stretched across it.
    public let growsHorizontally: Bool
    /// Height in points, given the width it ends up with.
    ///
    /// Square elements pass their width straight through, which is what makes
    /// artwork grow the row it is in. Everything else ignores the argument.
    public let height: @Sendable (_ resolvedWidth: CGFloat) -> CGFloat
    /// Whether a click on this element does something.
    ///
    /// The desktop widget sends itself to the back on a double-click of dead
    /// space, so it needs to know which parts of itself are not dead space.
    /// Getting this wrong makes the widget vanish when you double-click the
    /// scrubber, which reads as a bug rather than a feature.
    public let isInteractive: Bool
    /// `true` when `height` already follows the width it is given, so a surface
    /// scale must NOT be applied on top — the cells have already grown.
    public let growsVertically: Bool

    public init(
        minSpan: Int,
        preferredSpan: Int,
        growsHorizontally: Bool,
        isInteractive: Bool,
        growsVertically: Bool = false,
        height: @escaping @Sendable (CGFloat) -> CGFloat
    ) {
        self.minSpan = minSpan
        self.preferredSpan = preferredSpan
        self.growsHorizontally = growsHorizontally
        self.isInteractive = isInteractive
        self.growsVertically = growsVertically
        self.height = height
    }

    /// Fixed height whatever the width — buttons, text, badges.
    static func fixed(
        _ points: CGFloat,
        minSpan: Int = 1,
        preferredSpan: Int = 1,
        grows: Bool = false,
        interactive: Bool = false
    ) -> ElementMetrics {
        ElementMetrics(
            minSpan: minSpan, preferredSpan: preferredSpan, growsHorizontally: grows,
            isInteractive: interactive, height: { _ in points })
    }

    /// Height follows width — artwork, in either style.
    static func square(minSpan: Int, preferredSpan: Int, interactive: Bool) -> ElementMetrics {
        ElementMetrics(
            minSpan: minSpan, preferredSpan: preferredSpan, growsHorizontally: true,
            isInteractive: interactive, growsVertically: true, height: { $0 })
    }
}

extension PlayerElement {
    /// The numbers here are taken from what the existing surfaces actually draw,
    /// not invented: the vinyl widget's transport row is `width * 0.16`, its
    /// title block `width * 0.17` and its progress bar `width * 0.11`, against a
    /// record of `width * 0.72`. At a 320pt regular card and six columns that
    /// works out at roughly 51 / 54 / 35pt, which is where the fixed heights
    /// below come from. See `VinylWidgetSize.height(width:orientation:…)`.
    public var metrics: ElementMetrics {
        switch self {
        case .artwork:
            return .square(minSpan: 1, preferredSpan: 3, interactive: true)

        case .title:
            return .fixed(20, minSpan: 2, preferredSpan: 3, grows: true)
        case .artist:
            return .fixed(17, minSpan: 2, preferredSpan: 3, grows: true)
        case .album:
            return .fixed(17, minSpan: 2, preferredSpan: 3, grows: true)

        case .playPause:
            // Larger than its neighbours, as it is on every surface today.
            return .fixed(38, interactive: true)
        case .next, .previous, .seekBackward, .seekForward, .shuffle, .repeatMode,
            .outputDevice, .airPlay, .lyrics:
            return .fixed(30, interactive: true)

        case .progressBar:
            return .fixed(16, minSpan: 2, preferredSpan: 6, grows: true, interactive: true)
        case .volumeSlider:
            return .fixed(16, minSpan: 2, preferredSpan: 3, grows: true, interactive: true)

        // grows: true, and it matters. A non-growing element is centred at its
        // intrinsic SQUARE size, which is right for a button and wrong for a
        // time readout: "00:00" in a 14x14 box renders as a single ellipsis.
        // That is what the first run of the desktop player actually showed.
        case .timeElapsed, .timeRemaining:
            return .fixed(14, minSpan: 1, preferredSpan: 2, grows: true)
        case .trackTimeToggle:
            // Interactive: clicking it flips elapsed to remaining.
            return .fixed(14, minSpan: 1, preferredSpan: 2, grows: true, interactive: true)

        case .visualizer:
            // minSpan 1, not 2. `visualizerBarCount` defaults to 4, and four
            // thin bars in one column is exactly what the lock-screen panel
            // draws beside the title today. A minSpan of 2 was my own guess and
            // it contradicted the real layout — the defaults harness caught it.
            return .fixed(24, minSpan: 1, preferredSpan: 2, grows: true)

        case .appIcon:
            return .fixed(18)
        case .explicitBadge:
            return .fixed(14)

        case .clock:
            return .fixed(20, minSpan: 1, preferredSpan: 2, grows: true)
        case .timer:
            return .fixed(20, minSpan: 1, preferredSpan: 2, grows: true, interactive: true)
        }
    }

    /// Whether this element needs playback to mean anything.
    ///
    /// `clock` and `timer` do not, which is why they can sit on a surface that
    /// is showing nothing playing without leaving a hole.
    public var requiresPlayback: Bool {
        switch self {
        case .clock, .timer: return false
        default: return true
        }
    }
}

// MARK: - Artwork style

/// Cover or record, and what the record wears.
///
/// This lives on the placement rather than in global settings because the four
/// surfaces are independent: a vinyl on the desktop and a plain cover on the
/// lock screen has to be expressible. Anchor had `vinylShowStylus`,
/// `vinylShowTitle`, `vinylShowProgress` and `vinylProgressStyle` as global
/// booleans that applied everywhere at once.
public struct ArtworkStyle: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case cover
        case vinyl
    }

    public var kind: Kind
    /// The tonearm. Only meaningful for `.vinyl`.
    public var showsStylus: Bool
    /// Progress drawn as a ring around the record rather than as a separate
    /// `progressBar` element. Only meaningful for `.vinyl`.
    ///
    /// A layout may have both this and a `progressBar`; that is the user's
    /// business, and there is a real reason to want it — the ring reads at a
    /// glance and the bar is what you scrub.
    public var showsProgressRing: Bool

    public init(kind: Kind = .vinyl, showsStylus: Bool = true, showsProgressRing: Bool = false) {
        self.kind = kind
        self.showsStylus = showsStylus
        self.showsProgressRing = showsProgressRing
    }

    public static let vinyl = ArtworkStyle()
    public static let cover = ArtworkStyle(kind: .cover, showsStylus: false, showsProgressRing: false)
}
