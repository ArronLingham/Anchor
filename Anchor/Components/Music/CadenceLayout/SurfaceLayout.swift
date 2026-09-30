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
import Defaults
import Foundation

// Pure by design — no SwiftUI, no Defaults. See the note in PlayerElement.swift.

/// The four places a player is drawn.
///
/// They share the playback core and this layout engine, and **nothing else**.
/// A change to one surface's layout must never move an element on another. This
/// is the requirement most likely to get broken by a convenient shortcut,
/// because the code Cadence was extracted from does the opposite: Anchor keeps
/// one global `musicControlSlots` array that every surface reads.
public enum PlayerSurface: String, CaseIterable, Codable, Sendable {
    /// The free-floating desktop widget. Mouse-resizable, hover-reveals,
    /// sends itself to the back on a double-click of dead space.
    case desktop
    /// The small lock-screen widget.
    case lockWidget
    /// The lock-screen full-screen player.
    case lockFull
    /// The desktop player's own full-screen view, opened by clicking its
    /// artwork. A fifth surface with its own layout — sharing `lockFull`'s
    /// would violate the rule these surfaces exist to enforce.
    case desktopFull
    /// The now-playing card in Anchor's launcher. Built here, wired up at
    /// Anchor integration — Cadence has no launcher of its own.
    case launcher

    public var displayName: String {
        switch self {
        case .desktop: return String(localized: "Desktop player")
        case .lockWidget: return String(localized: "Lock screen widget")
        case .lockFull: return String(localized: "Lock screen full screen")
        case .desktopFull: return String(localized: "Desktop full screen")
        case .launcher: return String(localized: "Launcher widget")
        }
    }
}

/// Whether an element is always drawn, or only while the pointer is over the
/// surface.
public enum ElementVisibility: String, Codable, Sendable {
    case always
    case onHover
}

/// Whether an element sits in the grid or on top of what is already there.
///
/// This distinction is what makes the hover requirement work. Two `base`
/// elements may not share a cell. An `overlay` may sit on a base one, adds no
/// height, and therefore causes no growth — so a hover-only play button placed
/// over the artwork reveals without resizing the window, while a hover-only
/// progress bar placed as `base` on its own row makes the window taller.
public enum ElementLayer: String, Codable, Sendable {
    case base
    case overlay
}

/// One element, somewhere on one surface.
public struct ElementPlacement: Codable, Hashable, Identifiable, Sendable {
    /// Stable across edits so SwiftUI keeps hold of a cell mid-drag, and so the
    /// same element may legitimately appear twice on a surface (two clocks, or
    /// a progress ring on the artwork *and* a scrubbing bar below it).
    public var id: UUID

    public var element: PlayerElement
    public var col: Int
    public var row: Int
    public var colSpan: Int

    /// How many grid rows this placement occupies.
    ///
    /// Added because the full-screen player has to put lyrics beside a stack of
    /// artwork and transport, and a one-row element cannot do that. `rowSpan`
    /// was described in this project's own notes for a long time before any
    /// code implemented it — it existed only in comments.
    public var rowSpan: Int
    public var layer: ElementLayer
    public var visibility: ElementVisibility

    /// Drop order when there is not enough room. `0` is never dropped; higher
    /// values go first. One ordering the user maintains once, rather than a
    /// separate layout per size.
    public var priority: Int

    /// Only read for `.artwork`. Ignored elsewhere.
    public var artworkStyle: ArtworkStyle

    public init(
        id: UUID = UUID(),
        element: PlayerElement,
        col: Int,
        row: Int,
        colSpan: Int = 1,
        rowSpan: Int = 1,
        layer: ElementLayer = .base,
        visibility: ElementVisibility = .always,
        priority: Int = 0,
        artworkStyle: ArtworkStyle = .vinyl
    ) {
        self.id = id
        self.element = element
        self.col = col
        self.row = row
        self.colSpan = colSpan
        self.rowSpan = max(1, rowSpan)
        self.layer = layer
        self.visibility = visibility
        self.priority = priority
        self.artworkStyle = artworkStyle
    }

    /// Columns this placement occupies, as a half-open range.
    public var columns: Range<Int> { col..<(col + colSpan) }

    /// Rows this placement occupies, as a half-open range. `rowSpan` is clamped
    /// to at least 1 on the way in, so this is never empty.
    public var rows: Range<Int> { row..<(row + max(1, rowSpan)) }

    /// Decoding tolerates a placement written by a future version that has since
    /// gained fields, and an `id` that predates it being stored.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        element = try c.decode(PlayerElement.self, forKey: .element)
        col = try c.decode(Int.self, forKey: .col)
        row = try c.decode(Int.self, forKey: .row)
        colSpan = try c.decodeIfPresent(Int.self, forKey: .colSpan) ?? 1
        // Absent in every layout written before row spanning existed, which is
        // all of them — so a missing value must mean 1, not a decode failure.
        rowSpan = max(1, try c.decodeIfPresent(Int.self, forKey: .rowSpan) ?? 1)
        layer = try c.decodeIfPresent(ElementLayer.self, forKey: .layer) ?? .base
        visibility = try c.decodeIfPresent(ElementVisibility.self, forKey: .visibility) ?? .always
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
        artworkStyle = try c.decodeIfPresent(ArtworkStyle.self, forKey: .artworkStyle) ?? .vinyl
    }
}

/// The grid geometry a surface is laid out in.
public struct GridGeometry: Codable, Hashable, Sendable {
    /// Fixed per surface. The widget never grows horizontally, so this does not
    /// change with size.
    public var columns: Int
    public var padding: CGFloat
    public var gutter: CGFloat

    /// Multiplies BOTH font sizes and row heights.
    ///
    /// It has to do both. A first version scaled only the fonts, from a
    /// per-surface constant in `SurfaceStyle`, and the full-screen lock player
    /// rendered a 24pt title inside a 20pt row — visibly clipped. Row height
    /// comes from `ElementMetrics`, so anything that changes how large an
    /// element draws has to reach the metrics too, and one number is the only
    /// way to keep them from drifting apart.
    public var contentScale: CGFloat

    /// Centre each row horizontally, and the whole arrangement vertically, in
    /// whatever room the surface has.
    ///
    /// This is what makes "turn lyrics off and the album cover goes front and
    /// centre" work. The full-screen player's default puts the artwork in the
    /// left six columns and the lyrics in the right six; delete the lyrics
    /// placement and the artwork is alone in its row, so centring puts it in
    /// the middle of the screen with no second layout to maintain.
    ///
    /// Off for the desktop card, where the user positions things against a
    /// frame they sized themselves and drift would be surprising.
    public var centersContent: Bool

    public init(
        columns: Int, padding: CGFloat = 14, gutter: CGFloat = 8, contentScale: CGFloat = 1,
        centersContent: Bool = false
    ) {
        self.columns = columns
        self.padding = padding
        self.gutter = gutter
        self.contentScale = contentScale
        self.centersContent = centersContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        columns = try c.decode(Int.self, forKey: .columns)
        padding = try c.decodeIfPresent(CGFloat.self, forKey: .padding) ?? 14
        gutter = try c.decodeIfPresent(CGFloat.self, forKey: .gutter) ?? 8
        contentScale = try c.decodeIfPresent(CGFloat.self, forKey: .contentScale) ?? 1
        centersContent = try c.decodeIfPresent(Bool.self, forKey: .centersContent) ?? false
    }
}

/// One surface's saved arrangement.
public struct SurfaceLayout: Codable, Hashable, Sendable {
    public var geometry: GridGeometry
    public var placements: [ElementPlacement]

    public init(geometry: GridGeometry, placements: [ElementPlacement]) {
        self.geometry = geometry
        self.placements = placements
    }
}

/// All four, in one value.
///
/// One `Defaults` key holding this rather than four keys: one atomic write, one
/// migration, and it is structurally impossible for two surfaces to end up
/// sharing a layout by accident.
public struct PlayerLayouts: Codable, Hashable, Sendable {
    public var desktop: SurfaceLayout
    public var lockWidget: SurfaceLayout
    public var lockFull: SurfaceLayout
    public var desktopFull: SurfaceLayout
    public var launcher: SurfaceLayout

    public subscript(surface: PlayerSurface) -> SurfaceLayout {
        get {
            switch surface {
            case .desktop: return desktop
            case .lockWidget: return lockWidget
            case .lockFull: return lockFull
            case .desktopFull: return desktopFull
            case .launcher: return launcher
            }
        }
        set {
            switch surface {
            case .desktop: desktop = newValue
            case .lockWidget: lockWidget = newValue
            case .lockFull: lockFull = newValue
            case .desktopFull: desktopFull = newValue
            case .launcher: launcher = newValue
            }
        }
    }

    /// A surface missing from stored JSON falls back to its default rather than
    /// failing the whole decode — otherwise adding a fifth surface later (the
    /// notch, at Anchor integration) would reset every existing layout.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PlayerLayouts.defaults
        desktop = try c.decodeIfPresent(SurfaceLayout.self, forKey: .desktop) ?? d.desktop
        lockWidget = try c.decodeIfPresent(SurfaceLayout.self, forKey: .lockWidget) ?? d.lockWidget
        lockFull = try c.decodeIfPresent(SurfaceLayout.self, forKey: .lockFull) ?? d.lockFull
        // Absent from every layout stored before this surface existed, which is
        // exactly the case the fallback above was written for.
        desktopFull =
            try c.decodeIfPresent(SurfaceLayout.self, forKey: .desktopFull) ?? d.desktopFull
        launcher = try c.decodeIfPresent(SurfaceLayout.self, forKey: .launcher) ?? d.launcher
    }

    public init(
        desktop: SurfaceLayout, lockWidget: SurfaceLayout,
        lockFull: SurfaceLayout, desktopFull: SurfaceLayout, launcher: SurfaceLayout
    ) {
        self.desktop = desktop
        self.lockWidget = lockWidget
        self.lockFull = lockFull
        self.desktopFull = desktopFull
        self.launcher = launcher
    }
}

extension PlayerLayouts: Defaults.Serializable {}
