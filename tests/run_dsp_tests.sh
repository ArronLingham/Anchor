#!/bin/bash
# Pins the per-app EQ / loudness DSP — BiquadMath, SoftLimiter and the
# loudness maths.
#
# This is ~1,800 lines of pure arithmetic that had NO test at all, and it is the
# worst kind of code to leave untested: a wrong coefficient does not crash, it
# makes the user's audio quietly wrong. Distortion, a filter that rings, a
# limiter that clips — all of it sounds like "my headphones are bad", not like a
# bug in a notch app.
#
# The central test evaluates the ACTUAL frequency response H(z) from the
# returned coefficients and checks it against the requested gain. That is what
# catches a transposed numerator/denominator or a bad normalisation, which
# eyeballing the formula does not.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/DSP.swift" <<'PYX'
import re, sys

def grab(path, names):
    """Pull named static members out of a file, brace-balanced.

    Surgical rather than whole-enum: the enums also carry members that need
    Accelerate and EQSettings, which cannot compile standalone."""
    src = open(path).read()
    out = []
    for n in names:
        m = re.search(r'\n(    (?:@inline\(__always\)\n    )?static (?:func|var|let) ' + n + r'\b)', src)
        if not m:
            sys.exit(f"missing {n} in {path}")
        i = m.start(1)
        # A `static let x = 1.4` one-liner has no body. Anything else does —
        # but its `{` may be several lines down when the signature wraps, so
        # only treat it as a one-liner when the declaration is a let/var whose
        # first line already has an `=` and no brace.
        line_end = src.index("\n", i)
        first = src[i:line_end]
        if (" func " not in first) and ("=" in first) and ("{" not in first):
            out.append(first); continue
        depth, j = 0, src.index("{", i)
        k = j
        while True:
            if src[k] == "{": depth += 1
            elif src[k] == "}":
                depth -= 1
                if depth == 0: break
            k += 1
        out.append(src[i:k+1])
    return "\n\n".join(out)

parts = ["import Foundation\n"]
parts.append("enum BiquadMath {\n" + grab(
    "Anchor/Audio/PerApp/EQ/BiquadMath.swift",
    ["graphicEQQ", "peakingEQCoefficients", "lowShelfCoefficients",
     "highShelfCoefficients", "highPassCoefficients"]) + "\n}")
parts.append("enum SoftLimiter {\n" + grab(
    "Anchor/Audio/PerApp/Engine/SoftLimiter.swift",
    ["threshold", "ceiling", "headroom", "apply"]) + "\n}")
parts.append("enum LoudnessEqualizerMath {\n" + grab(
    "Anchor/Audio/PerApp/Loudness/LoudnessEqualizerMath.swift",
    ["dbToLinear", "linearToDb", "meanSquareToDb", "rmsFromMeanSquare",
     "clamp", "timeConstantCoefficient"]) + "\n}")

body = "\n\n".join(parts).replace("@inline(__always)\n", "")
open(sys.argv[1], "w").write(body + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

// Evaluate |H(e^jw)| for coefficients [b0,b1,b2,a1,a2] normalised by a0.
func magnitude(_ c: [Double], at freq: Double, sampleRate: Double) -> Double {
    let w = 2.0 * Double.pi * freq / sampleRate
    // numerator b0 + b1 z^-1 + b2 z^-2 ; denominator 1 + a1 z^-1 + a2 z^-2
    let nRe = c[0] + c[1] * cos(w) + c[2] * cos(2*w)
    let nIm = -(c[1] * sin(w) + c[2] * sin(2*w))
    let dRe = 1.0 + c[3] * cos(w) + c[4] * cos(2*w)
    let dIm = -(c[3] * sin(w) + c[4] * sin(2*w))
    return sqrt(nRe*nRe + nIm*nIm) / sqrt(dRe*dRe + dIm*dIm)
}
func db(_ linear: Double) -> Double { 20 * log10(linear) }

let sr = 48_000.0

// ---------- peaking EQ: the response must match the requested gain ----------
for gain in [-12, -6, -3, 3, 6, 12] as [Float] {
    for f in [100.0, 1_000.0, 5_000.0] {
        let c = BiquadMath.peakingEQCoefficients(frequency: f, gainDB: gain, q: 1.4, sampleRate: sr)
        let got = db(magnitude(c, at: f, sampleRate: sr))
        ok("peaking \(Int(f))Hz @ \(gain)dB hits its gain", abs(got - Double(gain)) < 0.15,
           String(format: "got %.2f dB", got))
    }
}

// 0 dB must be a true passthrough at EVERY frequency, not just the centre.
let flat = BiquadMath.peakingEQCoefficients(frequency: 1_000, gainDB: 0, q: 1.4, sampleRate: sr)
var worst = 0.0
for f in stride(from: 20.0, through: 20_000.0, by: 97.0) {
    worst = max(worst, abs(db(magnitude(flat, at: f, sampleRate: sr))))
}
ok("0 dB is flat across the whole band", worst < 0.001, String(format: "worst %.5f dB", worst))

// Far from the centre frequency a peaking filter must do nothing.
let peak = BiquadMath.peakingEQCoefficients(frequency: 1_000, gainDB: 12, q: 1.4, sampleRate: sr)
ok("peaking leaves 20 Hz alone",     abs(db(magnitude(peak, at: 20, sampleRate: sr))) < 0.5)
ok("peaking leaves 18 kHz alone",    abs(db(magnitude(peak, at: 18_000, sampleRate: sr))) < 0.5)

// Boost and cut of the same size are mirror images.
for f in [200.0, 2_000.0] {
    let up = BiquadMath.peakingEQCoefficients(frequency: f, gainDB: 6, q: 1.4, sampleRate: sr)
    let dn = BiquadMath.peakingEQCoefficients(frequency: f, gainDB: -6, q: 1.4, sampleRate: sr)
    let sum = db(magnitude(up, at: f, sampleRate: sr)) + db(magnitude(dn, at: f, sampleRate: sr))
    ok("+6/-6 dB at \(Int(f))Hz cancel", abs(sum) < 0.05, String(format: "sum %.3f dB", sum))
}

// ---------- STABILITY: every filter's poles must be inside the unit circle ----------
// An unstable biquad does not sound wrong, it screams. |a2| < 1 and
// |a1| < 1 + a2 is the standard triangle condition.
var unstable: [String] = []
for f in [20.0, 60.0, 200.0, 1_000.0, 6_000.0, 12_000.0, 20_000.0] {
    for g in [-24, -12, 0, 12, 24] as [Float] {
        for q in [0.5, 1.4, 4.0] {
            let c = BiquadMath.peakingEQCoefficients(frequency: f, gainDB: g, q: q, sampleRate: sr)
            let a1 = c[3], a2 = c[4]
            if !(abs(a2) < 1.0 && abs(a1) < 1.0 + a2) {
                unstable.append("f=\(Int(f)) g=\(g) q=\(q)")
            }
            if !c.allSatisfy({ $0.isFinite }) { unstable.append("non-finite f=\(Int(f)) g=\(g)") }
        }
    }
}
ok("every peaking filter is stable across 105 combinations", unstable.isEmpty,
   "unstable: \(unstable.prefix(3))")

// Nyquist and DC are the edges where naive coefficient maths blows up.
for f in [1.0, 23_999.0] {
    let c = BiquadMath.peakingEQCoefficients(frequency: f, gainDB: 6, q: 1.4, sampleRate: sr)
    ok("coefficients finite at \(Int(f))Hz", c.allSatisfy { $0.isFinite }, "\(c)")
}

// ---------- SoftLimiter ----------
ok("below threshold passes through", SoftLimiter.apply(0.5) == 0.5)
ok("zero stays zero",                SoftLimiter.apply(0) == 0)
ok("negative below threshold",       SoftLimiter.apply(-0.5) == -0.5)

// The guarantee in its own doc comment: never exceeds the ceiling, for ANY
// finite input. A limiter that lets one sample through clips audibly.
var overs = 0
for x in stride(from: -50.0, through: 50.0, by: 0.01) {
    let y = SoftLimiter.apply(Float(x))
    if abs(y) > SoftLimiter.ceiling + 1e-6 { overs += 1 }
    if !y.isFinite { overs += 1 }
}
ok("never exceeds the ceiling across ±50 (10,001 samples)", overs == 0, "\(overs) violations")

// Monotonic and sign-preserving — a limiter that folds back inverts the wave.
var nonMonotonic = 0
var prev = SoftLimiter.apply(-50)
for x in stride(from: -49.99, through: 50.0, by: 0.01) {
    let y = SoftLimiter.apply(Float(x))
    if y < prev - 1e-7 { nonMonotonic += 1 }
    prev = y
}
ok("monotonic across the whole range", nonMonotonic == 0, "\(nonMonotonic) reversals")
ok("odd symmetry", abs(SoftLimiter.apply(3.0) + SoftLimiter.apply(-3.0)) < 1e-6)
// The guarantee is `<= ceiling`, not `< ceiling`. The curve is asymptotic in
// real arithmetic but Float runs out of mantissa: measured, it is still below
// at 1e3 (0.999997) and saturates to exactly 1.0 by 1e5. Both are correct and
// both are safe — what would NOT be safe is exceeding it, which is asserted
// over 10,001 samples above.
ok("large input stays at or below the ceiling", SoftLimiter.apply(1e6) <= SoftLimiter.ceiling)
ok("still strictly below the ceiling at 1e3",
   SoftLimiter.apply(1e3) < SoftLimiter.ceiling && SoftLimiter.apply(1e3) > 0.9999)
ok("saturates to the ceiling by 1e5 (Float precision, not a bug)",
   SoftLimiter.apply(1e5) == SoftLimiter.ceiling)
ok("output is always above the threshold once limiting",
   SoftLimiter.apply(1e6) > SoftLimiter.threshold)
ok("continuous at the threshold",
   abs(SoftLimiter.apply(SoftLimiter.threshold) - SoftLimiter.threshold) < 1e-6)
ok("just above threshold barely moves",
   abs(SoftLimiter.apply(SoftLimiter.threshold + 1e-4) - SoftLimiter.threshold) < 1e-3)

// ---------- LoudnessEqualizerMath ----------
for d in [-60, -20, -6, 0, 6, 20] as [Float] {
    let round = LoudnessEqualizerMath.linearToDb(LoudnessEqualizerMath.dbToLinear(d))
    ok("dB round trip at \(d)", abs(round - d) < 0.001, "got \(round)")
}
ok("0 dB is unity gain", abs(LoudnessEqualizerMath.dbToLinear(0) - 1) < 1e-6)
ok("-6 dB is about half amplitude", abs(LoudnessEqualizerMath.dbToLinear(-6) - 0.5012) < 0.001)
ok("linearToDb(0) does not return -infinity",
   LoudnessEqualizerMath.linearToDb(0).isFinite, "\(LoudnessEqualizerMath.linearToDb(0))")

ok("clamp low",  LoudnessEqualizerMath.clamp(-5, min: 0, max: 10) == 0)
ok("clamp high", LoudnessEqualizerMath.clamp(50, min: 0, max: 10) == 10)
ok("clamp pass", LoudnessEqualizerMath.clamp(5,  min: 0, max: 10) == 5)
ok("clamp at bounds", LoudnessEqualizerMath.clamp(0, min: 0, max: 10) == 0
                   && LoudnessEqualizerMath.clamp(10, min: 0, max: 10) == 10)

// A smoothing coefficient outside [0,1] makes the smoother diverge instead of
// settle — a value of exactly 1 never moves, above 1 oscillates outward.
var badCoeff: [String] = []
for t in [1.0, 5.0, 50.0, 250.0, 1000.0] as [Float] {
    for step in [1.0, 5.0, 10.0] as [Float] {
        let c = LoudnessEqualizerMath.timeConstantCoefficient(timeMs: t, stepMs: step)
        if !(c >= 0 && c <= 1 && c.isFinite) { badCoeff.append("t=\(t) step=\(step) -> \(c)") }
    }
}
ok("every smoothing coefficient is in [0,1]", badCoeff.isEmpty, "\(badCoeff.prefix(3))")
ok("zero time constant does not divide by zero",
   LoudnessEqualizerMath.timeConstantCoefficient(timeMs: 0, stepMs: 10).isFinite)

ok("meanSquareToDb(0) is finite", LoudnessEqualizerMath.meanSquareToDb(0).isFinite)
ok("rms of 0.25 mean-square is 0.5",
   abs(LoudnessEqualizerMath.rmsFromMeanSquare(0.25) - 0.5) < 1e-6)

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/DSP.swift" "$WORK/main.swift" -o "$WORK/dsp" 2>&1 | grep -E "error" || true
"$WORK/dsp"
