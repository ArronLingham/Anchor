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
/// Uses Apple's on-device Translation framework.
///
/// Translation is shared by the visible lyric sheets and has no periodic work.
@MainActor
final class LyricsTranslator: ObservableObject {
    static let shared = LyricsTranslator()

    /// Original line text -> translated text.
    @Published private(set) var translations: [String: String] = [:]
    @Published private(set) var isTranslating = false

    private let gate = LyricsLookupGate(enabled: Defaults[.enableLyrics] && Defaults[.lyricsTranslationEnabled])
    private lazy var coordinator = LyricsTranslationCoordinator(gate: gate)
    private var cancellables = Set<AnyCancellable>()
    private var lyricsSubscription: AnyCancellable?
    private var visibleViews = Set<UUID>()

    private init() {
        coordinator.clear = { [weak self] in self?.translations.removeAll() }
        coordinator.setTranslating = { [weak self] value in self?.isTranslating = value }
        observe()
    }

    private func observe() {
        let gate = gate
        Defaults.publisher(.lyricsTranslationEnabled)
            .map { _ in gate.update(enabled: Defaults[.enableLyrics] && Defaults[.lyricsTranslationEnabled]) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        Defaults.publisher(.enableLyrics)
            .map { _ in gate.update(enabled: Defaults[.enableLyrics] && Defaults[.lyricsTranslationEnabled]) }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private var enabled: Bool { Defaults[.enableLyrics] && Defaults[.lyricsTranslationEnabled] }
    private var lines: [String] { MusicManager.shared.syncedLyrics.map(\.text) }

    private func refresh() {
        updateLyricsObservation()
        coordinator.reconcile(enabled: enabled, lines: lines)
    }

    private func updateLyricsObservation() {
        guard enabled, !visibleViews.isEmpty else {
            lyricsSubscription = nil
            gate.cancel()
            return
        }
        guard lyricsSubscription == nil else { return }
        let gate = gate
        lyricsSubscription = MusicManager.shared.$syncedLyrics
            .removeDuplicates { $0.map(\.text) == $1.map(\.text) }
            .map { lines in gate.cancel(); return lines }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.refresh() }
    }

    func register(_ id: UUID, handler: @escaping LyricsTranslationCoordinator.Handler) {
        visibleViews.insert(id)
        updateLyricsObservation()
        coordinator.register(id, handler: handler, enabled: enabled, lines: lines)
    }

    func unregister(_ id: UUID) {
        visibleViews.remove(id)
        coordinator.unregister(id, enabled: enabled, lines: lines)
        updateLyricsObservation()
    }

    func accepts(_ request: LyricsTranslationCoordinator.Request, owner: UUID) -> Bool {
        coordinator.accepts(request, owner: owner, enabled: enabled, lines: lines)
    }

    func apply(_ pairs: [(source: String, target: String)], request: LyricsTranslationCoordinator.Request, owner: UUID) {
        guard coordinator.finish(request, owner: owner, enabled: enabled, lines: lines, success: true) else { return }
        for pair in pairs where pair.source != pair.target {
            translations[pair.source] = pair.target
        }
    }

    func failed(_ request: LyricsTranslationCoordinator.Request, owner: UUID) {
        _ = coordinator.finish(request, owner: owner, enabled: enabled, lines: lines, success: false)
    }
}
