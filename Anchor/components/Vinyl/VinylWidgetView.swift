/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
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

/// Bridges the CALayer record into SwiftUI.
///
/// Only three things cross the boundary — the artwork, whether it is turning,
/// and the label size — so the record never rebuilds its layers for a state
/// change SwiftUI made elsewhere.
struct VinylRecordRepresentable: NSViewRepresentable {
    let artwork: NSImage?
    let isPlaying: Bool
    let labelFraction: CGFloat

    func makeNSView(context: Context) -> VinylRecordView {
        let view = VinylRecordView(frame: .zero)
        view.labelFraction = labelFraction
        view.setArtwork(artwork)
        view.setSpinning(isPlaying)
        return view
    }

    func updateNSView(_ view: VinylRecordView, context: Context) {
        view.labelFraction = labelFraction
        view.setArtwork(artwork)
        view.setSpinning(isPlaying)
    }
}

/// The desktop vinyl widget: record, tonearm, progress and hover controls.
struct VinylWidgetView: View {
    @ObservedObject private var music = MusicManager.shared

    @Default(.vinylShowStylus) private var showStylus
    @Default(.vinylShowProgress) private var showProgress
    @Default(.vinylShowTitle) private var showTitle
    @Default(.vinylUseAlbumColor) private var useAlbumColor
    @Default(.vinylBackgroundOpacity) private var backgroundOpacity

    @State private var isHovering = false

    private var accent: Color {
        useAlbumColor ? Color(nsColor: music.avgColor) : .white
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            let recordSide = side * (showStylus ? 0.82 : 0.92)

            ZStack {
                background

                if showProgress {
                    progressRing(side: recordSide + 10)
                }

                VinylRecordRepresentable(
                    artwork: music.albumArt,
                    isPlaying: music.isPlaying,
                    labelFraction: 0.38)
                .frame(width: recordSide, height: recordSide)

                if showStylus {
                    tonearm(side: side)
                }

                if isHovering {
                    controls
                }

                if showTitle {
                    title(side: side)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .onHover { isHovering = $0 }
        .animation(.easeInOut(duration: 0.18), value: isHovering)
    }

    // MARK: - Pieces

    private var background: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.black.opacity(backgroundOpacity))
    }

    /// Progress drawn as a ring around the record, which is the only place it
    /// can go without covering the artwork.
    private func progressRing(side: CGFloat) -> some View {
        let fraction = music.songDuration > 0
            ? min(max(music.elapsedTime / music.songDuration, 0), 1)
            : 0

        return ZStack {
            Circle()
                .strokeBorder(.white.opacity(0.10), lineWidth: 3)
            Circle()
                .trim(from: 0, to: fraction)
                .stroke(accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: side, height: side)
        // TimelineView is not used here on purpose: elapsedTime is republished
        // by MusicManager as the player reports it, and a ring that advances a
        // few times a second is indistinguishable from one that advances every
        // frame at this size.
    }

    /// The tonearm, swung onto the record while playing and lifted when not.
    private func tonearm(side: CGFloat) -> some View {
        let length = side * 0.42

        return ZStack(alignment: .topTrailing) {
            Color.clear
            ZStack(alignment: .top) {
                // Pivot
                Circle()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.85), .gray],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: side * 0.085, height: side * 0.085)

                // Arm
                Capsule()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.75), .white.opacity(0.35)],
                        startPoint: .top, endPoint: .bottom))
                    .frame(width: max(3, side * 0.018), height: length)
                    .offset(y: side * 0.04)

                // Head
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(.white.opacity(0.9))
                    .frame(width: side * 0.045, height: side * 0.055)
                    .offset(y: side * 0.04 + length - side * 0.02)
            }
            .rotationEffect(
                .degrees(music.isPlaying ? 28 : 6),
                anchor: .top)
            .animation(.spring(response: 0.7, dampingFraction: 0.8), value: music.isPlaying)
            .padding(.top, side * 0.06)
            .padding(.trailing, side * 0.10)
        }
        .allowsHitTesting(false)
    }

    private var controls: some View {
        HStack(spacing: 18) {
            button("backward.fill") { music.previousTrack() }
            button(music.isPlaying ? "pause.fill" : "play.fill") { music.playPause() }
            button("forward.fill") { music.nextTrack() }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            Capsule().fill(.ultraThinMaterial))
        .transition(.opacity.combined(with: .scale(scale: 0.94)))
    }

    private func button(_ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func title(side: CGFloat) -> some View {
        VStack {
            Spacer()
            VStack(spacing: 1) {
                Text(music.songTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(music.artistName)
                    .font(.system(size: 9))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 6)
            .frame(maxWidth: side)
        }
    }
}
