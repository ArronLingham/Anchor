#!/bin/bash
# Pins QuitOnCloseDecision and MediaAutoLaunchDecision.
#
# QuitOnCloseDecision is the most destructive pure function in the app after the
# uninstaller's matcher: a false positive terminates someone else's application,
# possibly with unsaved work in it. Every guard below is pinned because the
# failure is silent and unrecoverable, and because the situations that trigger
# it — an app mid-launch, a minimised window, a windowless menu bar agent — all
# look identical to "the last window just closed" from the outside.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

python3 - "$WORK/Rules.swift" <<'PY'
import re, sys
src = open("Anchor/Managers/Tools/AppLifecycleManager.swift").read()
quit_ = re.search(r'(struct QuitOnCloseDecision \{.*?\n\})\n', src, re.S).group(1)
media = re.search(r'(struct MediaAutoLaunchDecision \{.*?\n\})\n', src, re.S).group(1)
session = re.search(r'(final class QuitOnCloseSession \{.*?\n\})\n', src, re.S).group(1)
pending = re.search(r'(struct QuitOnClosePendingChecks \{.*?\n\})\n', src, re.S).group(1)
launches = re.search(r'(struct RunningApplicationLaunches<Process> \{.*?\n\})\n', src, re.S).group(1)
open(sys.argv[1], "w").write("import Foundation\n\n" + session + "\n\n" + pending + "\n\n" + launches + "\n\n" + quit_ + "\n\n" + media + "\n")
PY

cat > "$WORK/main.swift" <<'SWIFT'
import Foundation

var passes = 0, failures = 0
func ok(_ label: String, _ condition: Bool) {
    if condition { passes += 1 } else { failures += 1; print("  FAIL \(label)") }
}

// A fake observer and fake deferred check exercise off, ownership handover,
// rapid off/on, and process replacement without closing a real application.
let session = QuitOnCloseSession()
var pending = QuitOnClosePendingChecks()
var enabled = true, quits = 0
let old = session.current()
let oldRequest = pending.begin(pid: 42, ticket: old)!
ok("same-session window events coalesce", pending.begin(pid: 42, ticket: old) == nil)
enabled = false
session.invalidate()
ok("off rejects an observer callback", !session.accepts(old, enabled: enabled))
enabled = true // Native ownership can return before the queued check runs.
session.invalidate()
let current = session.current()
ok("off/on rejects the previous observer", !session.accepts(old, enabled: enabled))
let newRequest = pending.begin(pid: 42, ticket: current)!
ok("old completion cannot clear a new check", !pending.finish(pid: 42, request: oldRequest))
ok("current check survives an old completion", pending.finish(pid: 42, request: newRequest))
ok("current observer remains authorized", session.accepts(current, enabled: enabled))
let terminatedRequest = pending.begin(pid: 42, ticket: current)!
pending.remove(pid: 42)
let replacementRequest = pending.begin(pid: 42, ticket: current)!
ok("old process cannot clear replacement check", !pending.finish(pid: 42, request: terminatedRequest))
ok("replacement process check remains", pending.finish(pid: 42, request: replacementRequest))
let duringRead = pending.begin(pid: 42, ticket: current)!
if pending.finish(pid: 42, request: duringRead), session.accepts(current, enabled: enabled) {
    // The fake window-count read causes ownership to be handed over.
    enabled = false
    session.invalidate()
    if session.accepts(current, enabled: enabled) { quits += 1 }
}
ok("handover during window read prevents termination", quits == 0)
ok("off rejects even a current token", !session.accepts(session.current(), enabled: false))

// Different fake processes can share a PID. A late termination from the old
// one must neither erase the new process's launch time nor inherit its grace.
var launches = RunningApplicationLaunches<String>()
let oldLaunch = Date(timeIntervalSince1970: 10)
let newLaunch = Date(timeIntervalSince1970: 20)
ok("first process is new", !launches.record(pid: 7, process: "old", date: oldLaunch, matches: ==))
ok("replacement with same PID is new", !launches.record(pid: 7, process: "new", date: newLaunch, matches: ==))
launches.remove(pid: 7, process: "old", matches: ==)
ok("old termination preserves new launch", launches.date(pid: 7, process: "new", matches: ==) == newLaunch)
ok("old process cannot borrow new launch", launches.date(pid: 7, process: "old", matches: ==) == nil)
launches.remove(pid: 7, process: "new", matches: ==)
ok("matching termination removes launch", launches.date(pid: 7, process: "new", matches: ==) == nil)
let oldObserver = UUID(), newObserver = UUID()
let oldObserverRequest = pending.begin(pid: 7, ticket: oldObserver)!
let newObserverRequest = pending.begin(pid: 7, ticket: newObserver)!
ok("replaced observer gets its own check", !pending.finish(pid: 7, request: oldObserverRequest))
ok("new observer check remains pending", pending.finish(pid: 7, request: newObserverRequest))

// ---------- QuitOnCloseDecision ----------
var quit = QuitOnCloseDecision()
func app(bundle: String? = "com.acme.editor", visible: Int = 0, since: Double = 60,
         regular: Bool = true, minimised: Bool = false) -> QuitOnCloseDecision.State {
    .init(bundleID: bundle, visibleWindowCount: visible, sinceLaunch: since,
          isRegularApp: regular, hasMinimisedWindows: minimised)
}

ok("quits when the last window closes", quit.shouldQuit(app()))
ok("leaves an app with a window open", !quit.shouldQuit(app(visible: 1)))
ok("leaves an app with several windows", !quit.shouldQuit(app(visible: 5)))

// The guards, each on its own.
ok("never quits a menu bar agent", !quit.shouldQuit(app(regular: false)))
ok("respects the launch grace period", !quit.shouldQuit(app(since: 2)))
ok("acts once past the grace period", quit.shouldQuit(app(since: 11)))
ok("minimised is not closed", !quit.shouldQuit(app(minimised: true)))
ok("no bundle id, no action", !quit.shouldQuit(app(bundle: nil)))
ok("empty bundle id, no action", !quit.shouldQuit(app(bundle: "")))

// The built-in exclusions. Finder is the one that breaks the desktop.
for excluded in ["com.apple.finder", "com.apple.dock", "com.apple.systemuiserver",
                 "com.apple.controlcenter", "com.arronlingham.Anchor"] {
    ok("never quits \(excluded)", !quit.shouldQuit(app(bundle: excluded)))
}
ok("Anchor cannot quit itself", QuitOnCloseDecision.alwaysExcluded.contains("com.arronlingham.Anchor"))

// User exclusions.
quit.userExcluded = ["com.acme.editor"]
ok("respects a user exclusion", !quit.shouldQuit(app()))
ok("a user exclusion is specific to that app", quit.shouldQuit(app(bundle: "com.acme.other")))
quit.userExcluded = []

// Guards compose: an excluded agent, mid-launch, with a minimised window is
// still quiet — a rule that fires when several guards overlap is a rule that
// was only ever tested one condition at a time.
ok("guards compose", !quit.shouldQuit(
    app(bundle: "com.apple.finder", since: 1, regular: false, minimised: true)))

// A minimised window with no visible windows is the exact ambiguity the
// separate counts exist to resolve.
ok("minimised only does not quit", !quit.shouldQuit(app(visible: 0, minimised: true)))
ok("visible only does not quit",   !quit.shouldQuit(app(visible: 1, minimised: false)))
ok("neither quits",                 quit.shouldQuit(app(visible: 0, minimised: false)))

// ---------- MediaAutoLaunchDecision ----------
let media = MediaAutoLaunchDecision()
func launch(bundle: String? = "com.apple.Music", intent: Double = .infinity,
            running: Bool = false) -> MediaAutoLaunchDecision.State {
    .init(bundleID: bundle, sinceUserIntent: intent, wasAlreadyRunning: running)
}

ok("suppresses an unprompted Music launch", media.shouldSuppress(launch()))
ok("leaves a launch the user asked for", !media.shouldSuppress(launch(intent: 1)))
ok("leaves a launch just inside the window", !media.shouldSuppress(launch(intent: 4.9)))
ok("suppresses once outside the window", media.shouldSuppress(launch(intent: 5.1)))
ok("ignores an app that was already running", !media.shouldSuppress(launch(running: true)))
ok("ignores non-media apps", !media.shouldSuppress(launch(bundle: "com.acme.editor")))
ok("ignores a nil bundle id", !media.shouldSuppress(launch(bundle: nil)))
for a in ["com.apple.Music", "com.apple.TV", "com.apple.podcasts", "com.apple.iTunes"] {
    ok("covers \(a)", media.shouldSuppress(launch(bundle: a)))
}
// A user-opened media app must survive even at the boundary — this is the rule
// whose failure means Anchor closing something the user just clicked.
ok("user intent beats everything", !media.shouldSuppress(launch(intent: 0)))

if failures == 0 { print("\(passes)/\(passes) passed"); exit(0) }
print("\(passes) passed, \(failures) failed"); exit(1)
SWIFT

swiftc -O "$WORK/Rules.swift" "$WORK/main.swift" -o "$WORK/life" 2>&1 | grep -E "error" || true
"$WORK/life"
