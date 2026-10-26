# Browser header clicks — October 21, 2026

## Reproduction

The installed Anchor executable was `535caeaaa2e0578df65e7fe16df7f45aff62f68c5ac8c21ff50d7b1d6eaaf784`. Its native notch window occupied **580×218 points** at screen coordinates `(445, 0)`, at window level 27. The painted closed notch was only **191×32 points**.

Read-only Accessibility hit tests at three horizontal positions and four rows 40, 75, 110 and 160 points below the screen top all returned Anchor's group. Those positions were in transparent host space, including the browser header/search area. After Anchor closed, the same 12 locations returned Brave Browser. No pointer or lock event was generated during the reproduction.

## Fix

- A geometry bridge measures the actual clipped SwiftUI surface before shadow clearance, floating-island offsets and the larger animation container. It uses the rendered shape's path, including its clear rounded corners.
- The native window starts with mouse input ignored. Event-driven pointer updates enable input while the pointer is inside the painted surface and release the transparent area outside it. One local/global monitor pair serves all displayed native notch windows; there is no new timer, event suppression, click replay or polling loop.
- Geometry, resize, visibility, alpha and native/advanced-island ownership changes refresh routing immediately. Geometry updates also deliver coalesced hover changes, so the first entry can still activate the notch without waiting for another mouse movement.
- Mouse sequences that begin in the notch retain ownership while a slider or selection is dragged outside. Mouse-up, hiding and AppKit's nested control tracking release that ownership. Drags that begin in another app do not claim the notch.
- Terminal outside-click checks now use the painted region instead of the whole transparent host rectangle.

## Validation

The standalone native suite passes **71 checks** covering clear padding, curved corners, negative display coordinates, scaling and Y-axis conversion, fresh/unlaid-out/hidden/disabled windows, changing surface geometry, detachment and drag ownership. It uses the real AppKit window and geometry bridge in an off-screen fixture without moving the pointer. Related display-policy and feature-ownership suites pass **79** and **29** checks respectively.

The development app's actual ContentView passes **13 integration checks** for closed and open geometry, control input, the timer tab's lower controls, closing, and advanced-island takeover/handback. Measured surfaces: closed 191×32, open Home 580×68, timer tab 600×250, closed again 191×32. A view-only snapshot confirms the Home input region matches its painted surface. The review uses temporary process state, reports geometry only and exits; it never starts a timer, capture, camera or lock.

## Installed result

The signed Release build is installed and running at `/Applications/Anchor.app` as `com.arronlingham.Anchor`. Launch Services resolves that exact path, with one running production copy and no development copy. Deep strict signature verification passes. Built and installed executable hashes match:

`99266b8150dc338d5eab2cec8b5c71ec769b772384443aa969b266870d34e9b4`

The installed notch still reserves its original 580×218 animation window, but **all 12 previously blocked header positions now target Brave Browser** while Anchor is running. The web-content rows resolve to Brave's `AXWebArea`. The checks do not move the pointer or generate a lock action. They verify Accessibility hit targeting rather than synthesizing a hardware click in the user's browser.

All 77 library availability values and the saved display/hover choices match the values captured before the change; the 19 enabled library features remain enabled. The prior signed app is preserved at `/private/tmp/anchor-top-click-install.PHocOZ/Anchor.previous.app`.

The current machine has one built-in display connected. Display positions above/left of the primary display and scaled geometry are covered by the native test suite; no physical external-display change was made.

## Usage check

The original process closed after reproducing the issue, before a new before-fix idle sample could be captured. The broken app was left closed during implementation and compilation. No before/after performance reduction is claimed. The change adds event monitors and coalesced callbacks, with no new timer or polling loop. A 60-second post-install sample after more than five minutes of uptime recorded **0.05% mean CPU** (0.00% median, 1.44% maximum) and **111.6 MB mean/max RSS**, across 29 samples. No build or review fixture was running; the user continued using their Mac. The [validation receipt](TOP-SCREEN-CLICK-VALIDATION-2026-10-21.json) records the result and measurement limits.
