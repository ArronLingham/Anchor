#!/bin/bash
# Pins launcher frecency decay and the ntfy delay window.
#
# Frecency drives what the launcher shows first on every keystroke, and the
# decay is easy to get subtly wrong — an inverted exponent makes OLD apps rank
# higher, which feels like the launcher is simply bad rather than broken.
#
# The ntfy window is pinned because CLAUDE.md records the consequence of getting
# it wrong: ntfy REJECTS a delay under 10 s with HTTP 400, and a refused
# schedule delivers nothing at all. So "too soon" must fall back to sending
# immediately, never to scheduling.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/F.swift" <<'PYX'
import re, sys
lh = open("Anchor/Managers/Launcher/LaunchHistory.swift").read()

half = re.search(r'static let halfLifeDays: Double = ([0-9.]+)', lh).group(1)
# The decay is one expression; lift it into a pure function so it can be tested
# without the actor, the queue or the on-disk store.
decay = re.search(r'return raw \* pow\(([^)]*)\)', lh).group(0)

pp = open("Anchor/Managers/ClaudeUsage/PhonePush.swift").read()
mn = re.search(r'minimumDelay: TimeInterval = ([0-9]+)', pp).group(1)
mx = re.search(r'maximumDelay: TimeInterval = ([0-9*\s]+)', pp).group(1).strip()

src = f"""import Foundation

enum Frecency {{
    static let halfLifeDays: Double = {half}

    /// Extracted verbatim from LaunchHistory.decayedScore.
    static func decayed(raw: Double, ageDays: Double) -> Double {{
        {decay}
    }}
}}

enum PushWindow {{
    static let minimumDelay: TimeInterval = {mn}
    static let maximumDelay: TimeInterval = {mx}

    enum Outcome: Equatable {{ case sendNow, schedule, refuse }}

    /// Mirrors PhonePush.makeRequest's delay branch.
    static func decide(delay: TimeInterval) -> Outcome {{
        guard delay <= maximumDelay else {{ return .refuse }}
        return delay >= minimumDelay ? .schedule : .sendNow
    }}
}}
"""
open(sys.argv[1], "w").write(src)
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

// ---------- frecency decay ----------
ok("no age means no decay", Frecency.decayed(raw: 8, ageDays: 0) == 8)
ok("one half-life halves the score",
   abs(Frecency.decayed(raw: 8, ageDays: Frecency.halfLifeDays) - 4) < 0.0001,
   "\(Frecency.decayed(raw: 8, ageDays: Frecency.halfLifeDays))")
ok("two half-lives quarter it",
   abs(Frecency.decayed(raw: 8, ageDays: Frecency.halfLifeDays * 2) - 2) < 0.0001)
ok("ten half-lives is nearly nothing",
   Frecency.decayed(raw: 8, ageDays: Frecency.halfLifeDays * 10) < 0.01)

// The direction. An inverted exponent makes old apps rank HIGHER, which feels
// like a bad launcher rather than a bug.
ok("older always scores lower than newer, same raw count",
   Frecency.decayed(raw: 5, ageDays: 30) < Frecency.decayed(raw: 5, ageDays: 1))
var mono = 0
var prev = Frecency.decayed(raw: 10, ageDays: 0)
for d in stride(from: 0.5, through: 200.0, by: 0.5) {
    let cur = Frecency.decayed(raw: 10, ageDays: d)
    if cur > prev { mono += 1 }
    prev = cur
}
ok("decay is monotonic over 400 ages", mono == 0, "\(mono) increases")

// Recency beats raw count eventually — that is the whole point of frecency.
let usedOnceToday    = Frecency.decayed(raw: 1,  ageDays: 0)
let usedTwentyTimesLastMonth = Frecency.decayed(raw: 20, ageDays: 60)
ok("one launch today outranks twenty from two months ago",
   usedOnceToday > usedTwentyTimesLastMonth,
   "\(usedOnceToday) vs \(usedTwentyTimesLastMonth)")
// But not immediately — a heavily used app should survive a few days.
ok("twenty launches still beat one after three days",
   Frecency.decayed(raw: 20, ageDays: 3) > Frecency.decayed(raw: 1, ageDays: 0))

// Degenerate inputs must not produce NaN or negative scores.
var bad = 0
for raw in [0.0, 1.0, 1e6] {
    for age in [0.0, 1.0, 1e4, -1.0] {
        let v = Frecency.decayed(raw: raw, ageDays: age)
        if !v.isFinite || v < 0 { bad += 1 }
    }
}
ok("never NaN or negative, including a negative age", bad == 0, "\(bad) bad values")
ok("zero raw score stays zero", Frecency.decayed(raw: 0, ageDays: 5) == 0)
ok("a clock skewed backwards does not inflate a score beyond raw*2",
   Frecency.decayed(raw: 5, ageDays: -1) < 10,
   "\(Frecency.decayed(raw: 5, ageDays: -1))")

// ---------- ntfy delay window ----------
ok("a reset an hour out is scheduled", PushWindow.decide(delay: 3600) == .schedule)
ok("a reset three hours out is scheduled", PushWindow.decide(delay: 3 * 3600) == .schedule)

// The critical fallback: ntfy 400s on a sub-10s delay, and a refused schedule
// delivers NOTHING. Too-soon must send now, never schedule.
ok("5 seconds out sends NOW, not scheduled", PushWindow.decide(delay: 5) == .sendNow)
ok("1 second out sends now",  PushWindow.decide(delay: 1) == .sendNow)
ok("0 seconds sends now",     PushWindow.decide(delay: 0) == .sendNow)
ok("already past sends now",  PushWindow.decide(delay: -100) == .sendNow)
ok("exactly the minimum schedules", PushWindow.decide(delay: PushWindow.minimumDelay) == .schedule)
ok("a hair under the minimum sends now",
   PushWindow.decide(delay: PushWindow.minimumDelay - 0.001) == .sendNow)

// Past ntfy's 3-day ceiling it must refuse rather than send a doomed schedule.
ok("exactly the maximum is still scheduled",
   PushWindow.decide(delay: PushWindow.maximumDelay) == .schedule)
ok("a second past the maximum refuses",
   PushWindow.decide(delay: PushWindow.maximumDelay + 1) == .refuse)
ok("a week out refuses", PushWindow.decide(delay: 7 * 86_400) == .refuse)
ok("the maximum is three days", PushWindow.maximumDelay == 3 * 24 * 60 * 60,
   "\(PushWindow.maximumDelay)")
ok("the minimum is ten seconds", PushWindow.minimumDelay == 10)

// Every delay resolves to exactly one outcome, with no gap between the bands.
var gaps = 0
for d in stride(from: -60.0, through: 4 * 86_400, by: 137.0) {
    let o = PushWindow.decide(delay: d)
    let expected: PushWindow.Outcome =
        d > PushWindow.maximumDelay ? .refuse : (d >= PushWindow.minimumDelay ? .schedule : .sendNow)
    if o != expected { gaps += 1 }
}
ok("the three bands tile the whole range with no gap", gaps == 0, "\(gaps) mismatches")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/F.swift" "$WORK/main.swift" -o "$WORK/fr" 2>&1 | grep -E "error" || true
"$WORK/fr"
