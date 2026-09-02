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

/// The full synced-lyrics tab.
///
/// `MusicManager` already fetched, parsed and time-synced these — it has held
/// `syncedLyrics` and `currentLyricIndex` all along, and every other surface
/// (notch home, lock screen, the fullscreen artwork overlay) renders only
/// `currentLyrics`, the single line for right now. This is the view that shows
/// the rest of them, and lets you tap one to jump there.
struct NotchLyricsView: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.enableLyrics) private var enableLyrics

    private var hasLyrics: Bool { !musicManager.syncedLyrics.isEmpty }

    var body: some View {
        Group {
            if !enableLyrics {
                message("Lyrics are off", detail: "Turn them on in Settings › Media.")
            } else if !hasLyrics {
                message(
                    musicManager.isPlayerIdle ? "Nothing playing" : "No lyrics found",
                    detail: musicManager.isPlayerIdle
                        ? "Start a track to see its lyrics."
                        : "LRCLIB has nothing for this track.")
            } else {
                // Shared with the lock screen's immersive player.
                SyncedLyricsList(currentSize: 15, otherSize: 13, lineSpacing: 10, fitted: true)
                    // Turning lyrics off should not mean a trip to Settings
                    // when they are right there in front of you.
                    .overlay(alignment: .topTrailing) {
                        Button {
                            enableLyrics = false
                        } label: {
                            Image(systemName: "text.badge.xmark")
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(6)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help("Turn lyrics off")
                    }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func message(_ title: String, detail: String) -> some View {
        VStack(spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
