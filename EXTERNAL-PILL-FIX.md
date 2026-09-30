# Persistent external-display pill

## Cause

The idle-content selection in `ContentView` contained an empty branch before the idle animation. With `showNotHumanFace` enabled (as it is in the installed app's preferences), an idle, closed notch selected that empty branch. Focus bypassed it by rendering its own explicitly sized activity. The black pill background had no dependable idle content height.

Other independent paths undermined the persistent setting:

- Changing it only refreshed Space membership; it did not reconcile single-window and multi-window modes.
- Fullscreen detection and hover hiding still hid the external view.
- Matching the menu bar could produce height zero. The connected EK271 GD reported identical screen and visible frames during investigation, so its visible top inset was zero.
- The external style preference could still select a notch instead of the promised pill.

Apple documents `NSScreen.safeAreaInsets` as the unobscured layout insets and exposes auxiliary areas for displays with an obscured top region. The existing per-screen distinction is appropriate; the missing idle geometry and inconsistent visibility policy were the problems. [Apple NSScreen documentation](https://developer.apple.com/documentation/appkit/nsscreen/safeareainsets).

## Fix

Removed the empty idle branches. The persistent option now gives the closed view its own minimum body, uses the pill shape on unnotched displays, keeps its height at least 32 points, and overrides both fullscreen suppression and hover hiding. A physical notch continues to use its existing shape and fullscreen rules.

Both display settings now reconcile actual windows, remove obsolete single/per-screen windows, refresh geometry, and update Space membership. Changing either setting works without requiring a relaunch. Stale display windows also leave the managed Space when removed.

The settings explain the precedence and disable conflicting style/hide controls while the persistent option is enabled. Existing lock-screen handling is retained.

## Verification

- Debug (Apple Development signed) and Release builds passed. The signed bundle passed strict recursive signature verification.
- Five live window transitions passed across the two connected displays: single display, persistent external displays, both options on, all displays only, and back to single display.
- 79 policy checks cover physical/unnotched/unresolved screens, enabled/disabled persistence, fullscreen detection combinations, zero and normal heights, and the minimum width.
- Actual ContentView renders show idle with an animation, plain idle, Focus, and Focus off. All contain a visible capsule. The plain-idle and Focus-off images are identical.
- Fixtures deliberately enable hover hiding, select the notch style, and set custom height to zero while persistence is on. Preferences are temporary in-process overrides and tasks use an isolated directory.

The updated signed Debug app is installed at `/Applications/Anchor.app` and was relaunched with the existing bundle identity and team. The earlier development copy was closed; only the installed copy remains running. The previous app, preferences, and Application Support data were backed up under `build/installed-backup-20260914-131733/`.

The running installed app has an onscreen external-display panel with alpha 1. Native fullscreen Space transitions and sleep/wake still need interactive checks; these are distinct from rendering and policy checks. Screenshots and the window-transition result are in `build/feature-review/`.
