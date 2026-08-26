/*
 * Anchor — launcher tests
 *
 * Compiles the real FuzzyMatcher and CalculatorAction with swiftc, the same way
 * run_parser_tests.sh does, so these cannot drift from the implementation.
 *
 * Every case here pins a behaviour CLAUDE.md records as having been wrong at
 * some point, or a documented deliberate choice. A failure means the ranking
 * users actually see has changed.
 */

import Foundation

var failures = 0
var checks = 0

func check(_ condition: Bool, _ label: String) {
    checks += 1
    if condition {
        print("ok    \(label)")
    } else {
        failures += 1
        print("FAIL  \(label)")
    }
}

func score(_ query: String, _ candidate: String) -> Int? {
    FuzzyMatcher.match(query: query, candidate: candidate)?.score
}

@main
struct LauncherTests {
    static func main() {
        // MARK: - Subsequence rule

        check(score("zz", "Chess") == nil, "a non-subsequence does not match")
        check(score("", "Chess") != nil, "an empty query matches everything")
        check(score("chess", "Chess") != nil, "matching is case-insensitive")

        // MARK: - The DP-vs-greedy bug
        //
        // CLAUDE.md: greedy took the first valid alignment, so "ss" matched "SyStem"
        // and lost to "CheSS". The DP considers the word-boundary alignment too.

        if let system = score("ss", "System Settings"), let chess = score("ss", "Chess") {
            check(system > chess, "\"ss\" ranks System Settings above Chess (the DP bug)")
        } else {
            check(false, "\"ss\" matched both System Settings and Chess")
        }

        // MARK: - Acronym bonus
        //
        // +45 when every matched character is a word start. This is what makes
        // initials work at all.

        if let acronym = score("sm", "System Monitor"), let inWord = score("sm", "Sysmex") {
            check(acronym > inWord, "initials beat an in-word match of the same length")
        }

        // MARK: - Prefix and exact

        if let prefix = score("saf", "Safari"), let mid = score("saf", "Unsafari") {
            check(prefix > mid, "a prefix match outranks the same letters mid-word")
        }
        if let exact = score("chess", "Chess"), let partial = score("chess", "Chessboard") {
            check(exact > partial, "an exact match outranks a longer candidate")
        }

        // MARK: - Consecutive beats scattered

        if let run = score("abc", "abcdef"), let scattered = score("abc", "axbxcx") {
            check(run > scattered, "consecutive characters beat scattered ones")
        }

        // MARK: - Matched indices are usable for highlighting

        if let match = FuzzyMatcher.match(query: "sf", candidate: "Safari") {
            check(match.matchedIndices.count == 2, "one index per matched character")
            check(match.matchedIndices == match.matchedIndices.sorted(),
                  "matched indices come back in order")
            check(match.matchedIndices.allSatisfy { $0 >= 0 && $0 < 6 },
                  "matched indices are inside the candidate")
        }

        // MARK: - Real cases from the app's own index

        check(score("term", "Terminal") != nil, "term -> Terminal")
        check(score("xcode", "Xcode") != nil, "xcode -> Xcode")
        check(score("activity", "Activity Monitor") != nil, "activity -> Activity Monitor")

        // MARK: - Calculator: integer-division rewrite
        //
        // CLAUDE.md: NSExpression does integer arithmetic when both operands are
        // integers, so 100/3 gives 33 and 1/0 gives 0. Bare integer literals are
        // rewritten as decimals first.

        if let result = CalculatorAction.evaluate("100/3") {
            check(result.hasPrefix("33.3"),
                  "100/3 is decimal, not integer 33 (got \(result))")
        } else {
            check(false, "100/3 evaluates")
        }

        check(CalculatorAction.evaluate("1/0").map { $0 != "0" } ?? true,
              "1/0 does not silently return 0")

        // MARK: - Calculator: the lookarounds must not split an existing decimal

        if let result = CalculatorAction.evaluate("7.5+1") {
            check(result.hasPrefix("8.5") || result == "8.5",
                  "7.5+1 = 8.5, the decimal was not split (got \(result))")
        } else {
            check(false, "7.5+1 evaluates")
        }

        // MARK: - Calculator: what it must refuse

        check(CalculatorAction.evaluate("50%") == nil,
              "% is refused — percent to a user, modulo to NSExpression")
        check(CalculatorAction.evaluate("safari") == nil, "a plain app name is not arithmetic")
        check(CalculatorAction.evaluate("1+") == nil, "an incomplete expression is refused")
        check(CalculatorAction.evaluate("12") == nil, "a bare number is not an expression")
        check(CalculatorAction.evaluate("") == nil, "empty input is refused")

        // MARK: - Calculator: ordinary arithmetic still works

        check(CalculatorAction.evaluate("2+2")?.hasPrefix("4") ?? false, "2+2 = 4")
        check(CalculatorAction.evaluate("(2+3)*4")?.hasPrefix("20") ?? false, "(2+3)*4 = 20")
        check(CalculatorAction.evaluate("10-4")?.hasPrefix("6") ?? false, "10-4 = 6")


        print("")
        print("\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
