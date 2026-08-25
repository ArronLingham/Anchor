/*
 * Atoll (DynamicIsland)
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

    /// LRCLIB often has only a plain version of a track. Those lyrics are worth
    /// reading, but nothing about them is timed: there is no current line to
    /// highlight and no position to seek to.
    ///
    /// Derived from the lines themselves rather than read off
    /// `MusicManager.lyricsAreSynced`, which is only set on the fetch path — so
    /// anything that installs lyrics directly, the snapshot harness included,
    /// would otherwise be rendered as untimed no matter what its stamps say.
    /// Same rule `applyLyricsToDisplay` uses.
    private var isUnsynced: Bool {
        !musicManager.syncedLyrics.contains { $0.timestamp > 0 }
    }

    /// Live streams have no meaningful position to seek to.
    private var canSeek: Bool { !isUnsynced && !musicManager.isLiveStream }

    var body: some View {
        Group {
            if !enableLyrics {
                message("Lyrics are off", detail: "Turn them on in Settings › Media.")
            } else if musicManager.syncedLyrics.isEmpty {
                message(
                    musicManager.isPlayerIdle ? "Nothing playing" : "No lyrics found",
                    detail: musicManager.isPlayerIdle
                        ? "Start a track to see its lyrics."
                        : "LRCLIB has nothing for this track.")
            } else if isUnsynced {
                unsyncedList
            } else {
                lyricsList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var lyricsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(musicManager.syncedLyrics.enumerated()), id: \.element.id) { index, line in
                        lineView(index: index, line: line)
                            .id(index)
                    }
                }
                .padding(.horizontal, 4)
                // Half a screen of slack top and bottom so the first and last
                // lines can still settle in the middle when centred.
                .padding(.vertical, 60)
            }
            .onAppear { scroll(proxy, to: musicManager.currentLyricIndex, animated: false) }
            .onChange(of: musicManager.currentLyricIndex) { _, index in
                scroll(proxy, to: index, animated: true)
            }
        }
    }

    /// Untimed lyrics: a plain readable sheet. No highlight, because nothing is
    /// current, and no tap-to-seek, because every line is stamped 0 and tapping
    /// would jump to the start of the track.
    private var unsyncedList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Timing unavailable for this track")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 2)

                ForEach(musicManager.syncedLyrics) { line in
                    Text(line.text)
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func lineView(index: Int, line: LyricLine) -> some View {
        let distance = abs(index - musicManager.currentLyricIndex)
        let isCurrent = index == musicManager.currentLyricIndex

        Text(line.text)
            .font(.system(size: isCurrent ? 15 : 13, weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(.white.opacity(opacity(forDistance: distance, isCurrent: isCurrent)))
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canSeek else { return }
                musicManager.seek(to: line.timestamp)
            }
            .animation(.easeInOut(duration: 0.28), value: isCurrent)
    }

    /// Fades with distance from the current line so the eye lands on it without
    /// the surrounding lines disappearing.
    private func opacity(forDistance distance: Int, isCurrent: Bool) -> Double {
        if isCurrent { return 1 }
        // Before the first line has been reached, nothing is "current" and the
        // whole thing would otherwise render at the dimmest step.
        if musicManager.currentLyricIndex < 0 { return 0.55 }
        switch distance {
        case 1: return 0.5
        case 2: return 0.34
        default: return 0.22
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, to index: Int, animated: Bool) {
        guard index >= 0, index < musicManager.syncedLyrics.count else { return }
        if animated {
            withAnimation(.easeInOut(duration: 0.35)) {
                proxy.scrollTo(index, anchor: .center)
            }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
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
