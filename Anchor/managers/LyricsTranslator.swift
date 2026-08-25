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

import Combine
import Defaults
import Foundation
import Translation

/// Translated lyric lines, the last item in category 4.
///
/// On-device through Apple's Translation framework — no key, no network, and no
/// third-party service receiving what the user is listening to.
///
/// Translation happens once per track and is cached by line, so scrolling the
/// sheet costs nothing and a repeated track costs nothing. There is no periodic
/// work here at all: it runs when the lyrics change and is otherwise idle.
@MainActor
final class LyricsTranslator: ObservableObject {
    static let shared = LyricsTranslator()

    /// Original line text -> translated text.
    @Published private(set) var translations: [String: String] = [:]
    @Published private(set) var isTranslating = false

    /// Set by the view that owns the TranslationSession; the framework requires
    /// a session be driven from SwiftUI via `.translationTask`.
    var requestTranslation: (([String]) -> Void)?

    private var lastTranslatedKey: String?
    private var cancellables = Set<AnyCancellable>()

    private init() {
        DispatchQueue.main.async { [weak self] in self?.observe() }
    }

    private func observe() {
        // Re-translate when the lyric set changes, not on a timer.
        MusicManager.shared.$syncedLyrics
            .removeDuplicates { $0.map(\.text) == $1.map(\.text) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in self?.lyricsChanged(lines) }
            .store(in: &cancellables)

        Defaults.publisher(.lyricsTranslationEnabled)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] change in
                guard let self else { return }
                if change.newValue {
                    self.lyricsChanged(MusicManager.shared.syncedLyrics)
                } else {
                    self.reset()
                }
            }
            .store(in: &cancellables)
    }

    private func lyricsChanged(_ lines: [LyricLine]) {
        guard Defaults[.lyricsTranslationEnabled] else { reset(); return }
        let key = lines.map(\.text).joined(separator: "\u{1}")
        guard key != lastTranslatedKey, !lines.isEmpty else { return }
        lastTranslatedKey = key
        translations.removeAll()
        isTranslating = true
        requestTranslation?(lines.map(\.text))
    }

    /// Called back by the view once the session has produced results.
    func apply(_ pairs: [(source: String, target: String)]) {
        for pair in pairs where pair.source != pair.target {
            translations[pair.source] = pair.target
        }
        isTranslating = false
    }

    func failed() {
        isTranslating = false
        // Deliberately not cleared: a partial translation is more useful than
        // none, and a failure here should never blank lyrics that already work.
        lastTranslatedKey = nil
    }

    private func reset() {
        translations.removeAll()
        lastTranslatedKey = nil
        isTranslating = false
    }
}
