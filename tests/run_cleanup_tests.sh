#!/bin/bash
# Pins CleanupSafety — the rules deciding what the cleaner may touch.
#
# This is the most dangerous pure function in the app. AppUninstaller's matcher
# decides what belongs to one app; this one decides what to remove from the
# user's home directory wholesale. Every assertion below is a path that must
# NOT be cleanable, because the failure mode is someone's Documents folder in
# the Trash.
#
# The Trash itself is asserted forbidden: everything this feature removes moves
# INTO the Trash, so a cleaner that could also empty it would silently destroy
# the undo the whole design rests on.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/CleanupManager.swift").read()
cat  = re.search(r'(enum CleanupCategory[^\{]*\{.*?\n\})\n', src, re.S).group(1)
safe = re.search(r'(enum CleanupSafety \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + cat + "\n\n" + safe + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ c: Bool, _ d: String = "") {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)\(d.isEmpty ? "" : ": \(d)")") }
}
let home = (NSHomeDirectory() as NSString).standardizingPath

// ---------- isForbidden: the things that must never be touched ----------
for path in ["", "/", home,
             "/System", "/Library", "/Applications", "/usr", "/etc", "/var",
             "\(home)/Desktop", "\(home)/Desktop/thesis.pdf",
             "\(home)/Documents", "\(home)/Documents/tax",
             "\(home)/Downloads", "\(home)/Pictures", "\(home)/Movies",
             "\(home)/Music", "\(home)/Public", "\(home)/Applications",
             "\(home)/.Trash", "\(home)/.Trash/recovered-file",
             "/Users/someone-else/Library/Caches"] {
    ok("forbidden: \(path.isEmpty ? "(empty)" : path.replacingOccurrences(of: home, with: "~"))",
       CleanupSafety.isForbidden(path))
}

// Path traversal must not escape the home directory.
ok("forbidden: traversal out of home",
   CleanupSafety.isForbidden("\(home)/Library/Caches/../../../etc"))
// `~/Library/Caches/../Documents` standardises to `~/Library/Documents`, which
// is NOT the real Documents folder and is legitimately unprotected — so
// isForbidden correctly allows it. The layer that stops it being cleaned is
// isCleanable's suffix check, and that is what this asserts instead. Getting
// this wrong in the other direction (asserting isForbidden catches it) would
// have hidden which guard is actually load-bearing.
ok("traversal resolving inside home is not itself forbidden",
   !CleanupSafety.isForbidden("\(home)/Library/Caches/../Documents"))
ok("but it is not cleanable, which is the guard that matters",
   !CleanupSafety.isCleanable(.userCaches,
                              resolvedPath: "\(home)/Library/Caches/../Documents"))
ok("nor is a traversal that lands on real Documents",
   !CleanupSafety.isCleanable(.userCaches, resolvedPath: "\(home)/Documents"))

// ---------- the allowlisted locations must be permitted ----------
for c in CleanupCategory.allCases {
    let path = (home as NSString).appendingPathComponent(c.relativePath)
    ok("allowed: \(c.relativePath)", !CleanupSafety.isForbidden(path))
    ok("cleanable: \(c.rawValue)", CleanupSafety.isCleanable(c, resolvedPath: path))
}

// ---------- isCleanable must reject a mismatched path ----------
ok("a category cannot be pointed elsewhere",
   !CleanupSafety.isCleanable(.userCaches, resolvedPath: "\(home)/Documents"))
ok("a category cannot be pointed at another category's path",
   !CleanupSafety.isCleanable(.userCaches,
                              resolvedPath: "\(home)/\(CleanupCategory.npmCache.relativePath)"))
ok("empty resolved path is not cleanable",
   !CleanupSafety.isCleanable(.userCaches, resolvedPath: ""))
ok("home itself is not cleanable",
   !CleanupSafety.isCleanable(.userCaches, resolvedPath: home))

// ---------- no category may resolve to a forbidden place ----------
for c in CleanupCategory.allCases {
    ok("\(c.rawValue) has a non-empty relative path", !c.relativePath.isEmpty)
    ok("\(c.rawValue) stays under the home directory",
       !c.relativePath.hasPrefix("/") && !c.relativePath.contains(".."))
}

// ---------- defaults must never be the expensive choice ----------
ok("Xcode derived data is NOT default-selected", !CleanupCategory.xcodeDerivedData.isDefaultSelected)
ok("npm cache is NOT default-selected",          !CleanupCategory.npmCache.isDefaultSelected)
ok("Homebrew cache is NOT default-selected",     !CleanupCategory.homebrewCache.isDefaultSelected)
ok("device support is NOT default-selected",     !CleanupCategory.xcodeDeviceSupport.isDefaultSelected)
ok("app caches are NOT default-selected (some sign you out)",
   !CleanupCategory.userCaches.isDefaultSelected)
ok("logs ARE default-selected",        CleanupCategory.userLogs.isDefaultSelected)
ok("crash reports ARE default-selected", CleanupCategory.crashReports.isDefaultSelected)

// Every category must explain what removing it costs — a cleaner that says
// only "caches" invites someone to tick a box that forces a full Xcode build.
for c in CleanupCategory.allCases {
    ok("\(c.rawValue) states a consequence", c.consequence.count > 20)
    ok("\(c.rawValue) has a title", !c.title.isEmpty)
}

// The Trash must not be reachable as a category, ever.
ok("no category targets the Trash",
   !CleanupCategory.allCases.contains { $0.relativePath.contains(".Trash") })

// ---------- formatBytes ----------
ok("zero",   CleanupSafety.formatBytes(0) == "0 bytes")
ok("bytes",  CleanupSafety.formatBytes(512) == "512 bytes")
ok("KB",     CleanupSafety.formatBytes(2_000) == "2.0 KB")
ok("MB",     CleanupSafety.formatBytes(6_100_000) == "6.1 MB")
ok("GB",     CleanupSafety.formatBytes(2_700_000_000) == "2.7 GB")
ok("negative is not shown as a size", CleanupSafety.formatBytes(-5) == "0 bytes")

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/clean" 2>&1 | grep -E "error" || true
"$WORK/clean"
