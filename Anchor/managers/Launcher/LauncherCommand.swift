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

import AppKit
import Foundation

/// A launcher result that runs something instead of opening an app.
///
/// Anchor has no Dock icon, so its own settings are otherwise only reachable
/// through the menu bar — being able to type "settings" is the difference
/// between the app being configurable and the settings being a thing you have
/// to go hunting for.
struct LauncherCommand: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
    /// Extra terms that should match this command beyond its title.
    let keywords: [String]
    let run: @MainActor () -> Void

    @MainActor
    static let all: [LauncherCommand] = [
        LauncherCommand(
            id: "anchor.settings",
            title: "Anchor Settings",
            subtitle: "Notch, dictation, launcher and more",
            symbolName: "gearshape",
            keywords: ["settings", "preferences", "options", "config", "anchor", "atoll"]
        ) {
            SettingsWindowController.shared.showWindow()
        },
        LauncherCommand(
            id: "anchor.rebuildIndex",
            title: "Rebuild App Index",
            subtitle: "Rescan for newly installed applications",
            symbolName: "arrow.clockwise",
            keywords: ["reindex", "rescan", "refresh", "missing", "index"]
        ) {
            AppIndex.shared.refresh()
        },
    ]

    /// Commands matching `query`, best first. Matched against the title and
    /// every keyword, keeping whichever scores highest.
    @MainActor
    static func search(_ query: String) -> [ScoredCommand] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }

        var results: [ScoredCommand] = []
        for command in all {
            var best: FuzzyMatcher.Match?
            for candidate in [command.title] + command.keywords {
                guard let match = FuzzyMatcher.match(query: trimmed, candidate: candidate) else {
                    continue
                }
                if best == nil || match.score > best!.score { best = match }
            }
            guard let best else { continue }
            // Only the title is highlighted, so indices from a keyword match
            // would point at the wrong characters.
            let titleMatch = FuzzyMatcher.match(query: trimmed, candidate: command.title)
            results.append(
                ScoredCommand(
                    command: command,
                    score: best.score,
                    matchedIndices: titleMatch?.matchedIndices ?? []))
        }
        return results.sorted { $0.score > $1.score }
    }

    struct ScoredCommand: Identifiable {
        let command: LauncherCommand
        let score: Int
        let matchedIndices: [Int]
        var id: String { command.id }
    }
}
