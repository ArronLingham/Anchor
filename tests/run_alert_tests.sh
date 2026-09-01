#!/bin/bash
# Pins AlertThreshold and SustainedCondition — the anti-flapping rules.
#
# Worth pinning because the bug they prevent only appears at the boundary, and
# reproducing it on real hardware means draining a battery to exactly 20% and
# watching it hover. A plain `value <= threshold` passes every casual test and
# then sends someone eleven notifications while their battery sits at 20%.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/System/SystemAlertManager.swift").read()
thr = re.search(r'(struct AlertThreshold \{.*?\n\})\n', src, re.S).group(1)
sus = re.search(r'(struct SustainedCondition \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + thr + "\n\n" + sus + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func eq(_ label: String, _ got: AlertThreshold.Outcome, _ want: AlertThreshold.Outcome) {
    if got == want { passes += 1 } else {
        failures += 1; print("  FAIL \(label): got \(got), want \(want)")
    }
}
func ok(_ label: String, _ c: Bool) {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)") }
}

// ---------- battery: fires BELOW the threshold ----------
let battery = AlertThreshold(threshold: 20, recoveryMargin: 5, reArmSeconds: 900, firesAbove: false)
func bat(_ v: Double, active: Bool = false, cleared: Double = .infinity) -> AlertThreshold.State {
    .init(value: v, isActive: active, sinceLastCleared: cleared)
}

eq("battery above threshold holds",     battery.evaluate(bat(50)), .hold)
eq("battery at threshold fires",        battery.evaluate(bat(20)), .fire)
eq("battery below threshold fires",     battery.evaluate(bat(12)), .fire)

// Latching: an active alert must not re-fire on every sample.
eq("does not re-fire while active",     battery.evaluate(bat(12, active: true)), .hold)
eq("does not re-fire at threshold",     battery.evaluate(bat(20, active: true)), .hold)

// Hysteresis: crossing back is not recovery; the margin must be cleared.
eq("21% is not recovery (margin 5)",    battery.evaluate(bat(21, active: true)), .hold)
eq("25% is not recovery (boundary)",    battery.evaluate(bat(25, active: true)), .hold)
eq("26% is recovery",                   battery.evaluate(bat(26, active: true)), .clear)

// Re-arm: after clearing, the interval must pass.
eq("cannot re-fire immediately",        battery.evaluate(bat(12, cleared: 10)), .hold)
eq("cannot re-fire just under",         battery.evaluate(bat(12, cleared: 899)), .hold)
eq("can re-fire after the interval",    battery.evaluate(bat(12, cleared: 900)), .fire)

// The flapping scenario end to end: a battery oscillating 19–21% must produce
// exactly ONE alert, not one per sample.
var active = false
var fires = 0
for v in [19.0, 21, 19, 21, 20, 19, 21, 19, 20, 21] {
    switch battery.evaluate(bat(v, active: active)) {
    case .fire:  fires += 1; active = true
    case .clear: active = false
    case .hold:  break
    }
}
ok("ten oscillating samples produce one alert, not ten", fires == 1)

// ---------- disk / CPU: fires ABOVE the threshold ----------
let disk = AlertThreshold(threshold: 90, recoveryMargin: 3, reArmSeconds: 3600, firesAbove: true)
func dsk(_ v: Double, active: Bool = false, cleared: Double = .infinity) -> AlertThreshold.State {
    .init(value: v, isActive: active, sinceLastCleared: cleared)
}
eq("disk below threshold holds",  disk.evaluate(dsk(50)), .hold)
eq("disk at threshold fires",     disk.evaluate(dsk(90)), .fire)
eq("disk above threshold fires",  disk.evaluate(dsk(97)), .fire)
eq("disk latches",                disk.evaluate(dsk(97, active: true)), .hold)
eq("88% is not recovery",         disk.evaluate(dsk(88, active: true)), .hold)
eq("87% is the boundary",         disk.evaluate(dsk(87, active: true)), .hold)
eq("86% is recovery",             disk.evaluate(dsk(86, active: true)), .clear)

// The direction flag genuinely reverses the comparison — a copy-paste that
// left `firesAbove` wrong would alert on a FULL battery and an EMPTY disk.
ok("directions are opposite at the same value",
   battery.evaluate(bat(95)) == .hold && disk.evaluate(dsk(95)) == .fire)

// ---------- SustainedCondition ----------
let sustained = SustainedCondition(requiredSeconds: 300)
let now = Date(timeIntervalSince1970: 1_000_000)
ok("not sustained when the condition is false", !sustained.isSustained(heldSince: nil, now: now))
ok("not sustained after 1s",  !sustained.isSustained(heldSince: now.addingTimeInterval(-1), now: now))
ok("not sustained at 299s",   !sustained.isSustained(heldSince: now.addingTimeInterval(-299), now: now))
ok("sustained at exactly 300s", sustained.isSustained(heldSince: now.addingTimeInterval(-300), now: now))
ok("sustained past 300s",       sustained.isSustained(heldSince: now.addingTimeInterval(-600), now: now))

// A CPU spike — held briefly, then released — must never reach the threshold
// rule. This is the gate that keeps a build from alerting.
var cpuHeld: Date? = nil
var cpuFires = 0
let cpuRule = AlertThreshold(threshold: 85, recoveryMargin: 10, reArmSeconds: 1800, firesAbove: true)
// 100% for 60s, then idle — a build.
for tick in 0..<10 {
    let t = now.addingTimeInterval(Double(tick) * 30)
    let load: Double = tick < 2 ? 100 : 5
    if load >= 85 { if cpuHeld == nil { cpuHeld = t } } else { cpuHeld = nil }
    let value = sustained.isSustained(heldSince: cpuHeld, now: t) ? load : 0
    if cpuRule.evaluate(.init(value: value, isActive: false, sinceLastCleared: .infinity)) == .fire {
        cpuFires += 1
    }
}
ok("a 60-second CPU spike raises no alert", cpuFires == 0)

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/alert" 2>&1 | grep -E "error" || true
"$WORK/alert"
