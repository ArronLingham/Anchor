#!/bin/bash
# Pins AudioDeviceCycle and InputPinDecision — the two pure rules behind output
# switching and microphone pinning.
#
# The pin decision is the one that matters. Re-asserting a device in response to
# the change notification our own assertion caused is an infinite loop that
# fights the HAL, and it is not something you notice by trying the feature once:
# it needs a device to be contended. The settle window and the burst cap are
# what stop it, so they are pinned here rather than trusted.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Both types are pure — no CoreAudio, no Defaults — so they compile alone.
python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Audio/AudioDeviceToolsManager.swift").read()
cycle = re.search(r'(enum AudioDeviceCycle \{.*?\n\})\n', src, re.S).group(1)
pin   = re.search(r'(struct InputPinDecision \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + cycle + "\n\n" + pin + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ condition: Bool, _ detail: String = "") {
    if condition { passes += 1 } else {
        failures += 1
        print("  FAIL \(label)\(detail.isEmpty ? "" : ": \(detail)")")
    }
}
func eq<T: Equatable>(_ label: String, _ got: T?, _ want: T?) {
    if got == want { passes += 1 } else {
        failures += 1
        print("  FAIL \(label): got \(String(describing: got)), want \(String(describing: want))")
    }
}

// ---------- AudioDeviceCycle ----------
let three = [10, 20, 30]

eq("next from first",      AudioDeviceCycle.next(after: 10, in: three), 20)
eq("next from middle",     AudioDeviceCycle.next(after: 20, in: three), 30)
eq("next wraps at end",    AudioDeviceCycle.next(after: 30, in: three), 10)
eq("previous from last",   AudioDeviceCycle.previous(after: 30, in: three), 20)
eq("previous from middle", AudioDeviceCycle.previous(after: 20, in: three), 10)
eq("previous wraps at start", AudioDeviceCycle.previous(after: 10, in: three), 30)

// next then previous returns where it started, from every position
for id in three {
    let there = AudioDeviceCycle.next(after: id, in: three)!
    eq("round trip from \(id)", AudioDeviceCycle.previous(after: there, in: three), id)
}

// Degenerate lists: a single device is not a cycle, and firing a "switched to"
// HUD while nothing changed reads as a bug.
eq("single device does not cycle", AudioDeviceCycle.next(after: 10, in: [10]), nil)
eq("single device, reverse",       AudioDeviceCycle.previous(after: 10, in: [10]), nil)
eq("empty list",                   AudioDeviceCycle.next(after: 10, in: [Int]()), nil)

// The unplug case: the active device is gone from a refreshed list.
eq("unknown current lands on first", AudioDeviceCycle.next(after: 99, in: three), 10)
eq("unknown current, reverse",       AudioDeviceCycle.previous(after: 99, in: three), 10)

// Cycling every device exactly once before repeating — the property that
// makes this a cycle rather than a shuffle.
var visited: [Int] = []
var cursor = 10
for _ in three { visited.append(cursor); cursor = AudioDeviceCycle.next(after: cursor, in: three)! }
ok("visits every device once", Set(visited).count == three.count, "visited \(visited)")
eq("returns to start after a full lap", cursor, 10)

// ---------- InputPinDecision ----------
let pin = InputPinDecision()
func state(pinned: String? = "mic-uid", current: String? = "builtin",
           connected: Bool = true, sinceOwn: Double = 5, recent: Int = 0)
    -> InputPinDecision.State {
    .init(pinnedUID: pinned, currentUID: current, pinnedIsConnected: connected,
          sinceOwnChange: sinceOwn, recentAssertions: recent)
}

ok("reasserts when system drifted", pin.shouldReassert(state()))
ok("feature off when unpinned", !pin.shouldReassert(state(pinned: nil)))
ok("empty pin is off", !pin.shouldReassert(state(pinned: "")))
ok("no-op when already correct", !pin.shouldReassert(state(current: "mic-uid")))
ok("does not fight for an unplugged device", !pin.shouldReassert(state(connected: false)))

// The loop guards.
ok("ignores the echo of our own change", !pin.shouldReassert(state(sinceOwn: 0.1)))
ok("acts once past the settle window", pin.shouldReassert(state(sinceOwn: 0.6)))
ok("gives up after a burst", !pin.shouldReassert(state(recent: 5)))
ok("still acts below the burst cap", pin.shouldReassert(state(recent: 4)))

// A device that is unplugged AND being fought over must stay silent — the
// guards have to compose, not merely work one at a time.
ok("guards compose", !pin.shouldReassert(state(connected: false, sinceOwn: 0.1, recent: 9)))

// nil current (no default input at all — every microphone unplugged) is a
// drift, not a match: reasserting is right once the pinned device returns.
ok("nil current with connected pin reasserts", pin.shouldReassert(state(current: nil)))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/audio" 2>&1 | grep -E "error" || true
"$WORK/audio"
