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
import Foundation

/// A typed abbreviation and what it expands to.
struct TextSnippet: Codable, Identifiable, Equatable, Defaults.Serializable, Sendable {
    var id: UUID = UUID()
    /// What the user types, e.g. `;addr`.
    var trigger: String
    /// What replaces it. May contain placeholders — see `expanded()`.
    var expansion: String
    /// Expand as soon as the trigger is typed, rather than waiting for a
    /// following space or punctuation.
    var expandImmediately: Bool = false

    /// The placeholders a snippet may contain.
    ///
    /// Deliberately a tiny fixed set. A full template language would be a
    /// second thing to learn and a second thing to get wrong; these three cover
    /// what an abbreviation actually needs.
    enum Placeholder: String, CaseIterable {
        case clipboard = "{clipboard}"
        case date = "{date}"
        case time = "{time}"

        var explanation: String {
            switch self {
            case .clipboard: return "Whatever is on the clipboard"
            case .date: return "Today's date, e.g. 31 August 2026"
            case .time: return "The current time, e.g. 17:42"
            }
        }
    }

    /// The expansion with placeholders filled in.
    ///
    /// `clipboardText` is passed in rather than read here so this stays pure
    /// and testable — reading `NSPasteboard` would drag AppKit into a harness
    /// that otherwise needs only Foundation.
    func expanded(now: Date, clipboardText: String?, locale: Locale = .current) -> String {
        var result = expansion

        if result.contains(Placeholder.clipboard.rawValue) {
            result = result.replacingOccurrences(
                of: Placeholder.clipboard.rawValue, with: clipboardText ?? "")
        }
        if result.contains(Placeholder.date.rawValue) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .long
            formatter.timeStyle = .none
            result = result.replacingOccurrences(
                of: Placeholder.date.rawValue, with: formatter.string(from: now))
        }
        if result.contains(Placeholder.time.rawValue) {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.dateStyle = .none
            formatter.timeStyle = .short
            result = result.replacingOccurrences(
                of: Placeholder.time.rawValue, with: formatter.string(from: now))
        }
        return result
    }

    /// Whether this snippet is usable. A blank trigger would match constantly;
    /// a blank expansion would silently delete what the user typed.
    var isValid: Bool {
        !trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !expansion.isEmpty
    }
}

/// Finds which snippet, if any, the user has just finished typing.
///
/// Pure and separated from the event tap so it can be tested without
/// synthesising keystrokes.
enum SnippetMatcher {
    /// Characters that end a word, and so commit a non-immediate snippet.
    static let terminators: Set<Character> = [
        " ", "\t", "\n", ".", ",", ";", ":", "!", "?", ")", "]", "}", "\"", "'",
    ]

    struct Match: Equatable {
        let snippet: TextSnippet
        /// How many characters to delete before inserting the expansion —
        /// the trigger, plus the terminator when one committed it.
        let charactersToDelete: Int
    }

    /// Given the recently typed characters, returns the snippet to fire.
    ///
    /// `buffer` is the tail of what the user has typed, oldest first. Matching
    /// runs newest-first and takes the **longest** trigger, so `;addr` wins
    /// over `;a` when both exist — otherwise the shorter one would always fire
    /// and the longer could never be typed.
    static func match(buffer: String, snippets: [TextSnippet]) -> Match? {
        guard !buffer.isEmpty else { return nil }

        let valid = snippets.filter(\.isValid)
        guard !valid.isEmpty else { return nil }

        // Longest trigger first.
        let ordered = valid.sorted { $0.trigger.count > $1.trigger.count }

        // Case A: the buffer ends with a terminator, so a non-immediate
        // snippet whose trigger sits just before it commits now.
        if let last = buffer.last, terminators.contains(last) {
            let withoutTerminator = String(buffer.dropLast())
            for snippet in ordered where !snippet.expandImmediately {
                if withoutTerminator.hasSuffix(snippet.trigger) {
                    return Match(
                        snippet: snippet,
                        charactersToDelete: snippet.trigger.count + 1)
                }
            }
            return nil
        }

        // Case B: an immediate snippet fires the moment its trigger completes.
        for snippet in ordered where snippet.expandImmediately {
            if buffer.hasSuffix(snippet.trigger) {
                return Match(snippet: snippet, charactersToDelete: snippet.trigger.count)
            }
        }
        return nil
    }
}
