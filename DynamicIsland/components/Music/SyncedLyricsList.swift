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

import SwiftUI

/// The scrolling lyric sheet, shared by the notch tab and the lock screen's
/// immersive player.
///
/// Both need the same three behaviours — highlight the current line, fade the
/// rest by distance, keep the current line centred as playback moves — and the
/// only real difference between them is type size. Kept in one place so the
/// two cannot drift.
struct SyncedLyricsList: View {
    @ObservedObject private var musicManager = MusicManager.shared

    var currentSize: CGFloat = 15
    var otherSize: CGFloat = 13
    var lineSpacing: CGFloat = 10
    var alignment: HorizontalAlignment = .leading

    /// LRCLIB often has only a plain version of a track. Those lyrics are worth
    /// reading, but nothing about them is timed: no line is current and there is
    /// no position to seek to.
    ///
    /// Derived from the lines rather than `MusicManager.lyricsAreSynced`, which
    /// is only set on the fetch path — anything installing lyrics directly, the
    /// snapshot harness included, would otherwise render as untimed whatever its
    /// stamps say. Same rule `applyLyricsToDisplay` uses.
    private var isUnsynced: Bool {
        !musicManager.syncedLyrics.contains { $0.timestamp > 0 }
    }

    private var canSeek: Bool { !isUnsynced && !musicManager.isLiveStream }

    var body: some View {
        if isUnsynced {
            untimed
        } else {
            timed
        }
    }

    private var timed: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: alignment, spacing: lineSpacing) {
                    ForEach(Array(musicManager.syncedLyrics.enumerated()), id: \.element.id) { index, line in
                        lineView(index: index, line: line).id(index)
                    }
                }
                .padding(.horizontal, 4)
                // Slack so the first and last lines can still settle centred.
                .padding(.vertical, 60)
            }
            .onAppear { scroll(proxy, to: musicManager.currentLyricIndex, animated: false) }
            .onChange(of: musicManager.currentLyricIndex) { _, index in
                scroll(proxy, to: index, animated: true)
            }
        }
    }

    /// No highlight, because nothing is current, and no tap-to-seek, because
    /// every line is stamped 0 and a tap would jump to the start of the track.
    private var untimed: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: alignment, spacing: lineSpacing * 0.8) {
                Text("Timing unavailable for this track")
                    .font(.system(size: max(10, otherSize - 3), weight: .medium))
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.bottom, 2)

                ForEach(musicManager.syncedLyrics) { line in
                    Text(line.text)
                        .font(.system(size: otherSize))
                        .foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 8)
        }
    }

    @ViewBuilder
    private func lineView(index: Int, line: LyricLine) -> some View {
        let isCurrent = index == musicManager.currentLyricIndex
        let distance = abs(index - musicManager.currentLyricIndex)

        Text(line.text)
            .font(.system(size: isCurrent ? currentSize : otherSize,
                          weight: isCurrent ? .semibold : .regular))
            .foregroundStyle(.white.opacity(opacity(distance: distance, isCurrent: isCurrent)))
            .frame(maxWidth: .infinity, alignment: alignment == .center ? .center : .leading)
            .fixedSize(horizontal: false, vertical: true)
            .contentShape(Rectangle())
            .onTapGesture {
                guard canSeek else { return }
                musicManager.seek(to: line.timestamp)
            }
            .animation(.easeInOut(duration: 0.28), value: isCurrent)
    }

    private func opacity(distance: Int, isCurrent: Bool) -> Double {
        if isCurrent { return 1 }
        // Before the first line is reached nothing is current, and the whole
        // sheet would otherwise render at the dimmest step.
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
            withAnimation(.easeInOut(duration: 0.35)) { proxy.scrollTo(index, anchor: .center) }
        } else {
            proxy.scrollTo(index, anchor: .center)
        }
    }
}
