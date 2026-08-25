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

import Defaults
import SwiftUI

/// The lock screen's full now-playing view: the artwork blown up, the same
/// artwork blurred behind it, lyrics alongside when the track has them, and the
/// transport along the bottom.
///
/// Reached by tapping the artwork on the lock screen panel.
struct LockScreenImmersivePlayer: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.enableLyrics) private var enableLyrics

    /// Called when the view should close — tapping outside the artwork, or Escape.
    var onDismiss: () -> Void = {}

    private var hasLyrics: Bool { enableLyrics && !musicManager.syncedLyrics.isEmpty }

    var body: some View {
        GeometryReader { geo in
            // Artwork is square and sized off height, leaving the remaining
            // width for lyrics. Without lyrics it centres instead of sitting
            // off to one side.
            let contentHeight = geo.size.height * 0.62
            let artSide = min(contentHeight, hasLyrics ? geo.size.width * 0.42 : geo.size.width * 0.6)

            ZStack {
                background(size: geo.size)

                VStack(spacing: 0) {
                    Spacer(minLength: 0)

                    HStack(alignment: .center, spacing: hasLyrics ? geo.size.width * 0.05 : 0) {
                        artwork(side: artSide)

                        if hasLyrics {
                            // Five lines, one already sung and three ahead: at
                            // this size the sheet is for reading along, so the
                            // room goes to what is coming rather than to what
                            // has gone. No fade mask — nothing scrolls past an
                            // edge to soften.
                            SyncedLyricsList(
                                currentSize: 34,
                                otherSize: 25,
                                lineSpacing: 22,
                                fitted: true,
                                fittedCapacity: 5,
                                linesBefore: 1
                            )
                            .frame(maxWidth: .infinity)
                            .frame(height: artSide)
                        }
                    }
                    .padding(.horizontal, geo.size.width * 0.07)

                    Spacer(minLength: 0)

                    transport(width: geo.size.width)
                        .padding(.horizontal, geo.size.width * 0.07)
                        .padding(.bottom, geo.size.height * 0.07)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { onDismiss() }
        }
    }

    // MARK: - Background

    /// The artwork again, filled to the whole area and blurred. `scaledToFill`
    /// on a square image in a landscape frame crops the top and bottom rather
    /// than letterboxing, which is what makes it read as a wash of the track's
    /// colour rather than a picture.
    private func background(size: CGSize) -> some View {
        ZStack {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .scaledToFill()
                // Rendered tiny and then scaled back up, so the blur has almost
                // no detail left to preserve. Blurring the full-resolution cover
                // directly leaves it plainly readable — faces, lettering and
                // edges all survive a large radius — and it competes with the
                // lyrics sitting on top of it.
                .frame(width: size.width / 14, height: size.height / 14)
                .blur(radius: 26, opaque: true)
                .scaleEffect(14)
                .frame(width: size.width, height: size.height)
                .saturation(1.7)

            // Flat scrim for overall contrast, then a heavier wash toward the
            // bottom where the title and transport sit.
            Color.black.opacity(0.62)
            LinearGradient(
                colors: [.black.opacity(0.2), .black.opacity(0.85)],
                startPoint: .center, endPoint: .bottom)
        }
        .clipped()
        .ignoresSafeArea()
    }

    // MARK: - Artwork

    private func artwork(side: CGFloat) -> some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.045, style: .continuous))
            // A dark sleeve on a blurred version of itself has no visible edge —
            // the cover dissolves into the backdrop and reads as a hole rather
            // than as artwork. The hairline gives it one, and the shadow lifts
            // it off the background.
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.045, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.7), radius: 40, y: 18)
            .scaleEffect(musicManager.isPlaying ? 1 : 0.94)
            .animation(.easeInOut(duration: 0.25), value: musicManager.isPlaying)
            // Taps on the artwork must not fall through to the dismiss gesture
            // on the backdrop.
            .onTapGesture {}
    }

    // MARK: - Transport

    private func transport(width: CGFloat) -> some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(musicManager.songTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(musicManager.artistName)
                    .font(.system(size: 16))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            HStack(spacing: 34) {
                transportButton("backward.fill", size: 26) { musicManager.previousTrack() }
                transportButton(musicManager.isPlaying ? "pause.fill" : "play.fill", size: 34) {
                    musicManager.togglePlay()
                }
                transportButton("forward.fill", size: 26) { musicManager.nextTrack() }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func transportButton(_ icon: String, size: CGFloat, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: size * 1.8, height: size * 1.8)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
