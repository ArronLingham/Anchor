#!/bin/bash
# Pins KeyDebounceFilter — the rule that decides whether a keystroke reaches
# the app.
#
# The stakes are asymmetric and that shapes every case below: letting a bounce
# through is a minor annoyance, but wrongly suppressing a real keystroke means
# the user's typing silently loses characters. So every ambiguous case must
# resolve to ACCEPT, and those are the cases tested hardest.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Filter.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Input/KeyDebounceManager.swift").read()
st = re.search(r'(struct KeyDebounceFilter \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + st + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
var passes = 0, failures = 0
func ok(_ label: String, _ cond: Bool) {
    if cond { passes += 1 } else { failures += 1; print("  FAIL \(label)") }
}

// --- a bounce is suppressed ---
var f = KeyDebounceFilter(thresholdSeconds: 0.025)
ok("first press accepted", f.shouldAccept(keyCode: 4, timestamp: 1.000))
ok("bounce at +5ms suppressed", !f.shouldAccept(keyCode: 4, timestamp: 1.005))
ok("bounce at +10ms suppressed", !f.shouldAccept(keyCode: 4, timestamp: 1.015))

// --- real typing is never touched ---
var g = KeyDebounceFilter(thresholdSeconds: 0.025)
ok("deliberate repeat at +100ms accepted", g.shouldAccept(keyCode: 4, timestamp: 2.0))
ok("...accepted", g.shouldAccept(keyCode: 4, timestamp: 2.1))
ok("exactly at threshold accepted", g.shouldAccept(keyCode: 4, timestamp: 2.125))

// --- different keys never interfere, even typed fast ---
var h = KeyDebounceFilter(thresholdSeconds: 0.025)
ok("key A", h.shouldAccept(keyCode: 1, timestamp: 5.000))
ok("key B 1ms later still accepted", h.shouldAccept(keyCode: 2, timestamp: 5.001))
ok("key C 1ms later still accepted", h.shouldAccept(keyCode: 3, timestamp: 5.002))
ok("key A again 3ms later still accepted", h.shouldAccept(keyCode: 1, timestamp: 5.003) == false)

// --- ambiguity must resolve to ACCEPT ---
var i = KeyDebounceFilter(thresholdSeconds: 0.025)
ok("first ever press", i.shouldAccept(keyCode: 9, timestamp: 10.0))
ok("clock moved backwards -> accept", i.shouldAccept(keyCode: 9, timestamp: 9.0))
var j = KeyDebounceFilter(thresholdSeconds: 0.025)
ok("identical timestamps -> accept", j.shouldAccept(keyCode: 7, timestamp: 3.0))
ok("identical timestamps -> accept again", j.shouldAccept(keyCode: 7, timestamp: 3.0))

// --- reset clears history ---
var k = KeyDebounceFilter(thresholdSeconds: 0.025)
_ = k.shouldAccept(keyCode: 4, timestamp: 1.0)
k.reset()
ok("after reset the next press is accepted", k.shouldAccept(keyCode: 4, timestamp: 1.001))

// --- a zero threshold disables suppression entirely ---
var z = KeyDebounceFilter(thresholdSeconds: 0)
ok("zero threshold accepts", z.shouldAccept(keyCode: 4, timestamp: 1.0))
ok("zero threshold accepts immediately after", z.shouldAccept(keyCode: 4, timestamp: 1.0001))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT
swiftc -O "$WORK/Filter.swift" "$WORK/main.swift" -o "$WORK/deb" 2>&1 | grep -E "error" || true
"$WORK/deb"
