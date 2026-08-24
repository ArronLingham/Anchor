// Unit tests for ClaudeLimitParser.
//
// Run with ./tests/run_parser_tests.sh — it compiles the real parser source
// alongside this file, so these cannot drift from the implementation.

import Foundation

var failures = 0
var checks = 0

func iso(_ s: String, _ zone: String) -> Date {
    var c = DateComponents()
    let p = s.split(separator: " ")
    let d = p[0].split(separator: "-").map { Int($0)! }
    let t = p[1].split(separator: ":").map { Int($0)! }
    c.year = d[0]; c.month = d[1]; c.day = d[2]
    c.hour = t[0]; c.minute = t[1]; c.second = 0
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: zone)!
    return cal.date(from: c)!
}

func fmt(_ d: Date, _ zone: String) -> String {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm"
    f.timeZone = TimeZone(identifier: zone)!
    return f.string(from: d)
}

func expect(_ label: String, _ text: String, anchor: Date,
            expectZone: String?, expectWall: String?) {
    checks += 1
    let got = ClaudeLimitParser.parse(text, anchoredAt: anchor)
    guard let expectZone, let expectWall else {
        if got != nil {
            failures += 1
            print("FAIL  \(label): expected nil, got \(got!)")
        } else {
            print("ok    \(label): nil as expected")
        }
        return
    }
    guard let got else {
        failures += 1
        print("FAIL  \(label): expected \(expectWall) \(expectZone), got nil")
        return
    }
    let wall = fmt(got.resetDate, expectZone)
    if wall == expectWall && got.timeZone.identifier == expectZone {
        print("ok    \(label): \(wall) \(got.timeZone.identifier)")
    } else {
        failures += 1
        print("FAIL  \(label): expected \(expectWall) \(expectZone), got \(wall) \(got.timeZone.identifier)")
    }
}

@main
struct ClaudeLimitParserTests {
    static func main() {
        let TZ = "America/Toronto"
        // Anchor: Mon 2026-08-24 10:00 Toronto (a normal weekday, no DST edge)
        let anchor = iso("2026-08-24 10:00", TZ)

        // --- The four real fixtures observed in transcripts ---
        expect("5am (rolls to tomorrow, already past)",
               "You've hit your session limit · resets 5am (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-25 05:00")

        expect("12pm is NOON not midnight",
               "You've hit your session limit · resets 12pm (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 12:00")

        expect("8:10pm",
               "You've hit your session limit · resets 8:10pm (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        expect("1:40am (rolls to tomorrow)",
               "You've hit your session limit · resets 1:40am (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-25 01:40")

        // --- 12am is midnight ---
        expect("12am is MIDNIGHT",
               "You've hit your session limit · resets 12am (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-25 00:00")

        // --- cross-midnight: anchored at 23:00, reset 1:40am -> next day ---
        expect("cross-midnight from 23:00",
               "You've hit your session limit · resets 1:40am (America/Toronto)",
               anchor: iso("2026-08-24 23:00", TZ), expectZone: TZ, expectWall: "2026-08-25 01:40")

        // --- named zone is authoritative, not the machine zone ---
        expect("zone honoured: LA banner while anchored in Toronto",
               "You've hit your session limit · resets 5am (America/Los_Angeles)",
               anchor: anchor, expectZone: "America/Los_Angeles", expectWall: "2026-08-25 05:00")

        // --- wording tolerances ---
        expect("curly apostrophe U+2019",
               "You\u{2019}ve hit your session limit · resets 8:10pm (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        expect("'usage limit' wording",
               "You've hit your usage limit · resets 8:10pm (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        expect("uppercase PM",
               "You've hit your session limit · resets 8:10PM (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        // --- last match wins ---
        expect("two banners: last wins",
               "You've hit your session limit · resets 5am (America/Toronto)\nlater\nYou've hit your session limit · resets 8:10pm (America/Toronto)",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        // --- embedded in surrounding transcript noise ---
        expect("embedded in JSONL noise",
               "{\"type\":\"assistant\",\"text\":\"You've hit your session limit · resets 8:10pm (America/Toronto)\"}",
               anchor: anchor, expectZone: TZ, expectWall: "2026-08-24 20:10")

        // --- rejections ---
        expect("unrelated text", "just some ordinary output", anchor: anchor, expectZone: nil, expectWall: nil)
        expect("no zone", "You've hit your session limit · resets 5am", anchor: anchor, expectZone: nil, expectWall: nil)
        expect("bogus zone", "You've hit your session limit · resets 5am (Mars/Olympus)", anchor: anchor, expectZone: nil, expectWall: nil)
        expect("hour 13", "You've hit your session limit · resets 13pm (America/Toronto)", anchor: anchor, expectZone: nil, expectWall: nil)
        expect("minute 99", "You've hit your session limit · resets 8:99pm (America/Toronto)", anchor: anchor, expectZone: nil, expectWall: nil)
        expect("hour 0", "You've hit your session limit · resets 0am (America/Toronto)", anchor: anchor, expectZone: nil, expectWall: nil)

        // --- DST: America/Toronto springs forward 2026-03-08 02:00 -> 03:00 ---
        // Toronto springs forward 2026-03-08 02:00 -> 03:00, so 2:30am never occurs
        // that day. Foundation maps it forward past the transition rather than failing.
        expect("DST gap: 2:30am on spring-forward day maps to 3:30am",
               "You've hit your session limit · resets 2:30am (America/Toronto)",
               anchor: iso("2026-03-08 01:00", TZ), expectZone: TZ, expectWall: "2026-03-08 03:30")

        print("")
        print("\(checks - failures)/\(checks) passed")
        exit(failures == 0 ? 0 : 1)
    }
}
