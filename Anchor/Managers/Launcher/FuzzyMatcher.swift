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

import Foundation

/// Subsequence fuzzy matching with the scoring that makes a launcher feel right.
///
/// The behaviour people actually expect, in priority order:
///  - "ter" should find **Ter**minal before iTerm (prefix beats mid-word)
///  - "ss" should find **S**ystem **S**ettings (initials of separate words)
///  - "pht" should find **Ph**o**t**os (consecutive runs beat scattered letters)
enum FuzzyMatcher {
    struct Match {
        let score: Int
        /// Indices in the candidate that were matched, for highlighting.
        let matchedIndices: [Int]
    }

    private enum Score {
        static let consecutive = 15
        static let wordBoundary = 12
        static let camelBoundary = 10
        static let prefix = 20
        static let exact = 100
        static let gapPenalty = -2
        static let unmatchedTrailing = -1
        /// Every matched character landed on a word start — an acronym hit.
        /// Deliberately large: it is the strongest intent signal there is.
        static let acronym = 45
    }

    /// Returns nil when `query` is not a subsequence of `candidate`.
    ///
    /// Uses dynamic programming to find the *best-scoring* alignment, not the
    /// first one. Greedy left-to-right matching gets this wrong in a way users
    /// notice: for "ss" it matches "**s**y**s**tem Settings" and scores it worse
    /// than "Che**ss**", so Chess outranks System Settings. The DP considers the
    /// word-boundary alignment too and picks whichever scores higher.
    static func match(query: String, candidate: String) -> Match? {
        guard !query.isEmpty else { return Match(score: 0, matchedIndices: []) }

        let queryChars = Array(query.lowercased())
        let candidateChars = Array(candidate)
        let lowerCandidate = Array(candidate.lowercased())
        let queryCount = queryChars.count
        let candidateCount = candidateChars.count
        guard queryCount <= candidateCount else { return nil }

        // dp[j] = best score for matching the first (i+1) query characters with
        // query[i] landing on candidate[j]. `parent` stores where query[i-1]
        // matched, so the indices can be reconstructed afterwards.
        let unreachable = Int.min / 4
        var previousRow = [Int](repeating: unreachable, count: candidateCount)
        var currentRow = [Int](repeating: unreachable, count: candidateCount)
        var parents = [[Int]](
            repeating: [Int](repeating: -1, count: candidateCount), count: queryCount)

        for i in 0..<queryCount {
            // running[j] is the best value of previousRow[k] for k <= j, already
            // discounted by the gap between k and j. Keeping it as a running
            // maximum is what makes this linear rather than quadratic.
            var runningBest = unreachable
            var runningBestIndex = -1

            for j in 0..<candidateCount {
                if j > 0 {
                    let carried = runningBest == unreachable ? unreachable : runningBest + Score.gapPenalty
                    let candidatePrev = previousRow[j - 1]
                    if candidatePrev >= carried {
                        runningBest = candidatePrev
                        runningBestIndex = j - 1
                    } else {
                        runningBest = carried
                    }
                }

                guard lowerCandidate[j] == queryChars[i] else {
                    currentRow[j] = unreachable
                    continue
                }

                var bonus = 0
                if j == 0 {
                    bonus += Score.prefix
                } else if isWordBoundary(candidateChars, at: j) {
                    bonus += Score.wordBoundary
                } else if isCamelBoundary(candidateChars, at: j) {
                    bonus += Score.camelBoundary
                }

                if i == 0 {
                    currentRow[j] = bonus
                    parents[i][j] = -1
                    continue
                }

                // Option A: continue a run — query[i-1] matched at j-1.
                let consecutive =
                    (j > 0 && previousRow[j - 1] != unreachable)
                    ? previousRow[j - 1] + Score.consecutive : unreachable
                // Option B: jump a gap from the best earlier match.
                let gapped = runningBest == unreachable ? unreachable : runningBest

                if consecutive == unreachable && gapped == unreachable {
                    currentRow[j] = unreachable
                    continue
                }
                if consecutive >= gapped {
                    currentRow[j] = consecutive + bonus
                    parents[i][j] = j - 1
                } else {
                    currentRow[j] = gapped + bonus
                    parents[i][j] = runningBestIndex
                }
            }

            swap(&previousRow, &currentRow)
        }

        // previousRow now holds the final query character's row.
        var bestScore = unreachable
        var bestEnd = -1
        for j in 0..<candidateCount where previousRow[j] > bestScore {
            bestScore = previousRow[j]
            bestEnd = j
        }
        guard bestEnd >= 0, bestScore > unreachable else { return nil }

        var matched = [Int](repeating: 0, count: queryCount)
        var cursor = bestEnd
        for i in stride(from: queryCount - 1, through: 0, by: -1) {
            matched[i] = cursor
            cursor = parents[i][cursor]
            if cursor < 0 && i > 0 { return nil }
        }

        var score = bestScore
        if candidate.lowercased() == query.lowercased() {
            score += Score.exact
        }
        // Acronym hit: every matched character is the start of a word.
        if queryCount > 1,
            matched.allSatisfy({ $0 == 0 || isWordBoundary(candidateChars, at: $0) })
        {
            score += Score.acronym
        }
        // Prefer shorter names when scores are otherwise close: "Mail" over
        // "Mailbox Cleaner" for the query "mail".
        score += (candidateCount - queryCount) * Score.unmatchedTrailing

        return Match(score: score, matchedIndices: matched)
    }

    private static func isWordBoundary(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = chars[index - 1]
        return previous == " " || previous == "-" || previous == "_" || previous == "."
    }

    private static func isCamelBoundary(_ chars: [Character], at index: Int) -> Bool {
        guard index > 0 else { return false }
        return chars[index - 1].isLowercase && chars[index].isUppercase
    }
}
