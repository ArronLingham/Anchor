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

import AppKit
import Defaults
import SwiftUI

/// The now-playing card for Anchor's Option+Space launcher.
///
/// **Not reachable inside Cadence**, which has no launcher. It is built now,
/// against the same engine as everything else, so that wiring it up at Anchor
/// integration is a matter of placing this view in `LauncherWidgetStrip` rather
/// than writing a fifth player.
///
/// It replaces `LauncherVinylWidget`, which draws a static 38pt circle that does
/// not spin and carries no transport. Anchor's reason for that is recorded and
/// was good: the launcher dismisses on tap, so a button you press vanishes
/// before it does anything. Cadence's card **opens the desktop player** instead
/// of dismissing, which is what makes transport worth having.
struct LauncherPlayerWidget: View {
    /// Anchor's `WidgetCard` is `minWidth: 108, minHeight: 62`. These are the
    /// sizes that fit its strip without reflowing it.
    enum Size: String, Codable, CaseIterable, Defaults.Serializable {
        case compact, regular, wide

        var width: CGFloat {
            switch self {
            case .compact: return 150
            case .regular: return 220
            case .wide: return 300
            }
        }

        var label: String {
            switch self {
            case .compact: return String(localized: "Compact")
            case .regular: return String(localized: "Regular")
            case .wide: return String(localized: "Wide")
            }
        }
    }

    /// Defaults to the stored preference rather than a hardcoded `.regular`.
    /// It was the latter while `launcherWidgetSize` existed and was documented
    /// as being read — a dead key whose own comment claimed otherwise.
    var size: Size = Defaults[.launcherWidgetSize]
    /// Tapping the card. At integration this opens the desktop player; it is
    /// injected so the widget has no opinion about who hosts it.
    var onOpen: () -> Void = {}

    @Default(.playerLayouts) private var layouts
    @Default(.launcherAlwaysShowsControls) private var alwaysShowsControls
    @Default(.sliderColor) private var sliderColour
    @Default(.accentColor) private var accentColour
    @ObservedObject private var music = MusicManager.shared

    @State private var isHovering = false

    var body: some View {
        let layout = layouts.launcher
        let height = GridSolver.intrinsicHeight(
            layout: layout, width: size.width, hovering: showsControls)

        PlayerSurfaceView(
            layout: layout,
            style: .forSurface(
                .launcher, albumColor: music.avgColor, tinted: false,
                scale: layout.geometry.contentScale,
                sliderColor: sliderColour, accentColor: accentColour),
            hovering: showsControls
        )
        .frame(width: size.width, height: height)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .onHover { isHovering = $0 }
        .onTapGesture(perform: onOpen)
        .animation(.easeInOut(duration: 0.16), value: showsControls)
    }

    /// "Always visible, or only on hover" is the user's choice, and it is
    /// expressed by solving the hover set unconditionally rather than by a
    /// second layout. The transport in the launcher default is marked
    /// `.onHover`; forcing `hovering: true` reveals it permanently.
    private var showsControls: Bool { alwaysShowsControls || isHovering }
}
