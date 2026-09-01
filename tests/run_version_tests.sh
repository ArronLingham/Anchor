#!/bin/bash
# Pins VersionComparator and HomebrewOutdated.parse.
#
# Version comparison is wrong-but-plausible by default: "1.10" < "1.9"
# lexically, so a naive implementation reports every app in a 1.10 series as up
# to date and the bug is invisible until someone checks by hand. Every case
# below is a shape that appears in real Info.plist or Homebrew version fields.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/PackageUpdateManager.swift").read()
v = re.search(r'(enum VersionComparator \{.*?\n\})\n', src, re.S).group(1)
h = re.search(r'(enum HomebrewOutdated \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + v + "\n\n" + h + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
func cmp(_ l: String, _ r: String, _ want: VersionComparator.Order) {
    let got = VersionComparator.compare(l, r)
    if got == want { passes += 1 } else {
        failures += 1; print("  FAIL compare(\"\(l)\", \"\(r)\") = \(got), want \(want)")
    }
}

// ---------- the lexical trap ----------
cmp("1.9",  "1.10", .older)     // the bug this type exists to prevent
cmp("1.10", "1.9",  .newer)
cmp("2.9",  "2.10", .older)
cmp("1.0.9", "1.0.10", .older)
ok("1.10 is an upgrade over 1.9", VersionComparator.isUpgrade(installed: "1.9", available: "1.10"))
ok("1.9 is NOT an upgrade over 1.10", !VersionComparator.isUpgrade(installed: "1.10", available: "1.9"))

// ---------- ordinary ordering ----------
cmp("1.0", "2.0", .older)
cmp("2.0", "1.0", .newer)
cmp("1.2.3", "1.2.4", .older)
cmp("1.2.3", "1.3.0", .older)
cmp("0.9.1", "0.10.3", .older)   // real: colima on this machine
cmp("1.87.0", "1.92.0", .older)  // real: boost on this machine

// ---------- differing component counts ----------
cmp("2.0",   "2.0.0", .same)
cmp("2.0.0", "2.0",   .same)
cmp("2",     "2.0.0", .same)
cmp("2.0.1", "2.0",   .newer)
cmp("2.0",   "2.0.1", .older)

// ---------- pre-release suffixes lose to the plain version ----------
cmp("1.0-beta", "1.0", .older)
cmp("1.0", "1.0-beta", .newer)
cmp("2.0rc1", "2.0", .older)
cmp("1.0-beta", "1.0-beta", .same)
ok("a beta is not offered as an upgrade over the release",
   !VersionComparator.isUpgrade(installed: "1.0", available: "1.0-beta"))

// ---------- Homebrew revisions ----------
// `1.2.3_1` is a rebuild of 1.2.3, not version 1.2.3.1.
cmp("1.2.3_1", "1.2.3", .older)
cmp("1.2.3", "1.2.4_1", .older)

// ---------- degenerate input must not crash or invent an upgrade ----------
cmp("", "", .same)
ok("empty vs 1.0 is not a crash", VersionComparator.compare("", "1.0") == .older)
cmp("abc", "abc", .same)
ok("garbage is never an upgrade over itself",
   !VersionComparator.isUpgrade(installed: "abc", available: "abc"))
cmp("13.2b", "13.2b", .same)

// A version is never an upgrade over itself, for every shape above.
for v in ["1.0", "2.0.0", "1.10", "1.0-beta", "1.2.3_1", "", "abc", "13.2b"] {
    ok("\"\(v)\" is not an upgrade over itself", !VersionComparator.isUpgrade(installed: v, available: v))
}

// ---------- HomebrewOutdated.parse ----------
func parse(_ s: String) -> [HomebrewOutdated.Package] {
    HomebrewOutdated.parse(Data(s.utf8))
}

// Real shape, taken verbatim from `brew outdated --json=v2` on this machine.
let real = """
{"formulae":[
  {"name":"boost","installed_versions":["1.87.0"],"current_version":"1.92.0","pinned":false,"pinned_version":null},
  {"name":"colima","installed_versions":["0.9.1"],"current_version":"0.10.3","pinned":false,"pinned_version":null}
],"casks":[]}
"""
let parsed = parse(real)
ok("parses two formulae", parsed.count == 2, "got \(parsed.count)")
ok("names",     parsed.map(\.name) == ["boost", "colima"])
ok("installed", parsed.map(\.installed) == ["1.87.0", "0.9.1"])
ok("available", parsed.map(\.available) == ["1.92.0", "0.10.3"])
ok("not casks", parsed.allSatisfy { !$0.isCask })

// Casks are tagged, and given distinct ids so a formula and cask sharing a
// name cannot collide in a ForEach.
let mixed = parse("""
{"formulae":[{"name":"docker","installed_versions":["1.0"],"current_version":"2.0"}],
 "casks":[{"name":"docker","installed_versions":["1.0"],"current_version":"2.0"}]}
""")
ok("formula and cask both parsed", mixed.count == 2)
ok("ids are distinct", Set(mixed.map(\.id)).count == 2, "ids \(mixed.map(\.id))")
ok("one is a cask", mixed.filter(\.isCask).count == 1)

// installed_versions as a bare string (seen across Homebrew versions).
ok("string installed_versions is handled",
   parse(#"{"casks":[{"name":"x","installed_versions":"1.0","current_version":"2.0"}]}"#).count == 1)

// Pinned is surfaced, not silently upgraded.
let pinned = parse("""
{"formulae":[{"name":"node","installed_versions":["18.0"],"current_version":"22.0","pinned":true}]}
""")
ok("pinned formula is listed", pinned.count == 1)
ok("pinned flag survives", pinned.first?.isPinned == true)

// A rebuild whose version has not moved must not be reported as an upgrade.
ok("same version is not reported",
   parse(#"{"formulae":[{"name":"x","installed_versions":["1.0"],"current_version":"1.0"}]}"#).isEmpty)
ok("a DOWNgrade is not reported",
   parse(#"{"formulae":[{"name":"x","installed_versions":["2.0"],"current_version":"1.0"}]}"#).isEmpty)

// Malformed input yields nothing rather than crashing or half-parsing.
ok("empty object",   parse("{}").isEmpty)
ok("empty arrays",   parse(#"{"formulae":[],"casks":[]}"#).isEmpty)
ok("not json",       parse("brew: command not found").isEmpty)
ok("empty data",     parse("").isEmpty)
ok("missing name",   parse(#"{"formulae":[{"installed_versions":["1.0"],"current_version":"2.0"}]}"#).isEmpty)
ok("empty name",     parse(#"{"formulae":[{"name":"","installed_versions":["1.0"],"current_version":"2.0"}]}"#).isEmpty)
ok("missing current", parse(#"{"formulae":[{"name":"x","installed_versions":["1.0"]}]}"#).isEmpty)
ok("missing installed", parse(#"{"formulae":[{"name":"x","current_version":"2.0"}]}"#).isEmpty)
ok("empty installed list", parse(#"{"formulae":[{"name":"x","installed_versions":[],"current_version":"2.0"}]}"#).isEmpty)

// Sorted, so the list does not reshuffle between checks.
let unsorted = parse("""
{"formulae":[{"name":"zsh","installed_versions":["1.0"],"current_version":"2.0"},
             {"name":"awk","installed_versions":["1.0"],"current_version":"2.0"}]}
""")
ok("sorted by name", unsorted.map(\.name) == ["awk", "zsh"])

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/ver" 2>&1 | grep -E "error" || true
"$WORK/ver"
