#!/bin/bash
# Pins PerAppVolumeMode, which drives the per-app volume button.
#
# The button shows symbols[step] for levels[step] and cycles with
# (step + 1) % levels.count. If the two arrays ever disagree in length the
# control either shows the wrong icon for a level or indexes past the end, so
# that pairing is the thing worth pinning.
#
# The two modes also mean different things and must not drift into each other:
#   presets — four steps, and step 0 IS silence (hence no separate mute button)
#   booster — three steps, none below normal (hence mute as its own control)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Mode.swift" <<'PYX'
import re, sys
src = open("Anchor/Enums/generic.swift").read()
i = src.index("enum PerAppVolumeMode")
depth, k = 0, src.index("{", i)
while True:
    if src[k] == "{": depth += 1
    elif src[k] == "}":
        depth -= 1
        if depth == 0: break
    k += 1
body = src[i:k+1]
body = body.replace(", Defaults.Serializable", "").replace("Defaults.Serializable, ", "")
body = re.sub(r'String\(localized: ("(?:[^"\\]|\\.)*")\)', r'\1', body)
open(sys.argv[1], "w").write("import Foundation\n\n" + body + "\n")
PYX

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

for mode in PerAppVolumeMode.allCases {
    // The invariant the button depends on.
    ok("\(mode.rawValue): one symbol per level",
       mode.symbols.count == mode.levels.count,
       "\(mode.levels.count) levels vs \(mode.symbols.count) symbols")
    ok("\(mode.rawValue): every level is finite and in range",
       mode.levels.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 2 },
       "\(mode.levels)")
    ok("\(mode.rawValue): levels ascend",
       zip(mode.levels, mode.levels.dropFirst()).allSatisfy { $0 < $1 },
       "\(mode.levels)")
    ok("\(mode.rawValue): no empty symbol", mode.symbols.allSatisfy { !$0.isEmpty })
    ok("\(mode.rawValue): detail is written", !mode.detail.isEmpty)
    ok("\(mode.rawValue): name is written", !mode.localizedName.isEmpty)
    // Cycling must visit every step and return to the start.
    var seen = Set<Int>(); var step = 0
    for _ in 0..<mode.levels.count { seen.insert(step); step = (step + 1) % mode.levels.count }
    ok("\(mode.rawValue): cycling visits every step", seen.count == mode.levels.count)
    ok("\(mode.rawValue): cycling wraps to 0", step == 0)
}

// The distinction between the modes IS the feature.
ok("presets has four steps", PerAppVolumeMode.presets.levels.count == 4)
ok("presets step 0 is silence", PerAppVolumeMode.presets.levels[0] == 0)
ok("presets step 1 is normal", PerAppVolumeMode.presets.levels[1] == 1.0)
ok("booster has three steps", PerAppVolumeMode.booster.levels.count == 3)
ok("booster never goes below normal",
   PerAppVolumeMode.booster.levels.allSatisfy { $0 >= 1.0 }, "\(PerAppVolumeMode.booster.levels)")
ok("booster has no silent step",
   !PerAppVolumeMode.booster.levels.contains(0))
// Only presets folds mute into the stepper, which is why only booster shows a
// separate mute button.
ok("only presets contains silence",
   PerAppVolumeMode.allCases.filter { $0.levels.contains(0) } == [.presets])
ok("both modes reach full boost",
   PerAppVolumeMode.allCases.allSatisfy { $0.levels.last == 2.0 })
ok("raw values are stable (they are persisted)",
   PerAppVolumeMode.presets.rawValue == "Preset volumes"
   && PerAppVolumeMode.booster.rawValue == "Volume booster")

// ---- step derivation: what the button shows for a given gain ----
// This has been wrong once. A gain of 0 with isMuted false is reachable from
// the slider this control replaced and is still sitting in perAppAudioStates;
// matching it to the nearest non-zero level showed "Regular" on a silent app.
ok("presets: muted is step 0",
   PerAppVolumeMode.presets.step(forVolume: 1.0, isMuted: true) == 0)
ok("presets: a zero gain is step 0 even without the mute flag",
   PerAppVolumeMode.presets.step(forVolume: 0.0, isMuted: false) == 0)
ok("presets: a near-zero gain is still silence",
   PerAppVolumeMode.presets.step(forVolume: 0.001, isMuted: false) == 0)
ok("presets: 1.0 is Regular",  PerAppVolumeMode.presets.step(forVolume: 1.0, isMuted: false) == 1)
ok("presets: 1.5 is Loud",     PerAppVolumeMode.presets.step(forVolume: 1.5, isMuted: false) == 2)
ok("presets: 2.0 is Louder",   PerAppVolumeMode.presets.step(forVolume: 2.0, isMuted: false) == 3)

// Values from the old slider land on the nearest step rather than off the end.
for v in [Float(0.2), 0.4, 0.6, 0.75, 0.9, 1.1, 1.3, 1.7, 1.9, 2.0] {
    let step = PerAppVolumeMode.presets.step(forVolume: v, isMuted: false)
    ok("presets: gain \(v) maps into range", step >= 0 && step < PerAppVolumeMode.presets.levels.count, "got \(step)")
    ok("presets: a non-zero gain is never silence", step != 0, "gain \(v) read as muted")
}

// Booster has no silent step, so mute is tracked separately and never folds in.
ok("booster: 1.0 is the first step", PerAppVolumeMode.booster.step(forVolume: 1.0, isMuted: false) == 0)
ok("booster: muted still reports its gain step, since mute is its own control",
   PerAppVolumeMode.booster.step(forVolume: 2.0, isMuted: true) == 2)
ok("booster: a zero gain is not treated as a step",
   PerAppVolumeMode.booster.step(forVolume: 0.0, isMuted: false) == 0)

// Cycling from any derived step stays in range.
for mode in PerAppVolumeMode.allCases {
    for v in [Float(0), 0.5, 1.0, 1.5, 2.0] {
        let step = mode.step(forVolume: v, isMuted: false)
        let next = (step + 1) % mode.levels.count
        ok("\(mode.rawValue): cycling from gain \(v) stays in range",
           next >= 0 && next < mode.levels.count)
    }
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Mode.swift" "$WORK/main.swift" -o "$WORK/vm" 2>&1 | grep -E "error" || true
"$WORK/vm"
