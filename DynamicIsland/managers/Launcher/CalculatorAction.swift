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

import Foundation

/// Inline arithmetic in the launcher: type `18*7.5` and press Enter to copy
/// the answer.
///
/// Backed by `NSExpression`, which handles precedence and parentheses, wrapped
/// in a strict pre-check. Without that check `NSExpression` happily parses
/// things like `Safari` as a variable reference and throws at evaluation time,
/// so every ordinary app search would take an exception detour.
enum CalculatorAction {
    /// Characters an arithmetic expression may contain.
    ///
    /// `%` is deliberately excluded: it reads as "percent" to a user and
    /// "modulo" to `NSExpression`, and guessing wrong is worse than not
    /// handling it.
    private static let allowed = CharacterSet(charactersIn: "0123456789.+-*/() \t")

    /// Rewrites bare integer literals as decimals.
    ///
    /// `NSExpression` does integer arithmetic when both operands are integers,
    /// so `100/3` evaluates to `33` and `1/0` to `0` rather than infinity. The
    /// lookarounds keep it from splitting an existing decimal like `7.5`.
    private static let integerLiteral = try? NSRegularExpression(
        pattern: "(?<![\\d.])(\\d+)(?![\\d.])")

    /// Returns a formatted result, or nil when `query` is not arithmetic.
    static func evaluate(_ query: String) -> String? {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else { return nil }

        // Must be entirely arithmetic characters, contain at least one operator
        // between operands, and at least one digit.
        guard trimmed.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        guard trimmed.rangeOfCharacter(from: .decimalDigits) != nil else { return nil }
        guard trimmed.dropFirst().rangeOfCharacter(from: CharacterSet(charactersIn: "+-*/")) != nil
        else { return nil }
        // Reject a trailing operator — the user is still typing.
        guard let last = trimmed.last, !"+-*/.".contains(last) else { return nil }

        let normalized = floatify(trimmed)

        let value: Any?
        do {
            // NSExpression raises ObjC exceptions on malformed input, which
            // Swift cannot catch — hence the strict validation above.
            value = try evaluateExpression(normalized)
        } catch {
            return nil
        }

        guard let number = value as? NSNumber else { return nil }
        let double = number.doubleValue
        guard double.isFinite else { return nil }
        return format(double)
    }

    private static func floatify(_ expression: String) -> String {
        guard let integerLiteral else { return expression }
        let range = NSRange(expression.startIndex..., in: expression)
        return integerLiteral.stringByReplacingMatches(
            in: expression, options: [], range: range, withTemplate: "$1.0")
    }

    private static func evaluateExpression(_ string: String) throws -> Any? {
        let expression = NSExpression(format: string)
        return expression.expressionValue(with: nil, context: nil)
    }

    private static func format(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        // Integers should read as integers; otherwise show useful precision
        // without a float-noise tail.
        formatter.maximumFractionDigits = value == value.rounded() ? 0 : 6
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }
}
