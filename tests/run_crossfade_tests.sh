#!/bin/bash
# Pins CrossfadeState — the state machine that fades between two audio taps
# when the output device changes under a per-app volume/EQ session.
#
# The property that matters is EQUAL POWER: primary² + secondary² must equal 1
# at every point of the fade. If it does not, the audio dips or swells in the
# middle of the crossfade — the classic "hole in the middle" you hear when
# someone crossfades linearly instead. It is a one-line mistake
# (`1 - progress` instead of `cos(progress * pi/2)`) and it is inaudible in code
# review.
#
# Also pinned: the warmup gate. Destroying the primary tap before the secondary
# has produced samples is a hard audio dropout.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/CF.swift" <<'PYX'
import re, sys
src = open("Anchor/Audio/PerApp/Engine/CrossfadeState.swift").read()
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
out = block(r'enum CrossfadePhase\b') + "\n\n" + block(r'(?:nonisolated )?struct CrossfadeState\b')
out = out.replace("@inline(__always)\n", "")
# OSMemoryBarrier lives in Darwin.C; a no-op keeps the state machine testable
# without pulling the whole header in.
shim = "import Foundation\nfunc OSMemoryBarrier() {}\n\n"
open(sys.argv[1], "w").write(shim + out + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

// ---------- initial state ----------
var s = CrossfadeState()
ok("starts idle",            s.phase == .idle)
ok("starts inactive",        !s.isActive)
ok("starts at zero progress", s.progress == 0)
ok("idle plays the primary at full volume",   s.primaryMultiplier == 1.0)
ok("idle plays the secondary at full volume", s.secondaryMultiplier == 1.0)

// ---------- warmup ----------
s.beginWarmup()
ok("warmup phase set",     s.phase == .warmingUp)
ok("warmup is active",     s.isActive)
ok("primary stays FULL during warmup",  s.primaryMultiplier == 1.0)
ok("secondary is MUTED during warmup",  s.secondaryMultiplier == 0.0)
ok("warmup starts incomplete", !s.isWarmupComplete)

// The gate: the primary must not be torn down before the secondary is producing.
_ = s.updateProgress(samples: CrossfadeState.minimumWarmupSamples - 1)
ok("one sample short is still incomplete", !s.isWarmupComplete,
   "processed \(s.secondarySamplesProcessed) of \(CrossfadeState.minimumWarmupSamples)")
_ = s.updateProgress(samples: 1)
ok("exactly at the threshold completes warmup", s.isWarmupComplete)

// Progress must NOT advance during warmup — only the sample counter does.
ok("progress stays at zero through warmup", s.progress == 0, "got \(s.progress)")

// ---------- crossfading ----------
s.beginCrossfading()
ok("crossfade phase set", s.phase == .crossfading)
ok("counters reset on entry", s.progress == 0)
s.totalSamples = 4800   // 100 ms at 48 kHz

// EQUAL POWER across the whole fade. This is the test.
var worstPowerError: Float = 0
var progressPoints: [Float] = []
var st = CrossfadeState()
st.beginWarmup(); st.beginCrossfading(); st.totalSamples = 4800
for _ in 0..<100 {
    let p = st.updateProgress(samples: 48)
    progressPoints.append(p)
    let power = st.primaryMultiplier * st.primaryMultiplier
              + st.secondaryMultiplier * st.secondaryMultiplier
    worstPowerError = max(worstPowerError, abs(power - 1.0))
}
ok("equal power holds across the whole fade", worstPowerError < 0.0001,
   String(format: "worst deviation %.6f", worstPowerError))

// Endpoints.
var e = CrossfadeState()
e.beginWarmup(); e.beginCrossfading(); e.totalSamples = 1000
ok("at progress 0 the primary is full",   abs(e.primaryMultiplier - 1.0) < 0.0001)
ok("at progress 0 the secondary is silent", abs(e.secondaryMultiplier - 0.0) < 0.0001)
_ = e.updateProgress(samples: 500)
ok("at the midpoint both are ~0.707 (equal power, not 0.5)",
   abs(e.primaryMultiplier - 0.7071) < 0.001 && abs(e.secondaryMultiplier - 0.7071) < 0.001,
   "primary \(e.primaryMultiplier), secondary \(e.secondaryMultiplier)")
_ = e.updateProgress(samples: 500)
ok("at the end the primary is silent",   abs(e.primaryMultiplier) < 0.0001)
ok("at the end the secondary is full",   abs(e.secondaryMultiplier - 1.0) < 0.0001)
ok("crossfade reports complete",         e.isCrossfadeComplete)

// Monotonic fade — a reversal is an audible wobble.
var reversals = 0
for i in 1..<progressPoints.count where progressPoints[i] < progressPoints[i-1] { reversals += 1 }
ok("progress is monotonic", reversals == 0, "\(reversals) reversals")

// ---------- clamping and degenerate input ----------
var c = CrossfadeState()
c.beginWarmup(); c.beginCrossfading(); c.totalSamples = 100
_ = c.updateProgress(samples: 100_000)
ok("progress clamps at 1.0", c.progress == 1.0, "got \(c.progress)")
ok("multipliers stay in range after overshoot",
   c.primaryMultiplier >= 0 && c.secondaryMultiplier <= 1.0001)

// totalSamples of 0 must not divide by zero.
var z = CrossfadeState()
z.beginWarmup(); z.beginCrossfading(); z.totalSamples = 0
let zp = z.updateProgress(samples: 10)
ok("zero totalSamples does not divide by zero", zp.isFinite, "got \(zp)")
ok("zero totalSamples clamps to 1.0", zp == 1.0, "got \(zp)")
// NOTE: the `max(1, totalSamples)` in updateProgress is redundant — a negative
// control removing it leaves every test green, because `min(1.0, .infinity)`
// already yields 1.0 and `min(1.0, .nan)` yields 1.0 too. The CLAMP is what
// makes this safe, not the max(). Kept as belt-and-braces, but it is not the
// guard, and this comment exists so nobody removes the clamp believing the
// max() is protecting them. (Third guard in this repo found to be inert by a
// negative control — run the control before trusting one.)
ok("it is the CLAMP that saves this, not the max()",
   min(Float(1.0), Float.infinity) == 1.0 && min(Float(1.0), Float.nan) == 1.0)

// Zero-sample buffers are normal at stream start.
var zs = CrossfadeState()
zs.beginWarmup()
_ = zs.updateProgress(samples: 0)
ok("a zero-sample buffer changes nothing", zs.secondarySamplesProcessed == 0)

// ---------- completion resets everything ----------
var f = CrossfadeState()
f.beginWarmup(); f.beginCrossfading(); f.totalSamples = 100
_ = f.updateProgress(samples: 100)
f.complete()
ok("complete returns to idle",        f.phase == .idle)
ok("complete clears progress",        f.progress == 0)
ok("complete clears the sample count", f.secondarySampleCount == 0)
ok("complete clears warmup counter",   f.secondarySamplesProcessed == 0)
ok("complete clears totalSamples",     f.totalSamples == 0)
ok("after complete the secondary is full volume (it was promoted)",
   f.secondaryMultiplier == 1.0)
ok("after complete the primary is full (nothing to fade)", f.primaryMultiplier == 1.0)

// ---------- a full cycle can run twice ----------
var t = CrossfadeState()
for cycle in 1...3 {
    t.beginWarmup()
    _ = t.updateProgress(samples: CrossfadeState.minimumWarmupSamples)
    ok("cycle \(cycle): warmup completes", t.isWarmupComplete)
    t.beginCrossfading(); t.totalSamples = 480
    _ = t.updateProgress(samples: 480)
    ok("cycle \(cycle): fade completes", t.isCrossfadeComplete)
    t.complete()
    ok("cycle \(cycle): back to idle", t.phase == .idle)
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/CF.swift" "$WORK/main.swift" -o "$WORK/cf" 2>&1 | grep -E "error" || true
"$WORK/cf"
