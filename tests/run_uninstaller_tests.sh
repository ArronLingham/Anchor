#!/bin/bash
# Pins AppUninstaller.matches — the rule that decides whether a file on disk
# belongs to the app being removed.
#
# This is the highest-stakes pure function in the app: a false positive here
# moves an unrelated app's data to the Trash. The prefix case is the dangerous
# one — `com.acme.app` must NOT match `com.acme.apple`, which is a different
# app whose identifier merely starts the same way.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Matcher.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/AppUninstaller.swift").read()
func = re.search(
    r'(    static func matches\(filename: String, bundleID: String\) -> Bool \{.*?\n    \})',
    src, re.S).group(1)
open(sys.argv[1], "w").write(f"""import Foundation

enum AppUninstaller {{
{func}
}}
""")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func check(_ label: String, _ filename: String, _ bundleID: String, _ expected: Bool) {
    let got = AppUninstaller.matches(filename: filename, bundleID: bundleID)
    if got == expected { passes += 1 } else {
        failures += 1
        print("  FAIL \(label): matches('\(filename)', '\(bundleID)') = \(got), want \(expected)")
    }
}

let id = "com.acme.app"

// --- must match ---
check("exact", id, id, true)
check("plist", "com.acme.app.plist", id, true)
check("savedState", "com.acme.app.savedState", id, true)
check("binarycookies", "com.acme.app.binarycookies", id, true)
check("hyphen separator", "com.acme.app-helper", id, true)
check("underscore separator", "com.acme.app_data", id, true)

// --- must NOT match: the dangerous prefix collisions ---
check("longer id, no separator", "com.acme.apple", id, false)
check("longer id with plist", "com.acme.applepay.plist", id, false)
check("different vendor", "com.other.app.plist", id, false)
check("substring not prefix", "xcom.acme.app", id, false)
check("empty filename", "", id, false)
check("empty bundle id", "com.acme.app", "", false)
check("both empty", "", "", false)

// --- realistic near-misses seen in ~/Library ---
check("Apple's own", "com.apple.finder.plist", "com.apple.find", false)
check("sibling app", "com.acme.app2.plist", id, false)
check("case differs", "COM.ACME.APP.plist", id, false)

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Matcher.swift" "$WORK/main.swift" -o "$WORK/unin" 2>&1 | grep -E "error" || true
"$WORK/unin"
