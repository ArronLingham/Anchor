/*
 * Anchor / Cadence
 * Copyright (C) 2024-2026 Atoll and Cadence Contributors
 * GPL-3.0-or-later. See the repository LICENSE and NOTICE.
 */

import Defaults
import SwiftUI

/// Uses Cadence's independent lock-screen layout while Anchor continues to
/// own the shielded window, artwork fallback, and unlock lifecycle.
struct CadenceLockFullView: View {
    var onDismiss: () -> Void

    @ObservedObject private var music = MusicManager.shared
    @Default(.playerLayouts) private var layouts
    @Default(.enableLyrics) private var enableLyrics
    @Default(.sliderColor) private var sliderColor
    @Default(.accentColor) private var accentColor
    @Default(.lockFullBackground) private var backgroundStyle

    var body: some View {
        Group {
        ZStack {
            background
                .contentShape(Rectangle())
                .onTapGesture(perform: onDismiss)

            PlayerSurfaceView(
                layout: GridSolver.fullscreenLayout(layouts.lockFull,
                    lyricsVisible: enableLyrics && !music.syncedLyrics.isEmpty),
                style: .forSurface(
                    .lockFull, albumColor: music.avgColor, tinted: false,
                    scale: layouts.lockFull.geometry.contentScale,
                    sliderColor: sliderColor, accentColor: accentColor),
                fullscreen: true,
                onExpand: onDismiss)
                .padding(40)
        }
        .ignoresSafeArea()
        .onExitCommand(perform: onDismiss)
            }
        .anchorTheme()
    }

    @ViewBuilder
    private var background: some View {
        switch backgroundStyle {
        case .blurredArtwork:
            Image(nsImage: music.albumArt)
                .resizable()
                .scaledToFill()
                .blur(radius: 60, opaque: true)
                .overlay(Color.black.opacity(0.50))
        case .albumColour:
            Color(nsColor: SurfaceStyle.muted(music.avgColor))
                .overlay(Color.black.opacity(0.30))
        }
    }
}
