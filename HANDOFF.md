# Handoff — 2026-08-29

Written for whoever picks this up next, human or Claude, with no memory of the
session that produced it. Read this before CLAUDE.md's feature sections if
you're resuming cold — it tells you what's actually true on this machine
*right now*, which is not always the same as what the code defaults to.

## Read this part first

**The daily commit is live on this repo, pushing to GitHub, once a day.**
`gitDailyCommitRepos` is set to `/Users/arronlingham/Anchor` — this repo, not a
throwaway one — with `gitDailyCommitPush = true` and a custom message,
`"Implementing new feature"`. That's why `git log` shows two commits with that
exact message and no diff (`7c6b5a6`, `3f0386d`): one from a manual "Commit
Now" test click on 2026-08-28 at 18:39, one from the scheduled 21:07 fire. The
21:07 one is already on `origin/main` — the push happened on its own. This is
the feature working as designed, configured by hand through Settings, not a
bug. Two things worth knowing:

- It will keep doing this every day at 21:07 (or a random time in the last
  session's window, if that got turned on since) for as long as
  `gitDailyCommitEnabled` stays true and this repo stays in the list.
- The commit message is generic. If real commits and "Implementing new
  feature" noise both showing up in the same log bothers you, change the
  template in Settings → Daily Commit, or turn off "Vary the commit message"
  if that's on, or just remove this repo from the list.

**Working tree is clean, HEAD is `7ac8462`, one commit ahead of `origin/main`.**
Push it when you're ready — nothing here is blocking that.

**Disk is at 2.3 GB free**, down from 5.0 GB earlier this session.
`~/Library/Developer/Xcode/DerivedData/Anchor-dsnyutmyztidtqgpjqipjmhvwvms` is
1.6 GB of that — normal cost of the ~15 Debug/Release builds this session did,
not a leak. Worth clearing if a build ever fails for lack of space:
`rm -rf ~/Library/Developer/Xcode/DerivedData/Anchor-*` is safe; Xcode
regenerates it.

**Wispr Flow is still running** (nine Electron processes, launched 5:50 PM).
It's the old dictation app Anchor's own dictation replaced. The user asked
about its live-transcript overlay, I identified it, asked what to do with it,
and the question was dismissed without an answer — no action was taken. It is
still running as of this writing.

## What's actually enabled on this machine right now

Not the code's defaults — what's actually flipped on, read straight out of
`defaults read com.arronlingham.Anchor`:

| Feature | State |
|---|---|
| Per-app volume / mute / EQ | **On** |
| Vinyl desktop widget | Off (window level set to `floating`, so it was tried) |
| Menu bar shrinker | **On**, hover-to-expand **on** |
| To-do list | **On** |
| Ring app switcher (⌥Tab) | **On** |
| Notch pin (⌘⇧K) | Off |
| Always show pill on external displays | **Off — the fix shipped, the setting was never turned on** |
| HUD placement | "The display I'm using" (changed from the default "All displays") |
| Show on all displays (pre-existing feature) | On |
| Daily commit | **On**, see above |
| Keep-awake | Removed entirely, not a setting anymore |

`/Applications/Anchor.app` was built and installed at **Aug 29, 12:56:54**,
signed with the real Apple Development identity (not ad-hoc), 0 debug hooks in
the binary, currently running. Accessibility is granted (confirmed by the user
directly in System Settings, and independently confirmed working: the app
switcher's `AXUIElement` calls succeed).

## What changed this session, roughly in order

1. **Seven app-parity features added**, all shipped off by default: keep-awake
   triggers (since removed, see below), a to-do list, a daily git commit, a
   ring app switcher, a menu bar shrinker, a vinyl desktop widget, per-app
   volume. Commits `ca87646` through `18d438a`.
2. **A real bug in the settings sidebar.** `SettingsView.availableTabs` is a
   hardcoded ordered array, not `SettingsTab.allCases`. Five panes — Vinyl,
   Menu Bar, To-Do, Daily Commit, and Claude Usage — had cases, views, icons
   and tints but no entry in that array, so they were invisible with no build
   error. Claude Usage had never been reachable at all since that feature
   shipped, months before this session. Fixed in `68bd94e`; there's now an
   `assert` in `availableTabs` that names any case missing from the list.
3. **The hand-written per-app volume engine did not work**, for four
   independent reasons documented in `CLAUDE.md`'s per-app-audio section (it
   tapped one process object when apps route audio through several; it
   started the IOProc before the aggregate device was ready; it was missing
   two required aggregate-device keys; it ignored drift compensation, which
   must be off for Bluetooth or you get a rhythmic crackle). Replaced with a
   port of **FineTune** (github.com/ronitsingh10/FineTune, GPL-3.0,
   © 2026 Ronit Singh) into `Anchor/audio/perapp/` — the coordinator and
   settings UI are written fresh against Anchor's own idioms. `NOTICE` records
   the derivation. Commit `68bd94e`.
   - **This has still never been listened to.** It builds the device, starts
     the IOProc, and tears down cleanly. Whether it sounds right — no
     dropouts, no crackle, correct latency — needs a person with speakers.
     Test plan is TESTING.md item 101, and it should be the first thing
     anyone with a working setup tries.
4. **Keep-awake removed entirely** at the user's request — manager, settings
   section, triggers, seven `Defaults` keys, all gone. Commit `d4d0228`.
5. **Vinyl widget redesigned** to match a reference screenshot: portrait card,
   album-colour tinted (hue kept, saturation/brightness clamped to a narrow
   band so any cover produces something legible), dark or light ink chosen by
   Rec. 709 luma, title/artist under the record, transport, and a
   click-to-seek progress bar with times — the ring style from the original
   design is still available as an option. Commit `d4d0228`.
6. **The switcher had two real bugs, both fixed with root causes found, not
   guessed:**
   - **Release-to-activate didn't commit.** The only release-detection path
     was a `.flagsChanged` global monitor, which is silent without
     Accessibility. A polling watch on `NSEvent.modifierFlags` (needs no
     permission at all) now runs alongside it while the ring is open, at
     20ms. Commit `d4d0228`.
   - **Un-minimising didn't focus the app.** `activateSelection()` called
     `NSRunningApplication.activate()` *before* clearing `AXMinimized` — a
     fully-minimised app has nothing visible for `activate()` to bring
     forward, so it silently succeeded on nothing. Fixed by reordering:
     clear `AXMinimized`, `AXUIElementPerformAction(window, kAXRaiseAction)`,
     *then* activate. Commit `7ac8462`.
   - **Hit-testing is now a pie chart**, not per-icon hover: the whole disc is
     divided into as many wedges as there are apps, and the pointer anywhere
     in a wedge selects it. Commit `7ac8462`. **Not yet confirmed working by
     the user** — the build that contains this was installed moments before
     this document was written.
7. **The external-display pill had a real bug too.**
   `syncNotchSpaceMembership()` — which pins the window above other apps —
   had exactly one call site in the whole app, triggered only by a
   `hideNotchOption` change. Nothing called it at launch, when
   `alwaysShowOnExternalDisplays` itself changed, or when a monitor was
   plugged in. The logic was correct and had no way to ever run. Fixed with
   three triggers: launch, its own `Defaults.publisher`, and
   `screenConfigurationDidChange`. Commit `7ac8462`. **The setting is still
   off** — see the table above.
8. **53 settings carried `.help()` text nobody sees** (a tooltip needs a long
   hover to appear). 40 of them are now a clickable ⓘ with a popover, next to
   the row's control. Commit `13b5317`.
9. **Daily commit gained** a message pool, a randomised time inside a
   configurable window, and up to 12 commits a day spread evenly through it.
   The random draw is seeded from the day and slot rather than
   `Double.random`, so it doesn't redraw (and drift) on every reschedule.
   Commit `13b5317`. **Not exercised against real elapsed days** — the
   once-a-day quota logic has only been proven against the manual-then-
   scheduled pair described at the top of this document.
10. **HUD placement, brightness diagnosis, notch pin.** The volume/brightness
    HUD used to show on every display at once; there's now a placement
    setting (all / active / main). Investigated why brightness silently never
    showed a HUD: volume changes come from CoreAudio and need no permission,
    brightness has no such notification so it's detected by intercepting the
    key, which needs Accessibility — and at the time, Anchor had no
    Accessibility grant at all. The Controls pane now says so with a button
    straight to System Settings. **Brightness has still not been confirmed
    working** by the user since Accessibility was granted — see below.
    Separately, a pin button (and ⌘⇧K) now keeps the notch open through
    hover-out, clicking away, and typing. Commit `13b5317`.

## Verified vs. not — the distinction that matters most here

Everything above builds clean (0 errors) and passes all 6 test suites
(19/7/25/24/16/8, `run_parser`/`run_watcher`/`run_launcher`/`run_color`/
`run_gitcommit`/`test_privacy_configuration`). That proves the code does what
it was written to do. It does not prove any of the following, which still need
a person:

- **Per-app volume — never listened to.** TESTING.md item 101.
- **Brightness HUD — never confirmed since Accessibility was granted.** I
  cannot press a physical F-key from here, and `log show` returns zero lines
  for *any* process in this shell (confirmed against `WindowServer`, not just
  Anchor) — there is no way to check the media-key tap's state without the
  user pressing a key and reporting what happens.
- **Switcher fixes (release-commit, focus-after-unminimise, pie-wedge hover)
  — built and installed, not yet tried.** The build containing all three
  went up right before this document.
- **Vinyl widget actually appearing on screen — never confirmed.** It renders
  correctly in the offscreen harness; whether the real window reaches the
  window server was never independently verified (a known limitation of
  testing a GUI app headlessly — see CLAUDE.md's section on that). It's
  currently switched off, so this is untested either way.
- **Multi-display control windows (item 93) and per-app mute in isolation
  (item 95) — pre-existing gaps from before this session, still open.**
- **Menu bar shrinker against a notched display (item 104)** — whether hidden
  icons go off-edge or get stuck under the notch was never seen.
- **Multi-commit / randomised daily-commit scheduling** — the quota logic is
  reasoned through carefully in code and in CLAUDE.md, but has not run across
  real elapsed days with more than one commit configured.

## Open decisions, not yet answered

- **WisprFlow** — quit it, remove it from login items, uninstall it, or leave
  it. Asked once, dismissed without an answer.
- **Vorssaint module list** — roughly 50 of ~66 modules from that reference
  app are still unbuilt. No shortlist has been agreed.
- **Reference repos under `~/DynamicNotch`** (Atoll 230 MB, Sapphire 380 MB,
  boring.notch 9.6 MB) — kept per CLAUDE.md as read-only reference material.
  Nobody has asked to remove them; flagging only because of the disk pressure
  noted above.
- **Push the one outstanding commit (`7ac8462`) to `origin/main`?** Not done
  automatically — this project's convention is to ask before pushing.

## Priority order for the next session

1. **Per-app volume, with real speakers.** The one feature that can make the
   Mac sound wrong, and the one most overdue for a real test.
2. **Switcher: hold ⌥, tap Tab, release.** Does it land on the right app now,
   focused, not just unminimised? Does the pie-wedge hover actually feel
   right, or does the dead zone need adjusting?
3. **Brightness key**, now that Accessibility is granted and the app has been
   relaunched since. One press, one honest report of what appears.
4. **Turn on "Always show on external displays"** and confirm the pill is
   actually visible on the monitor this whole conversation started because of.
5. Everything else in TESTING.md §13, at leisure.
