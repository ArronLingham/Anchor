#!/bin/bash
# Pins DiskImageContents — what a mounted volume is judged to be offering.
#
# The dangerous case is the `Applications` symlink. Nearly every DMG ships one
# as the drag-here target, it sits next to the app, and a naive scan that
# treated it as a bundle would have the installer copy a symlink to
# /Applications over /Applications. The symlink filter is pinned twice: by name
# and by link status, because a DMG is free to call its alias something else.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/DiskImageInstaller.swift").read()
e = re.search(r'(enum DiskImageContents \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + e + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func eq(_ label: String, _ got: DiskImageContents.Outcome, _ want: DiskImageContents.Outcome) {
    if got == want { passes += 1 } else {
        failures += 1; print("  FAIL \(label): got \(got), want \(want)")
    }
}
func ok(_ label: String, _ c: Bool) {
    if c { passes += 1 } else { failures += 1; print("  FAIL \(label)") }
}

let vol = "/Volumes/Acme 2.0"
func ev(_ entries: [String], symlinks: Set<String> = []) -> DiskImageContents.Outcome {
    DiskImageContents.evaluate(entries: entries, volumePath: vol,
                               isSymlink: { symlinks.contains($0) })
}
func cand(_ name: String) -> DiskImageContents.Candidate {
    .init(appPath: "\(vol)/\(name)")
}

// --- the ordinary DMG: one app plus the drag-here alias ---
eq("app beside the Applications alias",
   ev(["Acme.app", "Applications", ".background", ".DS_Store"], symlinks: ["Applications"]),
   .offer(cand("Acme.app")))

// --- the alias must be excluded by BOTH rules independently ---
eq("excluded by name even when not a symlink",
   ev(["Acme.app", "Applications"]),
   .offer(cand("Acme.app")))
eq("excluded by symlink even under another name",
   ev(["Acme.app", "Drag Here.app"], symlinks: ["Drag Here.app"]),
   .offer(cand("Acme.app")))
// The nightmare: the ONLY bundle is a symlink. Must not offer to copy it.
eq("a lone symlink is not an install",
   ev(["Applications"], symlinks: ["Applications"]), .ignore)
eq("a lone aliased app is not an install",
   ev(["Drag Here.app"], symlinks: ["Drag Here.app"]), .ignore)

// --- nothing to install ---
eq("empty volume", ev([]), .ignore)
eq("only dotfiles", ev([".DS_Store", ".fseventsd", ".Trashes"]), .ignore)
eq("a pkg installer is not an app bundle", ev(["Acme Installer.pkg", "ReadMe.txt"]), .ignore)
eq("documents only", ev(["ReadMe.txt", "Licence.rtf", "manual.pdf"]), .ignore)

// --- a suite: ask, do not guess ---
if case .ambiguous(let c) = ev(["Writer.app", "Sheets.app", "Slides.app", "Applications"],
                               symlinks: ["Applications"]) {
    ok("three apps are ambiguous", c.count == 3)
    ok("ambiguous list is sorted", c.map(\.displayName) == ["Sheets", "Slides", "Writer"])
} else {
    failures += 1; print("  FAIL suite should be ambiguous")
}
ok("two apps do not silently pick one",
   { if case .ambiguous = ev(["A.app", "B.app"]) { return true }; return false }())

// --- names with awkward characters ---
eq("spaces in the name",
   ev(["My Great App.app"]), .offer(cand("My Great App.app")))
eq("a dot in the name",
   ev(["Acme 2.0.app"]), .offer(cand("Acme 2.0.app")))
// ".app" must be a suffix, not a substring anywhere in the name.
eq("a folder merely containing 'app'", ev(["appendix", "apple-notes"]), .ignore)
eq("'.application' is not '.app'", ev(["Thing.application"]), .ignore)

// --- displayName ---
ok("displayName strips .app", cand("Acme.app").displayName == "Acme")
ok("displayName keeps inner dots", cand("Acme 2.0.app").displayName == "Acme 2.0")

// --- isDiskImage: every row below was MEASURED on a real mount, not assumed.
//
// The original version of these tests asserted a DMG reports internal=false.
// It reports internal=TRUE. Both the code and the test encoded the same wrong
// belief, so the suite passed while the feature could never fire. These values
// come from `URLResourceValues` on an actual mounted image and on this Mac's
// startup disk.
func vol(removable: Bool, ejectable: Bool, root: Bool,
         network: Bool = false, proto: String? = nil) -> Bool {
    DiskImageContents.isDiskImage(isRemovable: removable, isEjectable: ejectable,
                                 isRootFileSystem: root, isNetwork: network,
                                 deviceProtocol: proto)
}

// MEASURED: /Volumes/TestApp 1.0 — removable=true internal=true ejectable=true rootFS=false
ok("a real mounted DMG qualifies",
   vol(removable: true, ejectable: true, root: false, proto: "Virtual Interface"))
// MEASURED: / — removable=false internal=true ejectable=false rootFS=true
ok("the startup disk does not",
   !vol(removable: false, ejectable: false, root: true, proto: "Apple Fabric"))
// MEASURED: /System/Volumes/Data — same shape as /
ok("the data volume does not",
   !vol(removable: false, ejectable: false, root: true, proto: "Apple Fabric"))

// The regression guard: internal=true must NOT disqualify. If someone
// reintroduces an `!isInternal` term, the DMG row above fails.
ok("internal=true is not disqualifying (the bug that shipped)",
   vol(removable: true, ejectable: true, root: false, proto: "Virtual Interface"))

// Physical buses are rejected by the protocol refinement.
ok("a USB stick does not",   !vol(removable: true, ejectable: true, root: false, proto: "USB"))
ok("an SD card does not",    !vol(removable: true, ejectable: true, root: false, proto: "Secure Digital"))
ok("a Thunderbolt disk does not",
   !vol(removable: true, ejectable: true, root: false, proto: "Thunderbolt"))
ok("a network share does not",
   !vol(removable: true, ejectable: true, root: false, network: true, proto: "Virtual Interface"))

// Degradation: an unknown or missing protocol must still allow the offer, so a
// renamed constant costs an occasional spurious prompt rather than the whole
// feature silently going dead — which is exactly what the first version did.
ok("an unknown protocol still offers",
   vol(removable: true, ejectable: true, root: false, proto: "Something New"))
ok("a missing protocol still offers",
   vol(removable: true, ejectable: true, root: false, proto: nil))

// Non-ejectable removable media (rare, but real) is not an image.
ok("removable but not ejectable does not",
   !vol(removable: true, ejectable: false, root: false))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/dmg" 2>&1 | grep -E "error" || true
"$WORK/dmg"
