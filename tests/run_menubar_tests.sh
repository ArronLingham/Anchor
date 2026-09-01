#!/bin/bash
# Pins MenuBarReadoutFormatter — the fixed-width rules for the menu bar readout.
#
# Width is the whole difficulty. The menu bar is shared with every other app,
# and a readout that grows by one character when CPU crosses 10% shoves every
# icon to its left, once a second, for as long as the feature is on. The tests
# below assert *character counts*, not just values, because a formatter that
# produces correct-but-variable-width text looks completely fine in isolation
# and is intolerable in place.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Fmt.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/System/MenuBarReadoutManager.swift").read()
fmt = re.search(r'(enum MenuBarReadoutFormatter \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + fmt + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func eq(_ label: String, _ got: String?, _ want: String?) {
    if got == want { passes += 1 } else {
        failures += 1
        print("  FAIL \(label): got \(got.map { "'\($0)'" } ?? "nil"), want \(want.map { "'\($0)'" } ?? "nil")")
    }
}
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}

// ---------- percent: always exactly 4 characters ----------
eq("0%",   MenuBarReadoutFormatter.percent(0),   "  0%")
eq("5%",   MenuBarReadoutFormatter.percent(5),   "  5%")
eq("42%",  MenuBarReadoutFormatter.percent(42),  " 42%")
eq("100%", MenuBarReadoutFormatter.percent(100), "100%")
eq("rounds", MenuBarReadoutFormatter.percent(42.6), " 43%")

// The width invariant, over the whole range.
var widths = Set<Int>()
for v in stride(from: 0.0, through: 100.0, by: 0.5) {
    widths.insert(MenuBarReadoutFormatter.percent(v).count)
}
ok("percent is one fixed width across 0–100", widths == [4], "widths seen: \(widths.sorted())")

// Values that should never appear, but must not produce ragged text if they do.
eq("clamps negative",   MenuBarReadoutFormatter.percent(-5),  "  0%")
eq("clamps above 100",  MenuBarReadoutFormatter.percent(150), "100%")
eq("NaN is not 'nan%'", MenuBarReadoutFormatter.percent(.nan), "  0%")
eq("infinity clamps",   MenuBarReadoutFormatter.percent(.infinity), "100%")

// ---------- rate: always exactly 5 characters ----------
eq("0 B",    MenuBarReadoutFormatter.rate(0),         "   0B")
eq("999 B",  MenuBarReadoutFormatter.rate(999),       " 999B")
eq("1 KB",   MenuBarReadoutFormatter.rate(1_000),     "   1K")
eq("940 KB", MenuBarReadoutFormatter.rate(940_000),   " 940K")
eq("1.2 MB", MenuBarReadoutFormatter.rate(1_200_000), " 1.2M")
eq("12 MB",  MenuBarReadoutFormatter.rate(12_000_000),"  12M")
eq("1.5 GB", MenuBarReadoutFormatter.rate(1_500_000_000), " 1.5G")

var rateWidths = Set<Int>()
for v in [0, 1, 999, 1_000, 9_999, 999_999, 1_000_000, 9_900_000,
          10_000_000, 999_000_000, 1_000_000_000, 50_000_000_000] as [Double] {
    let s = MenuBarReadoutFormatter.rate(v)
    rateWidths.insert(s.count)
}
ok("rate is one fixed width across every magnitude", rateWidths == [5],
   "widths seen: \(rateWidths.sorted())")

// The decimal-drop at 10 exists precisely to hold the width — without it
// "10.0M" is 5 chars but " 9.9M" is 5 too, and "100.0M" would be 6.
ok("9.9M and 100M are the same width",
   MenuBarReadoutFormatter.rate(9_900_000).count == MenuBarReadoutFormatter.rate(100_000_000).count)

eq("negative rate clamps", MenuBarReadoutFormatter.rate(-500), "   0B")
eq("NaN rate", MenuBarReadoutFormatter.rate(.nan), "   0B")

// ---------- line assembly ----------
eq("nothing enabled returns nil",
   MenuBarReadoutFormatter.line(cpu: nil, memory: nil, netIn: nil, netOut: nil), nil)
eq("cpu only",
   MenuBarReadoutFormatter.line(cpu: 42, memory: nil, netIn: nil, netOut: nil), "CPU  42%")
eq("cpu and memory",
   MenuBarReadoutFormatter.line(cpu: 42, memory: 71, netIn: nil, netOut: nil),
   "CPU  42%  RAM  71%")
eq("network both directions",
   MenuBarReadoutFormatter.line(cpu: nil, memory: nil, netIn: 1_200_000, netOut: 940_000),
   "\u{2193} 1.2M \u{2191} 940K")
eq("download only",
   MenuBarReadoutFormatter.line(cpu: nil, memory: nil, netIn: 1_000, netOut: nil),
   "\u{2193}   1K")
eq("upload only",
   MenuBarReadoutFormatter.line(cpu: nil, memory: nil, netIn: nil, netOut: 1_000),
   "\u{2191}   1K")

// The full line must also be width-stable, which is the property that actually
// matters in the menu bar — the parts being fixed is only useful if the whole
// is too.
var lineWidths = Set<Int>()
for (c, m, i, o) in [(0.0, 0.0, 0.0, 0.0), (5.0, 9.0, 1.0, 1.0),
                     (42.0, 71.0, 1_200_000.0, 940_000.0),
                     (100.0, 100.0, 5_000_000_000.0, 5_000_000_000.0)] {
    lineWidths.insert(MenuBarReadoutFormatter.line(cpu: c, memory: m, netIn: i, netOut: o)!.count)
}
ok("the full line never changes width", lineWidths.count == 1,
   "widths seen: \(lineWidths.sorted())")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Fmt.swift" "$WORK/main.swift" -o "$WORK/mb" 2>&1 | grep -E "error" || true
"$WORK/mb"
