#!/bin/bash
# Pins the loudness leveler — GainComputer and GainSmoother.
#
# This decides how much to boost or cut the user's audio in real time, and every
# failure here is audible rather than visible:
#
#   * boost exceeding maxBoostDb        -> distortion on quiet passages
#   * no noise-floor guard              -> silence amplified into hiss
#   * a smoother that overshoots        -> pumping
#   * gain applied to digital silence   -> the classic "amplify nothing" bug
#
# None of it crashes. It just sounds wrong, which is the hardest kind of bug to
# attribute to a notch app.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Loud.swift" <<'PYX'
import re, sys

def block(path, pattern):
    src = open(path).read()
    m = re.search(pattern, src)
    i = m.start()
    depth, k = 0, src.index("{", i)
    while True:
        if src[k] == "{": depth += 1
        elif src[k] == "}":
            depth -= 1
            if depth == 0: break
        k += 1
    return src[i:k+1]

parts = ["import Foundation\n"]
parts.append(block("Anchor/Audio/PerApp/Loudness/LoudnessEqualizerSettings.swift",
                   r'(?:nonisolated )?struct LoudnessEqualizerSettings\b'))
parts.append(block("Anchor/Audio/PerApp/Loudness/LoudnessEqualizerMath.swift",
                   r'enum LoudnessEqualizerMath\b'))
parts.append(block("Anchor/Audio/PerApp/Loudness/GainComputer.swift",
                   r'struct GainComputer\b'))
parts.append(block("Anchor/Audio/PerApp/Loudness/GainSmoother.swift",
                   r'(?:final )?(?:class|struct) GainSmoother\b'))
src = "\n\n".join(parts)
src = re.sub(r'^\s*import .*$', '', src, flags=re.M)
src = src.replace("@inline(__always)\n", "")
open(sys.argv[1], "w").write("import Foundation\n" + src + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

let s = LoudnessEqualizerSettings()
let g = GainComputer(settings: s)

// ---------- normal cases ----------
// Material quieter than target gets boosted, louder gets cut.
ok("quiet material is boosted",  g.desiredGainDb(forLevelDb: -20) > 0,
   "\(g.desiredGainDb(forLevelDb: -20))")
ok("material at target is left alone", abs(g.desiredGainDb(forLevelDb: s.targetLoudnessDb)) < 0.5,
   "\(g.desiredGainDb(forLevelDb: s.targetLoudnessDb))")
ok("loud material is cut", g.desiredGainDb(forLevelDb: 0) < 0,
   "\(g.desiredGainDb(forLevelDb: 0))")

// ---------- THE limits, across the entire input range ----------
// A boost above maxBoostDb distorts; a cut below maxCutDb pumps.
var overBoost = 0, overCut = 0, nonFinite = 0
for level in stride(from: -120.0, through: 20.0, by: 0.25) {
    let gain = g.desiredGainDb(forLevelDb: Float(level))
    if !gain.isFinite { nonFinite += 1 }
    if gain > s.maxBoostDb + 0.001 { overBoost += 1 }
    if gain < -(s.maxCutDb + 0.001) { overCut += 1 }
}
ok("never boosts past maxBoostDb over 561 levels", overBoost == 0, "\(overBoost) violations")
ok("never cuts past maxCutDb over 561 levels",     overCut == 0, "\(overCut) violations")
ok("gain is always finite",                        nonFinite == 0, "\(nonFinite) non-finite")

// ---------- noise floor: do not amplify silence into hiss ----------
let quiet = g.desiredGainDb(forLevelDb: -80)
ok("near-silence is barely boosted", quiet <= s.lowLevelMaxBoostDb + 0.001,
   "got \(quiet), cap is \(s.lowLevelMaxBoostDb)")
ok("digital silence is barely boosted",
   g.desiredGainDb(forLevelDb: -140) <= s.lowLevelMaxBoostDb + 0.001,
   "got \(g.desiredGainDb(forLevelDb: -140))")
// Just above the noise floor the full boost is allowed again.
ok("above the noise floor the full boost returns",
   g.desiredGainDb(forLevelDb: s.noiseFloorThresholdDb + 1) > s.lowLevelMaxBoostDb,
   "got \(g.desiredGainDb(forLevelDb: s.noiseFloorThresholdDb + 1))")

// ---------- monotonicity, and the one place it breaks ----------
//
// FINDING (2026-09-01): the curve is monotonic everywhere EXCEPT a single
// 5.5 dB step at exactly the noise-floor threshold (-40 dB), where the
// low-level boost cap is released. It is a hard knee with no hysteresis, so
// material sitting near -40 dB crosses back and forth and the desired gain
// flaps between 0.5 dB and 6 dB — the same shape as an alert threshold with no
// hysteresis.
//
// It is NOT changed here. This is ported FineTune DSP and altering a gain curve
// without being able to listen to the result is how audio gets quietly worse.
// What the tests do instead is pin it: the step exists, it is exactly one, it
// is exactly where the threshold is, and the smoother turns it into a swell
// rather than a click. If someone soft-knees this later, these assertions say
// what the old behaviour was.
var reversals: [(Double, Float, Float)] = []
var prev = g.desiredGainDb(forLevelDb: -120)
for level in stride(from: -119.75, through: 20.0, by: 0.25) {
    let cur = g.desiredGainDb(forLevelDb: Float(level))
    if cur > prev + 0.001 { reversals.append((level, prev, cur)) }
    prev = cur
}
ok("exactly one discontinuity in the whole curve", reversals.count == 1,
   "found \(reversals.count): \(reversals.prefix(3))")
ok("and it is at the noise-floor threshold",
   reversals.first.map { abs($0.0 - Double(s.noiseFloorThresholdDb)) < 0.26 } ?? false,
   "at \(reversals.first?.0 ?? -999), threshold is \(s.noiseFloorThresholdDb)")
ok("the step is the boost cap being released, not something larger",
   reversals.first.map { abs(($0.2 - $0.1) - (s.maxBoostDb - s.lowLevelMaxBoostDb)) < 0.01 } ?? false,
   "step \(reversals.first.map { $0.2 - $0.1 } ?? -1)")

// The mitigation: the smoother must turn that step into a ramp of many hops,
// not a single jump. If this ever passes in one step, the discontinuity becomes
// an audible click.
var stepSm = GainSmoother(settings: s, sampleRate: 48_000)
stepSm.reset(initialGainDb: 0.5)
var hops = 0
while stepSm.process(targetGainDb: 6) < 5.5, hops < 1000 { hops += 1 }
ok("the smoother spreads the step over many hops", hops > 5, "took \(hops) hops")

// ---------- degenerate settings must not produce NaN ----------
var zero = LoudnessEqualizerSettings()
zero.maxBoostDb = 0; zero.maxCutDb = 0
let zg = GainComputer(settings: zero)
ok("zero boost and cut yields zero gain", abs(zg.desiredGainDb(forLevelDb: -30)) < 0.001)

var silly = LoudnessEqualizerSettings()
silly.compressionRatio = 0        // below 1 — the code clamps it
silly.compressionKneeDb = -5      // negative knee
let sg = GainComputer(settings: silly)
var sillyBad = 0
for level in stride(from: -100.0, through: 10.0, by: 1.0) {
    if !sg.desiredGainDb(forLevelDb: Float(level)).isFinite { sillyBad += 1 }
}
ok("invalid ratio/knee still yields finite gain", sillyBad == 0, "\(sillyBad) non-finite")

// ---------- GainSmoother ----------
var sm = GainSmoother(settings: s, sampleRate: 48_000)
sm.reset(initialGainDb: 0)

// Converges to the target, and never overshoots it on the way.
var overshoot = 0
var last: Float = 0
for _ in 0..<400 { last = sm.process(targetGainDb: 6) ; if last > 6.001 { overshoot += 1 } }
ok("smoother converges upward to the target", abs(last - 6) < 0.2, "reached \(last)")
ok("smoother never overshoots on the way up", overshoot == 0, "\(overshoot) overshoots")

sm.reset(initialGainDb: 0)
var underShoot = 0
for _ in 0..<400 { last = sm.process(targetGainDb: -4); if last < -4.001 { underShoot += 1 } }
ok("smoother converges downward", abs(last + 4) < 0.2, "reached \(last)")
ok("smoother never undershoots", underShoot == 0, "\(underShoot) undershoots")

// It must SMOOTH, not jump — a single step reaching the target is not smoothing.
sm.reset(initialGainDb: 0)
let firstStep = sm.process(targetGainDb: 6)
ok("one step does not jump to the target", firstStep < 6 * 0.9, "first step went to \(firstStep)")
ok("but it does move", firstStep > 0, "first step \(firstStep)")

// reset() actually resets.
sm.reset(initialGainDb: 3)
ok("reset sets the starting point", abs(sm.process(targetGainDb: 3) - 3) < 0.001)

// Every output finite, for a target that jumps around.
var smBad = 0
sm.reset(initialGainDb: 0)
for t in [6, -4, 0, 6, -4, 6, 0, -4] as [Float] {
    for _ in 0..<50 { if !sm.process(targetGainDb: t).isFinite { smBad += 1 } }
}
ok("stays finite through 400 target changes", smBad == 0, "\(smBad) non-finite")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Loud.swift" "$WORK/main.swift" -o "$WORK/loud" 2>&1 | grep -E "error" || true
"$WORK/loud"
