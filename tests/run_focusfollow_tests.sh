#!/bin/bash
# Pins FocusFollowsMouseDecision — the rules that stop focus-follows-mouse
# firing when the user did not mean it.
#
# Every guard here exists because the failure mode is *stealing focus mid-
# action*: raising a window while the user is dragging, holding a modifier, or
# has a menu open interrupts something they were deliberately doing. A raise
# that fails to happen is a shrug; a raise that happens at the wrong moment
# loses work.
set -euo pipefail
cd "$(dirname "$0")/.."
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Decision.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Input/FocusFollowsMouseManager.swift").read()
st = re.search(r'(struct FocusFollowsMouseDecision \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\nimport AppKit\n\n" + st + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation
import AppKit

var passes = 0, failures = 0
func ok(_ label: String, _ cond: Bool) {
    if cond { passes += 1 } else { failures += 1; print("  FAIL \(label)") }
}

let d = FocusFollowsMouseDecision(
    dwellSeconds: 0.3, suspendingModifiers: [.command, .option, .control, .shift])

func state(app: String? = "com.other.app", front: String? = "com.current.app",
           dragging: Bool = false, mods: NSEvent.ModifierFlags = [],
           dwell: Double = 0.5, menu: Bool = false) -> FocusFollowsMouseDecision.State {
    .init(appUnderPointer: app, frontmostApp: front, isDragging: dragging,
          modifiers: mods, dwellElapsed: dwell, isMenuOpen: menu)
}

// --- the one case that should raise ---
ok("settled over another app raises", d.shouldRaise(state()))

// --- must NOT raise: focus-stealing hazards ---
ok("already frontmost", !d.shouldRaise(state(app: "com.same", front: "com.same")))
ok("dragging", !d.shouldRaise(state(dragging: true)))
ok("command held", !d.shouldRaise(state(mods: [.command])))
ok("option held", !d.shouldRaise(state(mods: [.option])))
ok("shift held", !d.shouldRaise(state(mods: [.shift])))
ok("control held", !d.shouldRaise(state(mods: [.control])))
ok("menu open", !d.shouldRaise(state(menu: true)))

// --- dwell threshold ---
ok("not settled long enough", !d.shouldRaise(state(dwell: 0.1)))
ok("exactly at dwell raises", d.shouldRaise(state(dwell: 0.3)))
ok("well past dwell raises", d.shouldRaise(state(dwell: 5.0)))

// --- nothing identifiable under the pointer ---
ok("nil app", !d.shouldRaise(state(app: nil)))
ok("empty app id", !d.shouldRaise(state(app: "")))

// --- guards compose: any one is enough to block ---
ok("dragging beats long dwell", !d.shouldRaise(state(dragging: true, dwell: 10)))
ok("modifier beats long dwell", !d.shouldRaise(state(mods: [.command], dwell: 10)))
ok("menu beats long dwell", !d.shouldRaise(state(dwell: 10, menu: true)))

// --- an unrelated modifier must not block (capsLock is not in the set) ---
ok("capsLock does not block", d.shouldRaise(state(mods: [.capsLock])))

// --- no frontmost app at all (login window, screensaver) ---
ok("nil frontmost still raises", d.shouldRaise(state(front: nil)))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT
swiftc -O "$WORK/Decision.swift" "$WORK/main.swift" -o "$WORK/ff" 2>&1 | grep -E "error" || true
"$WORK/ff"
