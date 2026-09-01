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

/// Reads the usage-limit banner Claude Code writes into its session
/// transcripts, e.g. `You've hit your session limit · resets 8:10pm
/// (America/Toronto)`.
///
/// That string is the only on-disk record of when the window reopens — there
/// is no API, no socket, and no other file that stores it. The wording is
/// undocumented and Anthropic can change it at any time, so a `nil` return
/// means "no information", never "error": callers must carry on silently
/// rather than surfacing a failure or retrying.
enum ClaudeLimitParser {
    struct Limit: Equatable {
        /// Instant the window reopens.
        let resetDate: Date
        /// Zone named in the banner, *not* the machine zone.
        let timeZone: TimeZone
    }

    /// Compiled once — `parse` runs against every line of every transcript,
    /// and `NSRegularExpression(pattern:)` is expensive enough to matter there.
    ///
    /// Tolerances: either apostrophe (ASCII or U+2019), "session" or "usage"
    /// limit, optional spaces around the U+00B7 middle dot, optional `:MM`.
    /// Case-insensitive so `AM`/`Am`/`am` all land.
    private static let bannerRegex = try? NSRegularExpression(
        pattern: "You['\u{2019}]ve hit your (?:session|usage) limit"
            + "\\s*\u{00B7}\\s*resets\\s*"
            + "(\\d{1,2})(?::(\\d{2}))?\\s*(am|pm)"
            + "\\s*\\(([^)]+)\\)",
        options: [.caseInsensitive])

    /// Returns nil for anything unrecognised. Never throws, never traps.
    static func parse(_ text: String, anchoredAt anchor: Date) -> Limit? {
        guard let bannerRegex else { return nil }

        let full = NSRange(text.startIndex..., in: text)
        // Last match wins: a transcript accumulates banners over its lifetime
        // and only the most recent one describes the current window.
        guard let match = bannerRegex.matches(in: text, options: [], range: full).last,
              match.numberOfRanges == 5
        else { return nil }

        guard let hourText = capture(match, 1, in: text),
              let meridiem = capture(match, 3, in: text)?.lowercased(),
              let identifier = capture(match, 4, in: text)
        else { return nil }

        guard let hour12 = Int(hourText), (1...12).contains(hour12) else { return nil }

        let minute: Int
        if let minuteText = capture(match, 2, in: text) {
            guard let parsed = Int(minuteText), (0...59).contains(parsed) else { return nil }
            minute = parsed
        } else {
            minute = 0
        }

        // 12am is midnight, 12pm is noon — both appear in real transcripts.
        let hour24: Int
        switch meridiem {
        case "am": hour24 = hour12 == 12 ? 0 : hour12
        case "pm": hour24 = hour12 == 12 ? 12 : hour12 + 12
        default: return nil
        }

        // The banner's zone is authoritative; the machine may well be elsewhere.
        guard let zone = TimeZone(identifier: identifier) else { return nil }

        guard let resetDate = resolve(hour: hour24, minute: minute, zone: zone, anchor: anchor)
        else { return nil }

        return Limit(resetDate: resetDate, timeZone: zone)
    }

    /// Places `hour:minute` on the anchor's calendar day in `zone`, rolling
    /// forward a day when that instant has already passed.
    ///
    /// The anchor is when the banner was *written*, not now: on startup we
    /// re-read old transcripts, and resolving a stale banner against the
    /// current time would schedule a notification up to 24h in the future for
    /// a window that reopened long ago. The >24h rejection is the backstop.
    private static func resolve(hour: Int, minute: Int, zone: TimeZone, anchor: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone

        // Built from explicit components rather than `date(bySettingHour:)`,
        // whose matching policies behave unexpectedly across DST transitions.
        var components = calendar.dateComponents([.year, .month, .day], from: anchor)
        components.hour = hour
        components.minute = minute
        components.second = 0

        // `date(from:)` does not return nil inside a DST gap — it maps the
        // missing wall-clock time forward past the transition, so 2:30am on a
        // spring-forward day resolves to 3:30am. That is the right reading of
        // a banner naming a time that never occurs, so take it. This guard
        // only catches genuinely malformed components.
        guard var resolved = calendar.date(from: components) else { return nil }

        if resolved <= anchor {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: resolved)
            else { return nil }
            resolved = nextDay
        }

        guard resolved.timeIntervalSince(anchor) <= 24 * 60 * 60 else { return nil }
        return resolved
    }

    private static func capture(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        guard index < match.numberOfRanges,
              let range = Range(match.range(at: index), in: text)
        else { return nil }
        return String(text[range])
    }
}
