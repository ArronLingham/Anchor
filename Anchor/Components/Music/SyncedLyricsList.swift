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
import Translation

/// The scrolling lyric sheet, shared by the notch tab and the lock screen's
/// immersive player.
///
/// Both need the same three behaviours — highlight the current line, fade the
/// rest by distance, keep the current line centred as playback moves — and the
/// only real difference between them is type size. Kept in one place so the
/// two cannot drift.
struct SyncedLyricsList: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @ObservedObject private var translator = LyricsTranslator.shared
    @Default(.lyricsTranslationEnabled) private var translationEnabled

    /// Lines handed to the session. The Translation framework insists on being
    /// driven from SwiftUI, so the view owns the session and the manager owns
    /// the results.
    @State private var pendingTranslation: [String] = []
    @State private var translationConfiguration: TranslationSession.Configuration?

    var currentSize: CGFloat = 15
    var otherSize: CGFloat = 13
    var lineSpacing: CGFloat = 10
    var alignment: HorizontalAlignment = .leading

    /// Fill the available height with as many lines as fit and step through them
    /// in place, instead of scrolling a longer sheet.
    ///
    /// The notch is short enough that a scroll view is mostly chrome — a scroll
    /// position to fight, momentum, and a sheet taller than anything visible.
    /// Fitted mode measures the space, shows exactly the lines that fit, and
    /// keeps the current one in the middle of them.
    var fitted: Bool = false

    /// Fixed number of lines in fitted mode. Without it the count is measured
    /// from the available height.
    var fittedCapacity: Int? = nil

    /// How many already-sung lines to keep above the current one. Defaults to
    /// half the window, i.e. centred. A smaller number weights the view toward
    /// what is coming, which is what you want to read.
    var linesBefore: Int? = nil

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
        content
            .onAppear {
                LyricsTranslator.shared.requestTranslation = { lines in
                    Task { @MainActor in
                        pendingTranslation = lines
                        // A fresh configuration is what re-triggers the task;
                        // mutating the existing one does not.
                        translationConfiguration = TranslationSession.Configuration(
                            source: nil, target: Locale.current.language)
                    }
                }
            }
            .translationTask(translationConfiguration) { session in
                guard !pendingTranslation.isEmpty else { return }
                do {
                    let requests = pendingTranslation.map {
                        TranslationSession.Request(sourceText: $0)
                    }
                    var pairs: [(source: String, target: String)] = []
                    for try await response in session.translate(batch: requests) {
                        pairs.append((response.sourceText, response.targetText))
                    }
                    await MainActor.run { LyricsTranslator.shared.apply(pairs) }
                } catch {
                    // Most often the language pair is unavailable or the model
                    // has not been downloaded. Lyrics keep working untranslated.
                    await MainActor.run { LyricsTranslator.shared.failed() }
                }
            }
    }

    @ViewBuilder
    private var content: some View {
        if isUnsynced {
            untimed
        } else if fitted {
            fittedTimed
        } else {
            timed
        }
    }

    /// No scroll view: measure, take the lines that fit, centre the current one.
    private var fittedTimed: some View {
        GeometryReader { geo in
            let rowHeight = currentSize + lineSpacing
            // A fixed line count when the user has asked for one, clamped to
            // what actually fits — asking for ten lines in a space that holds
            // four would just crop them.
            let fits = fittedCapacity ?? max(1, Int(geo.size.height / rowHeight))
            let preferred = Defaults[.lyricsVisibleLines]
            let capacity = preferred > 0 ? min(preferred, fits) : fits
            let window = windowedLines(capacity: capacity, before: linesBefore ?? capacity / 2)

            VStack(alignment: alignment, spacing: lineSpacing) {
                ForEach(window, id: \.index) { entry in
                    lineView(index: entry.index, line: entry.line)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            .animation(.easeInOut(duration: 0.3), value: musicManager.currentLyricIndex)
        }
    }

    /// The slice of lines to show, holding the current line as near the middle
    /// as it can while still filling the space at the start and end of a track.
    private func windowedLines(capacity: Int, before: Int) -> [(index: Int, line: LyricLine)] {
        let lines = musicManager.syncedLyrics
        guard !lines.isEmpty else { return [] }

        let current = max(0, musicManager.currentLyricIndex)
        // Clamped rather than offset blindly: near either end, holding the
        // current line at a fixed row would leave blank space while there are
        // still lines to show.
        let start = min(max(0, current - before), max(0, lines.count - capacity))
        let end = min(lines.count, start + capacity)
        return (start..<end).map { (index: $0, line: lines[$0]) }
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
            .overlay(alignment: .bottomLeading) {
                // Only under the current line: a translation under every line
                // doubles the height of the sheet and buries the thing you are
                // actually reading.
                if isCurrent, let translated = translator.translations[line.text] {
                    Text(translated)
                        .font(.system(size: otherSize * 0.85))
                        .foregroundStyle(.white.opacity(0.55))
                        .fixedSize(horizontal: false, vertical: true)
                        .offset(y: otherSize * 1.35)
                        .transition(.opacity)
                }
            }
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
