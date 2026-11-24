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
import AnchorUtilities
import Defaults
import SwiftUI

/// Cadence playback controls and metadata for Anchor's Launchpad widget shelf.
struct LauncherPlayerWidget: View {
    enum Size: String, Codable, CaseIterable, Defaults.Serializable {
        case compact, regular, wide

        var width: CGFloat {
            switch self {
            case .compact: return 150
            case .regular: return 220
            case .wide: return 300
            }
        }

        var profileValue: Int {
            switch self {
            case .compact: return 0
            case .regular: return 1
            case .wide: return 2
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
    var isPageActive = true
    /// Tapping the card. At integration this opens the desktop player; it is
    /// injected so the widget has no opinion about who hosts it.
    var onOpen: () -> Void = {}

    @Default(.playerLayouts) private var layouts
    @Default(.launcherAlwaysShowsControls) private var alwaysShowsControls
    @State private var isHovering = false
    @State private var isVisible = false

    var body: some View {
        let layout = layouts.launcher
        LauncherPlayerSizing(layout: layout, width: size.width, showsControls: showsControls) {
            if isPageActive && isVisible {
                LauncherPlayerContent(layout: layout, showsControls: showsControls)
            } else {
                Color.clear
            }
        }
        .background(AnchorSurface(radius: 16))
        .anchorCornerContainer(radius: 16)
        .overlay(
            AnchorCorners.rectangle(cornerRadius: 16)
                .anchorStrokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
        )
        .contentShape(AnchorCorners.rectangle(cornerRadius: 16))
        .onScrollVisibilityChange(threshold: 0.01) { isVisible = $0 }
        .onHover { isHovering = $0 }
        .onChange(of: isPageActive) { _, active in
            if !active { isHovering = false }
        }
        .onTapGesture(perform: onOpen)
        .animation(.easeInOut(duration: 0.16), value: showsControls)
    }

    /// "Always visible, or only on hover" is the user's choice, and it is
    /// expressed by solving the hover set unconditionally rather than by a
    /// second layout. The transport in the launcher default is marked
    /// `.onHover`; forcing `hovering: true` reveals it permanently.
    private var showsControls: Bool { alwaysShowsControls || isHovering }
}

private struct LauncherPlayerContent: View {
    let layout: SurfaceLayout
    let showsControls: Bool

    @Default(.sliderColor) private var sliderColour
    @Default(.accentColor) private var accentColour
    @ObservedObject private var music = MusicManager.shared

    var body: some View {
        PlayerSurfaceView(
            layout: layout,
            style: .forSurface(
                .launcher, albumColor: music.avgColor, tinted: false,
                scale: layout.geometry.contentScale,
                sliderColor: sliderColour, accentColor: accentColour
            ),
            hovering: showsControls
        )
    }
}

/// The grid's intrinsic height depends on the width available to the shelf.
private struct LauncherPlayerSizing: Layout {
    var layout: SurfaceLayout
    var width: CGFloat
    var showsControls: Bool

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let cardWidth = min(proposal.width ?? width, width)
        let height = GridSolver.intrinsicHeight(layout: layout, width: cardWidth, hovering: showsControls)
        return CGSize(width: cardWidth, height: max(96, height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}
