#!/bin/bash
# Pins SystemStatsManager's network rate derivation.
#
# Interface byte counters are cumulative and RESET when an interface goes away —
# waking from sleep, switching Wi-Fi networks, unplugging a dongle. A naive
# `now - last` then produces a huge negative number, which as an unsigned
# subtraction wraps to something astronomical and shows the user a 16 EB/s
# spike in the menu bar.
#
# The delta block is lifted from the source with its inputs turned into
# parameters, so it cannot drift from the code that actually feeds the readout.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Net.swift" <<'PYX'
import re, sys
src = open("Anchor/Managers/System/SystemStatsManager.swift").read()

# The contiguous delta/rate block, verbatim.
m = re.search(r'(        let seconds = now\.timeIntervalSince\(last\.at\).*?return \(dIn / seconds, dOut / seconds\))', src, re.S)
body = m.group(1)

out = f"""import Foundation

struct NetRate {{
    var sessionInBytes: UInt64 = 0
    var sessionOutBytes: UInt64 = 0

    /// Extracted verbatim from SystemStatsManager.readNetworkRates, with the
    /// system-read inputs turned into parameters.
    mutating func rates(inBytes: UInt64, outBytes: UInt64,
                        last: (inBytes: UInt64, outBytes: UInt64, at: Date)?,
                        now: Date) -> (Double, Double)? {{
        guard let last else {{ return nil }}
{body}
    }}
}}
"""
open(sys.argv[1], "w").write(out)
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// ---------- normal ----------
var n = NetRate()
if let r = n.rates(inBytes: 2_000, outBytes: 1_000,
                   last: (1_000, 500, t0), now: t0.addingTimeInterval(1)) {
    ok("1000 bytes in one second is 1000 B/s", r.0 == 1000, "\(r.0)")
    ok("500 bytes out in one second is 500 B/s", r.1 == 500, "\(r.1)")
} else { failures += 1; print("  FAIL normal case returned nil") }

var h = NetRate()
if let r = h.rates(inBytes: 3_000, outBytes: 0, last: (1_000, 0, t0), now: t0.addingTimeInterval(2)) {
    ok("2000 bytes over two seconds is 1000 B/s", r.0 == 1000, "\(r.0)")
}

// ---------- THE reset case ----------
// Counter goes BACKWARDS: interface came back with a fresh baseline.
var w = NetRate()
let reset = w.rates(inBytes: 50, outBytes: 20, last: (1_000_000, 900_000, t0),
                    now: t0.addingTimeInterval(1))
ok("a counter reset reports 0, not an unsigned-wrap spike",
   reset?.0 == 0 && reset?.1 == 0, "\(String(describing: reset))")
ok("a reset does not corrupt the session total",
   w.sessionInBytes == 0 && w.sessionOutBytes == 0,
   "in \(w.sessionInBytes), out \(w.sessionOutBytes)")

// Only the direction that reset is zeroed; the other still counts.
var one = NetRate()
if let r = one.rates(inBytes: 10, outBytes: 5_000, last: (9_999, 1_000, t0),
                     now: t0.addingTimeInterval(1)) {
    ok("in reset -> 0 while out still measures", r.0 == 0 && r.1 == 4000,
       "in \(r.0), out \(r.1)")
}

// ---------- first sample ----------
var f = NetRate()
ok("no previous sample yields nil, not a since-boot ratio",
   f.rates(inBytes: 1_000, outBytes: 500, last: nil, now: t0) == nil)

// ---------- zero and negative elapsed ----------
var z = NetRate()
ok("zero elapsed time yields nil rather than dividing by zero",
   z.rates(inBytes: 2_000, outBytes: 0, last: (1_000, 0, t0), now: t0) == nil)
ok("a clock that went backwards yields nil",
   z.rates(inBytes: 2_000, outBytes: 0, last: (1_000, 0, t0),
           now: t0.addingTimeInterval(-5)) == nil)

// ---------- session totals accumulate the same deltas as the rates ----------
var s = NetRate()
var expectedIn: UInt64 = 0
var cumulative: UInt64 = 0
var prev: (UInt64, UInt64, Date) = (0, 0, t0)
for i in 1...20 {
    cumulative += 1_500
    let now = t0.addingTimeInterval(Double(i))
    _ = s.rates(inBytes: cumulative, outBytes: 0, last: prev, now: now)
    prev = (cumulative, 0, now)
    expectedIn += 1_500
}
ok("session total equals the sum of the deltas it reported",
   s.sessionInBytes == expectedIn, "got \(s.sessionInBytes), want \(expectedIn)")

// A reset mid-session contributes nothing rather than a jump.
var m = NetRate()
_ = m.rates(inBytes: 1_000, outBytes: 0, last: (0, 0, t0), now: t0.addingTimeInterval(1))
let beforeReset = m.sessionInBytes
_ = m.rates(inBytes: 5, outBytes: 0, last: (1_000, 0, t0.addingTimeInterval(1)),
            now: t0.addingTimeInterval(2))
ok("a mid-session reset adds nothing to the total",
   m.sessionInBytes == beforeReset, "\(beforeReset) -> \(m.sessionInBytes)")

// ---------- no rate is ever negative or non-finite ----------
var bad = 0
var g = NetRate()
for (a, b, dt) in [(UInt64(0), UInt64(0), 1.0), (0, 1_000_000, 0.001),
                   (UInt64.max, 0, 1.0), (1, UInt64.max, 60.0)] {
    if let r = g.rates(inBytes: a, outBytes: 0, last: (b, 0, t0), now: t0.addingTimeInterval(dt)) {
        if r.0 < 0 || !r.0.isFinite || r.1 < 0 || !r.1.isFinite { bad += 1 }
    }
}
ok("no rate is ever negative or non-finite", bad == 0, "\(bad) bad")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Net.swift" "$WORK/main.swift" -o "$WORK/net" 2>&1 | grep -E "error" || true
"$WORK/net"
