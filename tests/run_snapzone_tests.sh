#!/bin/bash
# Pins SnapZoneManager.Zone.frame — the geometry that decides where a window
# lands when it is snapped.
#
# Worth pinning because the failure is quiet and infuriating: a zone that is one
# pixel off, or that overlaps its neighbour, or that leaves a gap, looks almost
# right. The invariants below (halves tile exactly, thirds sum to the full
# width, corners meet at the centre) are the things a human would not notice
# until they had been annoyed by them for a week.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Extract the Zone enum. It is pure — no AX, no NSScreen — so it compiles alone
# against Foundation with a small NSRect shim.
python3 - "$WORK/Zone.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/SnapZoneManager.swift").read()
enum = re.search(r'(    enum Zone: Equatable, CaseIterable \{.*?\n    \})\n', src, re.S).group(1)
enum = "\n".join(line[4:] if line.startswith("    ") else line for line in enum.split("\n"))
open(sys.argv[1], "w").write("import Foundation\nimport CoreGraphics\n\ntypealias NSRect = CGRect\n\n" + enum + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import CoreGraphics

var passes = 0, failures = 0
func ok(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { passes += 1 } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}
func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.001 }

// A deliberately non-zero origin: a second display never starts at 0,0, and
// zones that ignore the origin work on the primary screen and break elsewhere.
let visible = CGRect(x: 100, y: 50, width: 1600, height: 1000)

// --- every zone must stay inside the visible frame ---
for zone in Zone.allCases {
    let f = zone.frame(in: visible)
    ok("\(zone.title) within bounds",
       f.minX >= visible.minX - 0.001 && f.maxX <= visible.maxX + 0.001 &&
       f.minY >= visible.minY - 0.001 && f.maxY <= visible.maxY + 0.001,
       "got \(f) vs \(visible)")
    ok("\(zone.title) non-empty", f.width > 0 && f.height > 0, "got \(f)")
}

// --- halves tile the screen exactly ---
let l = Zone.left.frame(in: visible), r = Zone.right.frame(in: visible)
ok("left+right widths sum", close(l.width + r.width, visible.width))
ok("left/right do not overlap", close(l.maxX, r.minX))
ok("halves full height", close(l.height, visible.height) && close(r.height, visible.height))

let t = Zone.topHalf.frame(in: visible), b = Zone.bottomHalf.frame(in: visible)
ok("top+bottom heights sum", close(t.height + b.height, visible.height))
ok("top/bottom do not overlap", close(b.maxY, t.minY))

// --- thirds tile exactly (the classic off-by-rounding case) ---
let t1 = Zone.leftThird.frame(in: visible)
let t2 = Zone.centreThird.frame(in: visible)
let t3 = Zone.rightThird.frame(in: visible)
ok("thirds sum to width", close(t1.width + t2.width + t3.width, visible.width))
ok("third 1|2 meet", close(t1.maxX, t2.minX))
ok("third 2|3 meet", close(t2.maxX, t3.minX))
ok("right third ends at edge", close(t3.maxX, visible.maxX))

// --- two-thirds line up with the thirds ---
ok("leftTwoThirds ends where rightThird starts",
   close(Zone.leftTwoThirds.frame(in: visible).maxX, t3.minX))
ok("rightTwoThirds starts where leftThird ends",
   close(Zone.rightTwoThirds.frame(in: visible).minX, t1.maxX))
ok("rightTwoThirds ends at edge",
   close(Zone.rightTwoThirds.frame(in: visible).maxX, visible.maxX))

// --- corners meet exactly at the centre, and tile the screen ---
let tl = Zone.topLeft.frame(in: visible), tr = Zone.topRight.frame(in: visible)
let bl = Zone.bottomLeft.frame(in: visible), br = Zone.bottomRight.frame(in: visible)
ok("corners meet at midX", close(tl.maxX, tr.minX) && close(bl.maxX, br.minX))
ok("corners meet at midY", close(bl.maxY, tl.minY) && close(br.maxY, tr.minY))
let oneCorner: CGFloat = tl.width * tl.height
let cornerArea: CGFloat = oneCorner * 4
let screenArea: CGFloat = visible.width * visible.height
ok("corners tile the screen", close(cornerArea, screenArea))

// --- maximize / margin / centre ---
ok("maximize is the whole visible frame", Zone.top.frame(in: visible) == visible)
let m = Zone.maximizeWithMargin.frame(in: visible)
ok("margin is inset on all sides",
   m.minX > visible.minX && m.maxX < visible.maxX &&
   m.minY > visible.minY && m.maxY < visible.maxY)
let c = Zone.centre.frame(in: visible)
ok("centre is centred horizontally", close(c.midX, visible.midX))
ok("centre is centred vertically", close(c.midY, visible.midY))
ok("centre is smaller than screen", c.width < visible.width && c.height < visible.height)

// --- a second display with negative origin (the case that breaks naive maths) ---
let external = CGRect(x: -1920, y: -59, width: 1920, height: 1080)
for zone in Zone.allCases {
    let f = zone.frame(in: external)
    ok("\(zone.title) respects negative origin",
       f.minX >= external.minX - 0.001 && f.maxY <= external.maxY + 0.001,
       "got \(f)")
}

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Zone.swift" "$WORK/main.swift" -o "$WORK/zones" 2>&1 | grep -E "error" || true
"$WORK/zones"
