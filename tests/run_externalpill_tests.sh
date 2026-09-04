#!/bin/bash
# Pins the external-display pill's hover geometry.
#
# The pill on a display without a physical notch is opened by hovering it, and
# two things about that were wrong before this harness existed:
#
#   1. `NotchHoverManager` published ONE global `isHoveringExtendedArea: Bool`,
#      which every per-screen `ContentView` observed. The pointer is only ever
#      over one display, so hovering the band on the built-in opened the notch
#      on the external monitor too, and vice versa.
#
#   2. The band was sized from `AppDelegate.shared.vm.closedNotchSize` — the
#      singleton view model, which in multi-window mode drives no window at all
#      and is sized for `NSScreen.main`. On the external display the band was
#      therefore the width of the *built-in's* physical notch.
#
# Both are expressible as "which displays does this point extend into", so the
# whole thing is one pure function and this harness compiles the real source
# file rather than a copy of it.
#
# MEASURED on this machine, 2026-09-03, with NSScreen (scratchpad/probe/sizes):
#   Built-in Retina Display  frame=(0,0,1470,956)      safeTop=32
#                            auxTopLeft=646 auxTopRight=645 -> closed pill 183x32
#   EK271 GD                 frame=(-1920,-59,1920,1080) safeTop=0
#                            auxTopLeft/Right = nil -> closed pill 135x32
#                            (closedNotchWidth=135, nonNotchHeight=32)
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import CoreGraphics

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

typealias G = NotchHoverGeometry
typealias D = NotchHoverGeometry.Display

// Real hardware, measured. See the header.
let builtIn = D(name: "Built-in Retina Display",
                frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                closedNotchSize: CGSize(width: 183, height: 32))
let external = D(name: "EK271 GD",
                 frame: CGRect(x: -1920, y: -59, width: 1920, height: 1080),
                 closedNotchSize: CGSize(width: 135, height: 32))
let both = [builtIn, external]

// ---------- band geometry ----------
let bb = G.extendedRect(screenFrame: builtIn.frame, closedNotchSize: builtIn.closedNotchSize)
ok("band is the pill plus 40pt of width", bb.width == 183 + 40, "\(bb.width)")
ok("band is the pill plus 12pt of height", bb.height == 32 + 12, "\(bb.height)")
ok("band is centred on the display", bb.midX == builtIn.frame.midX, "\(bb.midX) vs \(builtIn.frame.midX)")
ok("band sits flush with the top edge", bb.maxY == builtIn.frame.maxY, "\(bb.maxY) vs \(builtIn.frame.maxY)")

let eb = G.extendedRect(screenFrame: external.frame, closedNotchSize: external.closedNotchSize)
ok("external band is centred on the external display", eb.midX == -960, "\(eb.midX)")
ok("external band sits flush with the external top edge", eb.maxY == 1021, "\(eb.maxY)")
ok("external band is sized from the EXTERNAL pill, not the built-in's",
   eb.width == 135 + 40, "\(eb.width)")

// The two displays' bands must not overlap, or "which screen" is meaningless.
ok("the two bands are disjoint", !bb.intersects(eb))

// ---------- the defect: hovering one display must not name the other ----------
let overBuiltIn = CGPoint(x: 735, y: 940)      // inside the built-in band
ok("built-in band contains the built-in probe point", bb.contains(overBuiltIn))
let a = G.hoveredDisplayNames(point: overBuiltIn, displays: both)
ok("hovering the built-in names only the built-in",
   a == ["Built-in Retina Display"], "\(a)")

let overExternal = CGPoint(x: -960, y: 1000)   // inside the external band
ok("external band contains the external probe point", eb.contains(overExternal))
let b = G.hoveredDisplayNames(point: overExternal, displays: both)
ok("hovering the external names only the external", b == ["EK271 GD"], "\(b)")

// NEGATIVE CONTROL for defect 2. This point is inside the band the OLD code
// built for the external display (sized 223 wide from the built-in's 183pt
// pill) and outside the band its own 135pt pill earns. If anyone reintroduces
// a shared notch size, this flips to a match and the test goes red.
let wrongSizeOnly = CGPoint(x: -1060, y: 1000)
let wrongBand = G.extendedRect(screenFrame: external.frame,
                               closedNotchSize: builtIn.closedNotchSize)
ok("the probe point IS inside a built-in-sized band on the external display",
   wrongBand.contains(wrongSizeOnly))
ok("but the external display's own band does not reach it",
   !G.hoveredDisplayNames(point: wrongSizeOnly, displays: both).contains("EK271 GD"))

// ---------- misses ----------
ok("the middle of the built-in screen extends into nothing",
   G.hoveredDisplayNames(point: CGPoint(x: 735, y: 400), displays: both).isEmpty)
ok("the middle of the external screen extends into nothing",
   G.hoveredDisplayNames(point: CGPoint(x: -960, y: 400), displays: both).isEmpty)
ok("the top-LEFT corner of the external screen extends into nothing",
   G.hoveredDisplayNames(point: CGPoint(x: -1900, y: 1015), displays: both).isEmpty)
ok("just below the external band is a miss",
   G.hoveredDisplayNames(point: CGPoint(x: -960, y: 976), displays: both).isEmpty)
ok("just left of the external band is a miss",
   G.hoveredDisplayNames(point: CGPoint(x: -1048, y: 1000), displays: both).isEmpty)
ok("just right of the external band is a miss",
   G.hoveredDisplayNames(point: CGPoint(x: -872, y: 1000), displays: both).isEmpty)

// ---------- the external display is ABOVE the built-in here ----------
// Its top edge is at y=1021, the built-in's at y=956. A point at the external's
// top edge is off the built-in screen entirely, which is what makes the global
// bool so wrong: it opened a notch on a display the pointer was nowhere near.
ok("the external top edge is above the built-in's",
   external.frame.maxY > builtIn.frame.maxY, "\(external.frame.maxY) vs \(builtIn.frame.maxY)")
ok("a point in the external band is outside the built-in's frame ENTIRELY",
   !builtIn.frame.contains(overExternal))

// ---------- a single display still works ----------
ok("with only the built-in attached, its band still matches",
   G.hoveredDisplayNames(point: overBuiltIn, displays: [builtIn]) == ["Built-in Retina Display"])
ok("with only the external attached, its band still matches",
   G.hoveredDisplayNames(point: overExternal, displays: [external]) == ["EK271 GD"])
ok("no displays means no hover", G.hoveredDisplayNames(point: overBuiltIn, displays: []).isEmpty)

// ---------- degenerate pill sizes must not produce a band that swallows the screen ----------
let zero = D(name: "zero", frame: external.frame, closedNotchSize: .zero)
let zb = G.extendedRect(screenFrame: zero.frame, closedNotchSize: .zero)
ok("a zero-size pill still yields only the 40x12 padding band",
   zb.width == 40 && zb.height == 12, "\(zb)")
ok("a zero-size pill does not match the far corner",
   G.hoveredDisplayNames(point: CGPoint(x: -1900, y: 1015), displays: [zero]).isEmpty)

// ---------- sweep: every point matches at most one display ----------
var multi = 0, matched = 0
for x in stride(from: -1920.0, through: 1470.0, by: 7.0) {
    for y in stride(from: -59.0, through: 1021.0, by: 7.0) {
        let n = G.hoveredDisplayNames(point: CGPoint(x: x, y: y), displays: both)
        if n.count > 1 { multi += 1 }
        if n.count == 1 { matched += 1 }
    }
}
ok("no point on either display extends into two displays at once", multi == 0, "\(multi)")
ok("the sweep does find the bands at all (harness is not vacuous)", matched > 0, "\(matched)")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O Anchor/Managers/Input/NotchHoverGeometry.swift "$WORK/main.swift" \
    -o "$WORK/extpill" 2>&1 | grep -E "error" || true
"$WORK/extpill"
