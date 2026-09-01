#!/bin/bash
# Pins BatteryHistoryManager's coalescing and pruning.
#
# CLAUDE.md's claim for this feature is that it costs nothing: "on a machine
# sitting at 100% plugged in, that is zero samples per hour." That is only true
# if the coalescer actually collapses the OS's repeat signals — IOPS fires
# several times for one real change. Without it the history grows unboundedly
# on a machine that is doing nothing, which is the opposite of the design.
#
# The record/prune bodies are lifted from the manager with the stored array
# turned into a parameter, so they cannot drift.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/BH.swift" <<'PYX'
import re, sys
src = open("Anchor/Managers/Battery/BatteryHistoryManager.swift").read()

def block(pattern):
    m = re.search(pattern, src); i = m.start()
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    return src[i:k+1]

sample = block(r'struct BatterySample\b')
rec  = block(r'    private func record\(level: Float, charging: Bool\)')
prn  = block(r'    private func prune\(now: Date\)')
retention = re.search(r'private let retention: TimeInterval = ([0-9*\s]+)', src).group(1).strip()
maxs = re.search(r'(?:private )?(?:let|var) maxSamples[^=]*= *([0-9]+)', src)
maxs = maxs.group(1) if maxs else "2000"

# Turn the two private methods into a testable store.
rec = rec.replace("private func record(level: Float, charging: Bool)",
                  "mutating func record(level: Float, charging: Bool, now: Date)")
rec = rec.replace("let now = Date()", "")
rec = rec.replace("scheduleSave()", "")
prn = prn.replace("private func prune(now: Date)", "mutating func prune(now: Date)")

src_out = f"""import Foundation

{sample}

struct HistoryStore {{
    var samples: [BatterySample] = []
    let retention: TimeInterval = {retention}
    let maxSamples: Int = {maxs}

{rec}

{prn}
}}
"""
open(sys.argv[1], "w").write(src_out)
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
let t0 = Date(timeIntervalSince1970: 1_700_000_000)

// ---------- the claim: an idle machine records nothing ----------
var s = HistoryStore()
s.record(level: 100, charging: true, now: t0)
ok("the first sample is always recorded", s.samples.count == 1)

// Twenty repeat signals for one unchanged state, seconds apart — exactly what
// IOPS does on a plugged-in machine.
for i in 1...20 { s.record(level: 100, charging: true, now: t0.addingTimeInterval(Double(i))) }
ok("20 identical signals collapse to the original one sample",
   s.samples.count == 1, "got \(s.samples.count)")

// Past the 60-second window the same state IS recorded again — that is the
// heartbeat, not a duplicate.
s.record(level: 100, charging: true, now: t0.addingTimeInterval(61))
ok("the same state after 60s records again", s.samples.count == 2, "got \(s.samples.count)")
// The boundary is `elapsed < 60`, so exactly 60 s records rather than
// collapsing. Pinned explicitly because "within a minute" is ambiguous in
// prose and this is the line that decides it.
var w = HistoryStore()
w.record(level: 50, charging: false, now: t0)
w.record(level: 50, charging: false, now: t0.addingTimeInterval(59.999))
ok("just under 60s is collapsed", w.samples.count == 1, "got \(w.samples.count)")
w.record(level: 50, charging: false, now: t0.addingTimeInterval(60))
ok("exactly 60s records (the guard is < 60, not <=)", w.samples.count == 2,
   "got \(w.samples.count)")

// ---------- a REAL change is never collapsed ----------
var c = HistoryStore()
c.record(level: 80, charging: false, now: t0)
c.record(level: 79, charging: false, now: t0.addingTimeInterval(1))
ok("a level change one second later is recorded", c.samples.count == 2)
c.record(level: 79, charging: true, now: t0.addingTimeInterval(2))
ok("a charging-state change is recorded even at the same level", c.samples.count == 3)

// ---------- rejection ----------
var z = HistoryStore()
z.record(level: 0, charging: false, now: t0)
ok("level 0 is rejected (IOPS reports it while waking)", z.samples.isEmpty)
z.record(level: -5, charging: false, now: t0)
ok("a negative level is rejected", z.samples.isEmpty)

// ---------- pruning by age ----------
var p = HistoryStore()
for h in 0..<48 { p.record(level: Float(100 - h), charging: false, now: t0.addingTimeInterval(Double(h) * 3600)) }
let now48 = t0.addingTimeInterval(47 * 3600)
ok("48 hours of samples prune to the retention window",
   p.samples.count <= 25, "kept \(p.samples.count)")
ok("nothing older than the retention window survives",
   p.samples.allSatisfy { $0.at >= now48.addingTimeInterval(-p.retention) },
   "oldest is \(p.samples.first?.at.timeIntervalSince(now48) ?? 0)s before now")
ok("the newest sample is always kept", p.samples.last?.level == Float(100 - 47))

// ---------- ordering ----------
ok("samples stay oldest-first",
   zip(p.samples, p.samples.dropFirst()).allSatisfy { $0.at <= $1.at })

// ---------- the count cap ----------
var big = HistoryStore()
for i in 0..<(big.maxSamples + 500) {
    // one second apart and always changing, so nothing collapses
    big.record(level: Float(1 + (i % 99)), charging: i % 2 == 0,
               now: t0.addingTimeInterval(Double(i)))
}
ok("never exceeds maxSamples", big.samples.count <= big.maxSamples,
   "got \(big.samples.count), cap \(big.maxSamples)")
ok("the cap drops the OLDEST, keeping recent history",
   big.samples.last?.at == t0.addingTimeInterval(Double(big.maxSamples + 499)))

// ---------- an empty store prunes without crashing ----------
var e = HistoryStore()
e.prune(now: t0)
ok("pruning an empty store is safe", e.samples.isEmpty)

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/BH.swift" "$WORK/main.swift" -o "$WORK/bh" 2>&1 | grep -E "error" || true
"$WORK/bh"
