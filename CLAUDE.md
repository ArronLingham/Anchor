# Anchor

One native macOS app: a dynamic notch bar (from Atoll), with dictation replacing
WisprFlow and an app launcher (LaunchMe) built fresh. The target feature set is
the union of what Atoll, Sapphire and boring.notch each do, delivered in phases.

Plans: `~/.claude/plans/i-want-to-make-recursive-fog.md` is the current plan of
record (repo, roadmap, licensing). `i-want-to-build-functional-pinwheel.md` is
the 86-item manual test checklist, mirrored into `TESTING.md`.
`i-want-to-design-luminous-hennessy.md` is the usage-watcher design.

## How to work with me

**Don't narrate.** Do the work, then report the outcome. No running commentary, no "now I'll do X", no explaining tool calls before making them. Skip preamble and postamble.

**Surface decisions, not process.** When you need input, state the choice in one or two lines with a clear recommendation. Don't present an exhaustive survey of options — pick one and say why in a sentence.

**Report at the end, briefly.** What changed, what broke, what's next. Numbers and file paths over prose. If something failed, say so plainly with the error.

**Ask before:** anything outward-facing (pushing, creating repos, publishing), installing tooling, or deleting code that isn't obviously dead. Local edits, builds, and measurements need no confirmation.

**Don't ask about:** which file to edit, whether to run a build, formatting choices, or anything the plan already settles.

## Project constraints

- **Low CPU is the top priority.** Measure before and after any perf change; record idle CPU% and RSS. Never add a polling loop where an event-driven API exists.
- **Native Swift only.** No Electron, no Node, no sidecar processes.
- **macOS 26+ / Apple Silicon only.** `MACOSX_DEPLOYMENT_TARGET = 26.0`, arm64-only.
- **Personal use.** The GitHub repo is private, so nothing is distributed and the GPL/AGPL obligations stay dormant. See Licensing — this is a one-way door.
- **Dictation uses Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber`**, not Whisper. Keep it behind a protocol so a swap stays possible.

## Layout

The repo is `~/Anchor`, pushed to `github.com/ArronLingham/Anchor` (**private** —
see Licensing below). It used to sit at `~/DynamicNotch/Anchor/Atoll`, which is
why the Xcode project is still `Anchor.xcodeproj`.

| Path | What |
|---|---|
| `Anchor/` | The app. Swift/SwiftUI; product name `Anchor`. |
| `tests/` | Standalone harnesses — see Tests below. |
| `scripts/measure.sh` | CPU/RSS sampler. Every figure in this file was taken with it. |
| `~/DynamicNotch/{Atoll,Sapphire,boring.notch}` | **Reference only.** Read for behaviour. GPL-3.0, GPL-3.0, AGPL-3.0. |
| `~/DynamicNotch/Anchor/{Anchor,WisprFlow}` | **Stale.** `Anchor/` is an abandoned 10-commit checkout of this repo; `WisprFlow/` is the Electron app dictation replaced. |

## Not built, and why

These are not oversights — each needs something on the user's machine that is
theirs to grant, and none should be built without asking first.

| Feature | Blocker |
|---|---|
| Per-app volume, per-app EQ | Needs a virtual audio driver / HAL plug-in installed to `/Library/Audio/Plug-Ins/HAL` with admin rights. macOS has no public per-process volume API; `AudioHardwareCreateProcessTap` can *observe* a process's audio but not control its level. |
| Camera mirror | `ENABLE_RESOURCE_ACCESS_CAMERA = NO` in both build configurations, and `tests/test_privacy_configuration.py` has `test_camera_entitlement_is_not_reintroduced` pinning it. |
| Face ID / proximity unlock | Needs the privileged-helper story settled, and only an *Apple Development* identity exists here — no Developer ID Application. |
| Battery charge *limit* | **Probably not a helper problem — that earlier claim looks wrong.** See "SMC access" below. Needs one write attempt to settle, which is a write to the battery controller and wants a human present. |
| Fan control | **Not applicable to this Mac.** `Mac14,2` is a MacBook Air M2 and is fanless: zero `AppleSMCFanControl` nodes, zero fan entries in the `AppleSMC` ioreg tree. There is no fan to control. |
| Notification mirroring | Full Disk Access. |

## Licensing

The repo is private, and that is load-bearing rather than incidental. Anchor
derives from boring.notch and Atoll, both GPL-3.0. Publishing it would be
distribution and would trigger their copyleft; porting Sapphire source, which is
AGPL-3.0, would bind the result to the stricter licence still. Keep `NOTICE`,
which records the boring.notch -> Atoll chain. Settle the licence question
before the repo is ever made public, not after.

Sapphire's dependency graph pulls in Firebase, GoogleAppMeasurement and the
Google Ads on-device conversion SDK. Port the source that implements a feature;
do not let that graph follow it in.

## Atoll gotchas

- **Never construct a singleton from `AppDelegate`'s stored properties.** SwiftUI
  builds the delegate on the main thread *before* the run loop starts. Any
  singleton that blocks in `init` (IOBluetooth waits on a main-queue semaphore;
  reading `~/Downloads` blocks on a TCC prompt) deadlocks the whole app at launch
  and `applicationDidFinishLaunching` never runs. They are `lazy var` for this
  reason — keep them that way, and defer blocking work in any new manager's
  `init` with `DispatchQueue.main.async`.
- **A running process is not a working app.** This deadlock survived several
  rounds of "launches fine, no crashes, 0 children" because all of that was true
  while the app was hung. Verify a real side effect instead — e.g.
  `ps -o state= -p $(pgrep -x OSDUIHelper)` should print `T`.

- ~93 `static let shared` singletons; no central store.
- ~350 `Defaults` keys in `models/Constants.swift:833+` — the de-facto feature-flag registry. Flip switches before deleting code.
- `ContentView.swift` (1,887 lines) observes 12 `ObservableObject`s and ~34
  `@Default` keys. **`@ObservedObject` has no per-property granularity** — any
  `objectWillChange` from any of them re-renders the whole view, even for
  properties this view never reads. Split it before adding to it.
  - Don't try to move its methods into an `extension ContentView` in another file.
    The lifecycle handlers alone touch ~30 `private` members; making them all
    internal to win a line count trades away real encapsulation. The honest fix is
    to lift state into a model object, not to relocate functions.
  - **The re-render cost is smaller than it looks, and is not the reason to
    split.** All twelve publish rarely — the one high-frequency value in the app,
    `DictationManager.LiveOutput.inputLevel`, is already on a nested observable
    that only its leaf view watches. Idle median CPU is 0.00. Split it for
    ownership, not for a performance number you will not be able to measure.
  - `MusicControlWindowController` is what "lift state into a model object" looks
    like here: eight `@State` fields holding three `Task`s, a visibility
    deadline, a suppression flag and a deferred-sync queue, plus twenty methods,
    none of which drew anything. Follow it for the next one.
  - The five remaining low-use observations (`privacyManager`, `dictationManager`,
    `claudeUsageManager`, `capsLockManager`, `recordingManager` — one or two
    references each) all feed the same mutually-exclusive `if/else if` chain that
    picks the closed-notch live activity. Extracting that selection is the next
    real step, and it is *per-screen*: the chain mixes manager state with `vm`
    state and screen-derived predicates, so a shared selector would be wrong.

- **`ContentView` is instantiated once per screen.** `AppDelegate` keeps
  `windows: [NSScreen: NSWindow]` and `viewModels[screen]`, and with
  `showOnAllDisplays` it builds one window, view model and `ContentView` for each.
  Anything held in that view's `@State` therefore exists N times.
  - **Fixed: every display now has its own control window.**
    `MusicControlWindowManager` was one shared instance that all N
    `MusicControlWindowController`s drove. `ensureWindow(on:)` returned the
    existing panel whatever screen it was handed, so `present()` dragged the one
    window onto whichever notch synced last, and a `hide()` from one screen tore
    down a window another screen still wanted — leaving that one's
    `isWindowVisible` stale-true so it would never re-present.
    `MusicControlWindowManager.manager(for:)` now returns one instance per
    display, keyed by `NSScreen.localizedName`; `hideAll()` covers quit and
    switching the feature off, and `pruneDetachedScreens()` runs on
    `didChangeScreenParametersNotification` so a manager cannot outlive its
    display holding a panel positioned off every remaining screen.
  - The controller records `boundScreen` when it presents rather than resolving
    the screen from its weak view model at hide time — otherwise a hide can land
    on a different display's panel, which is the whole bug. It also handles the
    notch moving between displays mid-present by tearing the old panel down and
    presenting on the new one.
  - **Still untested on real hardware — this was written without a second
    display.** Verified only that it builds, launches and behaves unchanged on
    one screen. `showOnAllDisplays` defaults to false but is *on* for this user,
    so these paths go live the moment a monitor is attached. Check it first if
    anything odd shows up around the floating control window.
- **Settings panes are one file each** under `components/Settings/`.
  `SettingsView.swift` is now the shell — the two tab enums,
  `SettingsHighlightCoordinator`, the search/highlight plumbing, `SettingsForm`
  and the container. It was 7,784 lines holding eighteen panes; it is 1,062.
  Add a new pane as its own file and register it in `SettingsTab`, and add it to
  `UISnapshotHarness.settingsPanes` so it is covered by the render sweep.
- `StatsManager.swift:514-548` is the one good throttling pattern in the repo. Copy it.
- **A `Defaults` key referenced only inside `components/Settings/` is a dead
  switch.** This repo produces them steadily — Phase 1 alone left several
  behind. The audit that finds them:
  ```bash
  # keys whose only references live in the settings panes
  grep -oE 'static let [a-zA-Z0-9_]+ = Key<' Anchor/models/Constants.swift |
    awk '{print $3}' | while read -r k; do
      refs=$(grep -rln "\.$k\b" Anchor --include='*.swift' | grep -v models/Constants.swift)
      [ -n "$refs" ] && [ -z "$(echo "$refs" | grep -v components/Settings/)" ] && echo "$k"
    done
  ```
  It found four of 320: `selectedDownloadIconStyle` (defaulted to a value the
  app then ignored, and had no control at all), `customVisualizers` (the pane
  adds them, nothing renders them), and `showEmojis` / `systemHUDSensitivity`
  (`@Default` properties declared and never read even in their own file — live
  subscriptions re-rendering a pane for nothing).
- **Zero unreferenced keys is not the same as zero dead switches.** All 320 keys
  are referenced somewhere; the dead ones are referenced *only* by their own UI.
- **Two adjacent toggles read as duplicates when one is mislabelled.**
  `playerColorTinting` was captioned "Enable colored spectograms", a misspelt
  copy of the toggle above it, so the pane showed two identical-looking switches
  doing different things.
- **Keep high-frequency `@Published` values on their own nested observable.**
  `DictationManager.LiveOutput` is the reference: `state` changes ~4x per dictation
  and `ContentView` must watch it, but `inputLevel` changes 10-20x a second. On one
  object, the level meter re-rendered the entire notch for the whole dictation.
  Only the leaf view observes `LiveOutput`.
- Five SPM packages are pinned to `main`, not a version — builds can break with no local change.

## CPU measurements

**Every figure before the deadlock fix was measured on a hung app and is
meaningless.** Everything below was measured after it:

| Build | mean | median | p90 | max | RSS mean |
|---|---|---|---|---|---|
| v2.2.0 installed (Release), original baseline | 1.93% | 1.90% | — | 3.00% | 27 MB |
| Debug, steady (`.dev` domain — waveform off) | 0.02% | 0.00% | — | 0.80% | 58 MB |
| Release `e88b20b`, before the AudioTap fix | 0.95% | 0.80% | 1.30% | 8.00% | 27 MB |
| Release, pre-Phase-4, machine in use | 0.72% | 0.70% | — | 1.90% | 13 MB |
| Release + usage watcher, idle machine | 0.07% | 0.00% | — | 1.70% | 14 MB |
| **Release, after the AudioTap fix** | **0.08%** | **0.00%** | **0.10%** | 2.70% | **16 MB** |
| Release 2026-08-24, **live Claude session** (icon cache v1) | 0.35% | 0.00% | 0.49% | 4.30% | 49 MB |
| Release 2026-08-24, live Claude session, **icon cache v2** | 0.29% | 0.00% | 0.48% | 8.76% | **36 MB** |
| **Release 2026-08-25, six features added, all off** | **0.100%** | — | — | — | **26 MB** |
| **Release 2026-08-25, end of the cleanup pass, quiet** | **0.08%** | **0.00%** | 0.48% | 0.48% | **81 MB** |
| Release 2026-08-25, + Touch ID and per-display control windows | 0.09% | 0.00% | 0.48% | 0.48% | 80 MB (unsettled) |
| **Release 2026-08-25, fully settled (12+ min), two runs** | **0.30% / 0.35%** | 0.47% | 0.48% | 0.48% | **18.9 / 19.1 MB** |

**RSS needs ~12 minutes to settle, not 5, and every reading above taken at a
5-minute settle is of an app that had not finished settling.** Watched on one
process: **96 -> 80 -> 45 -> 24 -> 19 MB** over roughly twelve minutes. Two
independent 180 s samples at 12+ minutes both give **~19 MB**, close to the best
16 MB row this file has ever recorded.

An earlier note here claimed ~80 MB was the steady state and that the 26 MB row
"does not reproduce". **Both claims were wrong** and are the reason this
paragraph exists. The A/B behind them — `7178fbe` at 85.2 MB against the new tip
at 79.4 MB — is still valid as a *comparison*, because both arms were measured
equally early, and it does show the new code is not heavier. The absolute
numbers were simply of an unsettled app. **Let it run 12+ minutes before
believing any RSS figure.**

Not a leak, and not the launcher icon cache — that shows up under CG image /
IOSurface, which total under 5 MB with the launcher unused.

**The same build measured 0.09%, 0.53%, 0.30% and 0.35% in one afternoon, with
every thread parked in all four.** The spread between runs is larger than most
differences this table is used to argue about, so treat a single run as
approximate and do not read a change of less than roughly 2x as signal. The two
*settled* runs agree closely (0.30 / 0.35), which is the shape to trust: match
uptime before comparing anything.

**A measurable part of the floor is the sampler.** Lifetime CPU went from 1.69 s
at 9 minutes to 4.13 s at 16 — 2.4 s consumed across two 180 s `measure.sh`
runs, while a 3 s profile showed every thread in a wait state and `__proc_info`
as the largest non-idle leaf. `__proc_info` is what `ps` triggers by observing
the process. This is the same ~0.33% floor already documented under lyric
gating, from the same cause.

**The 0.08% row was measured with me doing nothing.** An earlier attempt in the
same session read **0.56% mean / 0.48% median** and was discarded: the whole
dead-code sweep ran inside its sampling window, and every tool call writes
`~/.claude/projects`, which is the one thing that drives the usage watcher's
FSEvents callback. Sampling this app from a Claude session measures the session
as much as the app. A third run was thrown away before that for overlapping an
`xcodebuild`, which CLAUDE.md already warned about — and I did it anyway.

The `e88b20b` row and the last row are a true A/B: same machine, same 120 s
settle + 240 s sample, 120 samples each, pid verified stable throughout both
runs. **12x less mean CPU and 41% less RSS.**

The 0.02% Debug row is not comparable to the Release rows. It was measured
against the `.dev` defaults domain, where `enableRealTimeWaveform` is off; the
production domain has it on, which is what the 0.95% row is actually measuring.

The two Phase-4 rows are not a clean A/B either — the first was taken while the
machine was being worked on. The controlled comparison for the usage watcher is
the on/off pair in the Phase 4 section, which shows no difference.

**The 2026-08-24 row is not a regression against the 0.08% row above it, and
must not be read as one.** Every earlier row was sampled on an idle machine.
That one was deliberately taken with a live Claude Code session running in
another window, because `~/.claude/projects` is written on every tool call in
every session and that is the only thing that exercises the usage watcher's
FSEvents callback at all. It is the first measurement of that path under load,
and the shape is the one to want: **median 0.00** with the mean carried by
occasional bursts. Compare it only to another loaded run.

The 2026-08-25 row is the check that mattered after adding six features: they
default off, and the claim that off costs nothing is exactly the sort of thing
that should be measured rather than asserted. Taken from cputime over a 120 s
window after a 5-minute settle, not sampled — 0.12 s of CPU for 120 s of wall
clock. It is *lower* than the rows above it because the lyric-sync gate landed in
the same build.

The v1/v2 icon-cache pair is a real A/B — same machine, same 5-minute settle,
same 180 s sample, **88 samples each**, both with a live Claude session running.
Read it as an RSS fix and nothing more:

- **RSS: 49 MB -> 36 MB mean**, max 71 -> 62. Real, and the expected size.
- **CPU: unchanged.** 0.35% -> 0.29% mean looks like an improvement and is not
  one. Median is 0.00 in both, p90 is 0.49 vs 0.48, and the max went *up*,
  4.30% -> 8.76%. With a zero median the mean is carried entirely by a noisy
  tail. The icon cache is not on any hot path; it had no reason to change CPU
  and did not.
- **Disk: 129 MB -> 2.1 MB**, over more apps (87 -> 116).

A first attempt at the v2 arm reported 0.16% mean and was thrown away: it
collected **15 samples instead of 88**, and its p90 and max were both exactly
0.48, which is the signature of a window too short to see a tail rather than of
a quiet app. Check the sample count before believing any row here.

Sampling shows every thread parked in a wait state. RSS above the 16 MB row is
the launcher icon cache: `NSCache` holds up to 512 icons, and under v1 each one
decoded to a 1024x1024 RGBA bitmap of roughly 4 MB.

Let the app run for 5+ minutes before sampling — launch transients hit ~28%
and destroy the mean.

```bash
scripts/measure.sh Anchor 180 "<label>"
```

Every poller now parks on display sleep / screen lock / Low Power Mode via
`SystemActivityGate`.

**`AudioTap` is reference-counted, not launch-started.** It used to start from
`applicationDidFinishLaunching` whenever `enableRealTimeWaveform` was on and stop
only at quit, so a CoreAudio process tap (real-time IO thread, keeps the audio
HAL awake) *and* a 60 Hz main-run-loop `Timer` bridging `NSArray`->`[Float]` ran
for the whole session to feed a view that is only on screen while the notch is
open and music plays. `RealTimeAudioSpectrum` and `RealTimeWaveformScrubberView`
now `acquire()`/`release()`; the tap is built on 0 -> 1 and torn down on 1 -> 0.
That one change is nearly all of the 0.95% -> 0.08% above.

- Smoothing moved off the timer into `getSmoothedMagnitudes()` and is derived
  from elapsed time, so it looks identical at any caller rate.
- `restartCapture()` must gate on `consumerCount`, **not** `captureIsRunning`.
  `startCaptureSync()` bails when no target music app is running, leaving
  `captureIsRunning` false — gating on it means the waveform never starts for an
  app launched after the notch was already open.
- `displayMagnitudes`/`lastSmoothingTick` are main-thread only; the audioQueue
  paths that reset them hop to main.

### Lyric sync gating — measured 2026-08-25

Replacing the lyric loop's 300 ms poll with sleep-until-next-line helped while
playing and left it waking once a second while *paused*, and against *untimed*
lyrics, where no line can change and `updateCurrentLyric` returns immediately.

| | lyrics on | lyrics off |
|---|---|---|
| before gating | 0.48% median | 0.24% median |
| after gating | 0.33% | 0.33% |

Identical on and off is the result to want: the feature now costs nothing at
idle. The 0.33% floor is not lyrics and not reducible from here — a 20 s profile
at 1 ms finds 32 non-idle leaf samples out of ~20,000, and the largest single
leaf is `__proc_info`, which is what `ps` triggers by observing the process.
Lifetime average over 4h25m is 0.094%.

**A 7-sample run reported 0.00% median / 0.00% p90 for this and was wrong to
quote.** It is in the commit message of 3e8136d, which overstates the result.
Two runs have now been discarded in this project for the same reason — check the
sample count before believing any figure, including your own.

**`scripts/measure.sh` aborts if the pid changes mid-run.** Two measurements in
this environment were silently garbage because the app was replaced underneath
the sampler, and were quoted for weeks before that surfaced. There is no longer
a separate `measure-strict.sh`; the strict check is always on.

It samples `cputime` and divides by elapsed wall time. Until 3e8136d it divided
by a *string*: it used `date +%s.%N`, and macOS `date` has no `%N`, so every
elapsed-time term was literally `1787610000.N`. Figures taken before that fix are
not comparable with ones taken after it.

It samples `cputime` and divides by elapsed wall time. Do not "simplify" it to
`ps -o %cpu`, which reports a lifetime average — for a process that has been up
for hours that number describes no particular moment.

The harness lived only in a session scratchpad until 2026-08-24 and was lost with
it. It could not have been committed: `.gitignore` excluded `*.sh` outright, so
adding it staged nothing and looked like it had worked. `scripts/` and `tests/`
are now negated. **Check `git check-ignore -v <path>` if a file you added does
not show up in `git status`** — that block also swallows `*.py` and `*.txt`.

## Verifying the UI

Screen-recording and accessibility grants are both denied here, so UI is
checked by rendering it:

```bash
ANCHOR_RENDER_UI=/tmp/uishots \
  <build>/Anchor.app/Contents/MacOS/Anchor
```

Writes a PNG of the launcher and every settings pane in light and dark, then
exits before any manager starts — it returns early from
`applicationDidFinishLaunching`, so it never suppresses the OSD. Inert unless
the variable is set. **Debug only**, deliberately: it renders the settings pane
that displays the ntfy topic read from the Keychain, so in a Release build
anyone could `open -n /Applications/Anchor.app --env ANCHOR_RENDER_UI=/tmp/x`
and read the topic out of a PNG. See `helpers/UISnapshotHarness.swift`.

- Do **not** use `ImageRenderer` — it draws AppKit-backed controls as a yellow
  placeholder (`TextField`) and never materialises lazy containers, so the app
  grid comes out empty. The harness uses `NSHostingView` in an offscreen window.
- Appearance must be set on the *window*; `.environment(\.colorScheme)` does not
  reach AppKit controls inside a hosting view.
- Settings panes need `.formStyle(.grouped)` and a `SettingsHighlightCoordinator`
  in the environment, or they render as unstyled floating labels. Three
  (`GeneralSettings`, `HUD`, `NotesSettingsView`) also need a
  `DynamicIslandViewModel`, and `About` takes an `SPUStandardUpdaterController` —
  build it with `startingUpdater: false`, never a live one.
- **The sweep covers every settings pane**, so a pane that renders empty is
  caught here rather than by clicking through 21 sidebar tabs. Add new panes to
  `settingsPanes`. All panes share one 720x1800 canvas; a pane that outgrows it
  is visibly cut off, which is the signal to raise it rather than a failure.
  (It was 720x1200 until Appearance outgrew it.)
- **A short sweep means it was killed, not that a pane failed.** The full run
  writes **50 PNGs — 25 light, 25 dark** — and takes ~85 s at the 1800 canvas.
  It renders every pane dark first, then every pane light, so a run cut off
  early looks exactly like "all the dark ones worked and the light ones are
  broken". Three runs here returned 37, 33 and 50 PNGs purely from where the
  kill landed. Count the PNGs and check for both appearances before reading
  anything into a missing pane.

## Naming

The app is **Anchor** throughout: `/Applications/Anchor.app`, bundle id
`com.arronlingham.Anchor`, process `Anchor`, `Anchor.xcodeproj`, scheme `Anchor`,
source in `Anchor/`, types `Anchor*`. This file previously recorded the opposite
decision — that renaming ~671 internal references was not worth it — and that was
reversed in 9b14ade and the commit after it.

Three things keep upstream's name on purpose:

- **`Copyright (C) 2024-2026 Atoll Contributors`**, on every source file. The GPL
  requires copyright notices be preserved. Only the title line above it is this
  project's to change.
- **`/auth/DynamicIsland`** in the YouTube Music client — a path on upstream's
  service, not a name this project owns.
- **`~/Library/Application Support/DynamicIsland`** is *not* referenced any more,
  but `AppSupportDirectory` moves it to `Anchor/` on first use rather than
  abandoning what is in it. Do not "simplify" that away until it has run
  everywhere it needs to.
- **The Apple Notes sync folder is still `Atoll`, and must stay.**
  `AppleNotesSyncManager.syncFolderName` names a real folder in the user's
  Notes, and `atollTagPattern` is a marker embedded in the body of their actual
  notes — it is how a note is matched back to its record. Renaming either
  creates a second folder and orphans everything already synced. The Notes
  settings text interpolates the constant rather than hardcoding a name,
  because a cleanup pass here did rename the prose and left it describing a
  folder that does not exist.
- **`utils/Logger`'s subsystem must match the diagnostic collector's
  predicate.** It did not: the logger published under `com.ebullioscopic.Atoll`
  while `collectDiagnostics` filtered on `com.arronlingham.Anchor`, so the
  app's own log lines were never collected. Same mismatch as the crash-log
  filename bug, in the other half of the same feature.

GPL headers still credit Atoll and boring.notch, and must keep doing so.
`NOTICE` records the fork and rename above upstream's original notice.

Changing the bundle id resets TCC grants (unavoidable — they key on identifier
plus signature) and would have reset ~300 settings; `PreferencesMigration`
carries the settings over from `com.Ebullioscopic.Atoll` on first launch.
`PreferencesMigration` no longer exports a backup to the Desktop — that
code is gone, and this file claimed otherwise for a while. Nothing in the
app writes to the Desktop at all, which is why
`NSDesktopFolderUsageDescription` was removed.

## Install / signing

The daily-driver build is a **signed Release** at `/Applications/Anchor.app`,
which is also the login item.

```bash
xcodebuild -project Anchor.xcodeproj -scheme Anchor \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="Apple Development: arronlingham@icloud.com (Q4FNFX8QSH)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=KLWHJX56T3 \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

- **Sparkle is disabled on purpose.** Every channel in `UpdateChannel` points at
  *upstream* Atoll's appcast, so a live updater eventually replaces Anchor with
  upstream — it already did once, v2.2.0 → v2.3.3. The updater is not started,
  the delegate returns no feed, and `SUFeedURL` is stripped. Don't re-enable it.
- **`ENABLE_RESOURCE_ACCESS_*` in project.pbxproj overrides the `.entitlements`
  file.** The file said audio-input and no camera while the built app shipped
  the reverse. Change entitlements in *both* places, and `tests/` pins them.
- Upstream's last build was at `~/Desktop/Atoll-upstream-v2.3.3-backup.app`. It
  is gone.
- Install with `ditto <built>/Anchor.app /Applications/Anchor.app`, then
  `open -a /Applications/Anchor.app`. Verified 2026-08-24: signs under team
  KLWHJX56T3, `codesign --verify --strict` passes, all three Sparkle guards hold
  (`startingUpdater: false`, `feedURLString` returns nil, no `SUFeedURL`).
- **`ANCHOR_RENDER_UI` is compiled out of Release** — confirmed, 0 occurrences in
  the Release binary. It matters: the harness renders the settings pane, which
  shows the ntfy topic read from the Keychain, so in a Release build anyone
  running as the user could `open -n /Applications/Anchor.app --env
  ANCHOR_RENDER_UI=/tmp/x` and read the topic out of a PNG. Keep it `#if DEBUG`.

### Quitting restores the system OSD — verified

Anchor SIGSTOPs `OSDUIHelper` to suppress the native HUD, so a build that dies
without running its termination handler leaves the volume and brightness keys
showing nothing at all until reboot. TESTING.md §5 item 43 is the check, and it
**passes** as of 2026-08-24: `OSDUIHelper` sat in state `T` while Anchor ran and
returned to `S` after `tell application "Anchor" to quit`.

```bash
ps -o state= -p "$(pgrep -x OSDUIHelper)"    # T while running, S after quit
```

If a crash or `kill -9` ever leaves it frozen, `kill -CONT $(pgrep -x OSDUIHelper)`
fixes it without a reboot.

## Build (Debug, for iteration)

```bash
xcodebuild -project Anchor.xcodeproj -scheme Anchor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

- The project hardcodes upstream's team `9Y64TRM77N`; ad-hoc (`-`) signing is required until it's changed. A real `Apple Development: arronlingham@icloud.com (Q4FNFX8QSH)` identity exists and should be used once TCC grants matter.
- SwiftTerm needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) — already installed. SwiftTerm is a Phase 1 deletion target, which removes this dependency.
- Build is clean: **0 errors, 82 warnings** in a clean Release build (it was
  94 before this pass; the "2 warnings" recorded here previously was long
  stale). Most are deprecated `onChange(of:perform:)` and `Text` `+`.
  **An incremental build reports far fewer — it only recompiles what changed —
  so only compare clean builds.**

## Tests

Neither harness needs an app build or a unit-test target — the project has only
a UI-test target, and adding one would mean surgery on a `.pbxproj` that uses
file-system-synchronized groups. Both compile the *real* source files with
`swiftc`, so they cannot drift from the implementation.

```bash
./tests/run_parser_tests.sh     # 19 cases over the banner wordings
./tests/run_watcher_tests.sh    # 7 cases, real FSEventStream over a temp dir
./tests/run_launcher_tests.sh   # 25 cases over fuzzy matching and the calculator
./tests/run_color_tests.sh      # 24 cases over the eight clipboard colour formats
python3 tests/test_privacy_configuration.py
```

`run_launcher_tests.sh` pins the behaviours this file records as having been
wrong: that `ss` ranks *System Settings* above *Chess* (the greedy-vs-DP bug),
that the acronym bonus makes initials win, that `100/3` is decimal rather than
integer `33`, that the integer rewrite does not split `7.5`, and that `%` is
refused. `FuzzyMatcher` and `CalculatorAction` are pure and import only
Foundation, so this harness needs no stub — unlike the watcher tests.

`run_color_tests.sh` checks what the colour picker actually pastes. A wrong
HSL hue sector is invisible in the swatch — that is drawn from RGB — so it would
be silently wrong work rather than a visible bug.

**A stub *file* cannot satisfy an `import`.** `LoggerStub.swift` works because
`Logger` is a type in the same module; `PickedColor` does `import Defaults`, so
the stub has to be compiled into a module actually named `Defaults`, with
`-emit-module` **and** `-c -parse-as-library` for an object to link against.
Without the object you get "protocol descriptor not found"; without
`-parse-as-library` swiftc treats the lone file as `main.swift` and you get a
duplicate `_main`. Linking SwiftUI this way warns about `SwiftUICore` not being
an allowed client — that is only a warning and the binary runs.

**Top-level code only runs in `main.swift`.** Both Swift harnesses put their
body in a `@main struct` for this reason; a file of bare `check(...)` calls
fails to compile with "expressions are not allowed at the top level".

`tests/support/LoggerStub.swift` stands in for `utils/Logger.swift`, which drags
in SwiftUI and the `Defaults` package for a log level the tests do not need.

**Build fixtures the way Claude Code writes them, not the way Foundation does.**
`JSONSerialization` escapes `/` as `\/`, which puts a backslash inside the zone
identifier and makes `TimeZone` reject it. Claude Code is a Node process, so its
transcripts come from `JSON.stringify`, which leaves `/` raw — a real transcript
contains `(America/Toronto)`. The watcher's `unescaped()` deliberately handles
only `\n` and `\"`, so a fixture that over-escapes fails against correct code.

## Git

Repo is **`ArronLingham/Anchor`**, **private** — standalone (not a fork), so
commits count on the contribution calendar. Branch `main`. The Atoll fork is
remote **`atoll`**, renamed from `upstream` so it reads as somewhere to
cherry-pick from rather than somewhere to merge from.

**Every commit is authored by `ArronLingham
<196463080+ArronLingham@users.noreply.github.com>`** (set repo-locally, not
global) and carries no co-author trailer. Keep it that way.

**Commit the call site and the thing it calls together.** `cdd6503` committed
`ClaudeUsageManager.shared.start()` in `DynamicIslandApp` while the manager
itself stayed untracked, so the tip did not build for five commits and nobody
noticed, because the working tree — which had the untracked files — built fine.
`git status` showing untracked files under `Anchor/` is a build-breaking
signal, not noise.

Pushes go over **SSH**, which is why the missing `workflow` OAuth scope does not
block them; that restriction only applies to OAuth-over-HTTPS.

Git LFS is **disabled here on purpose** — upstream's LFS budget is exhausted and all 9 media objects are unreachable. Do not re-enable it; `git lfs install` re-adds a pre-push hook that blocks pushes.

## Dictation (Phase 2)

Hold **Cmd+Shift+D**, speak, release → transcript pastes into the focused app.

| File | Role |
|---|---|
| `managers/Dictation/SpeechTranscribing.swift` | Backend protocol — swap engines here |
| `managers/Dictation/AppleSpeechTranscriber.swift` | macOS 26 `SpeechAnalyzer` impl |
| `managers/Dictation/DictationManager.swift` | `AVAudioEngine` capture, state machine |
| `managers/Dictation/TextInjector.swift` | Pasteboard + synthesized ⌘V |
| `components/Live activities/DictationLiveActivity.swift` | Notch UI |

- **Deployment target is now macOS 26.0** (was 14.6) — `SpeechAnalyzer` requires it.
- Requires **Microphone** and **Accessibility** grants. Without Accessibility, `CGEvent.post` is silently dropped and nothing pastes.
- Injection synthesizes ⌘V rather than setting the AX value, because the AX route silently fails in Electron apps, terminals, and custom text views. Prior clipboard contents are restored 250 ms later.
- Nothing runs while idle — the audio engine only exists between key-down and key-up.

## Launcher (Phase 3)

**Option+Space** opens a Spotlight-style search panel.

| File | Role |
|---|---|
| `managers/Launcher/FuzzyMatcher.swift` | DP best-alignment scoring + acronym bonus |
| `managers/Launcher/AppIndex.swift` | Directory scan, ranking, launching |
| `managers/Launcher/AppIconCache.swift` | Memory + on-disk icon cache |
| `managers/Launcher/LaunchHistory.swift` | Frecency, 10-day half-life |
| `components/Launcher/LauncherPanel.swift` | Non-activating `NSPanel` |
| `components/Launcher/LauncherView.swift` | Search field, switches grid/list/calc |
| `components/Launcher/LauncherGridView.swift` | Paged 7x4 Launchpad-style grid |
| `managers/Launcher/CalculatorAction.swift` | Inline arithmetic |

- **Safari lives in a cryptex.** `/Applications/Safari.app` is a symlink and
  `contentsOfDirectory` does not return it, so `/System/Cryptexes/App/System/Applications`
  is scanned explicitly. Any future "app is missing" report starts here.
- **Matching is a DP, not greedy.** Greedy took the first valid alignment, so
  `ss` matched *SyStem* and lost to *CheSS*. The acronym bonus (+45 when every
  matched char is a word start) is what makes initials work.
- `NSWorkspace.icon(forFile:)` hits disk every call — never call it per row per
  keystroke. Icons are rendered once at 64pt and cached by path+mtime.
- Directory scan, deliberately not `NSMetadataQuery`: a live Spotlight query
  wakes the app on every index change. Scan is 13 ms for 109 apps; search 0.4 ms.
- **`NSExpression` does integer arithmetic** when both operands are integers —
  `100/3` gives `33`, `1/0` gives `0`. `CalculatorAction` rewrites bare integer
  literals as decimals first. `%` is unsupported on purpose (percent vs modulo).
- Grid has **no drag-reorder or folders**, deliberately. The old Launchpad
  layout can't be migrated either — macOS 26 removed its database.

## Smaller features

| Feature | Where | Notes |
|---|---|---|
| Desktop number | `managers/SpaceIndicatorManager.swift` | Off by default |
| Battery history | `managers/BatteryHistoryManager.swift` | Off by default |
| Colour picker | `managers/ColorPickerManager.swift` | Cmd+Shift+P |
| Animation profiles | `animations/drop.swift` | Bouncy / smooth / snappy / instant |
| Touch ID lock | `managers/BiometricAuthManager.swift` | Off by default |

- **There is no public API for the current Space.** `SpaceIndicatorManager`
  reads SkyLight's `CGSCopyManagedDisplaySpaces`, the same list Mission Control
  numbers from, and filters to `type == 0`. Fullscreen apps each occupy their
  own Space, so counting them makes the number jump when you fullscreen
  something — which is not what anyone means by "desktop 3". Verified against
  the live window server before it was wired up: 4 desktops, current index 3.
  Driven entirely by `activeSpaceDidChangeNotification`; no timer.
- **Battery history has no sampler.** `BatteryActivityManager` already owns an
  `IOPSNotificationCreateRunLoopSource` and an observer registry, so history
  subscribes to that. A sample is written only when the level or charging state
  actually moves — on a machine sitting at 100% plugged in, that is nothing per
  hour. Repeat signals for one real change are collapsed and saves coalesced.
- **`NSColorSampler` is the system eyedropper.** AppKit owns the magnifier and
  the capture, so the colour picker needs no screen-recording grant and nothing
  of ours runs until the shortcut is pressed. The colour model is
  `models/PickedColor.swift`, which survived Phase 1 and already carries all
  eight output formats — a first pass here defined a second `PickedColor` and
  `ColorFormat` and collided at build time. Check `models/` before adding a type.
### SMC access — measured, and it contradicts what this file used to say

This file claimed SMC writes need a privileged helper signed with a Developer
ID. A read-only probe says otherwise:

- **`IOServiceOpen` on `AppleSMC` succeeds as the ordinary user.** No root, no
  helper. Key metadata and values read fine — `#KEY` reports 1631 keys.
- **`CHTE` is present, size 4, attributes `0xd4`** — which sets the writable
  bit (`0x40`). It currently reads `00 00 00 00`, i.e. no charge limit set.
  `ACLC` is also present and writable-flagged.
- The Intel-era keys are **absent** on this Mac: `CHWA`, `CH0B`, `CH0C`,
  `CH0I`, `BCLM`. Looking for those and finding nothing is what produced the
  wrong "needs a helper" conclusion.

**What is still unknown:** whether the AppleSMC user client actually permits a
*write* selector from an unprivileged process, or only advertises the attribute.
The only way to find out is to attempt a write to the battery charge
controller. That was deliberately not done unattended — it is hardware state,
the effect cannot be observed from here, and a wrong guess about `CHTE`
semantics changes how the machine charges. **Writing the current value back to
itself is the safe first test** if someone is at the keyboard.

`utils/SMC.swift` already has the read/write plumbing for this.

- **Battery *health* needs no privileges; only the charge *limit* does.** The
  `AppleSmartBattery` IORegistry node exposes `CycleCount`, `DesignCapacity`,
  `NominalChargeCapacity`, `Temperature` and `PermanentFailureStatus` to any
  process. `MacBatteryManager.currentHealth()` reads them and
  `BatteryHealthView` shows them. Verified against this machine: 386 cycles,
  4077 of 4563 mAh, 89%, 30.0 °C, condition Normal.
  - `Temperature` is in **hundredths of a degree Celsius** — 3004 is 30.04 °C.
    Reading it as Kelvin gives an absurd answer, which is the check that the
    scale is right.
  - `NominalChargeCapacity` is what System Information calls maximum capacity.
    `AppleRawMaxCapacity` is the pre-calibration figure and reads lower; it is
    the fallback only.
  - Read on appear, never polled. Cycle count moves a few times a week and
    capacity a few times a year.

- **`AudioHardwareCreateProcessTap` returns `noErr` with an invalid tap ID when
  the caller lacks the audio-capture grant.** A standalone probe got status 0
  and `tapID == kAudioObjectUnknown` for both itself and Spotify. Status alone
  is not success — always check the ID too, which `PerAppAudioManager` does. The
  safe consequence is that a permission failure mutes nothing and marks nothing
  muted, rather than half-applying.
- **Per-app audio is mute, not a volume slider, deliberately.** A
  `CATapDescription` with `muteBehavior = .muted` silences a process outright,
  which needs no playback path. Arbitrary *gain* would mean muting the app,
  capturing it through an aggregate device, applying a multiplier and
  re-rendering to the output device from a real-time IOProc — an audio engine
  permanently in the path of the user's sound, where a mistake is distortion or
  silence rather than a visual bug. Not something to land unverified.
  There is **no per-process volume property** in CoreAudio; `kAudioProcessProperty*`
  covers PID, bundle ID, devices and is-running only. Re-rendering is the only route.
- Taps are owned by the creating process, so a muted app un-mutes by itself if
  Anchor exits or crashes. That is the reason this was safe to build unattended.

- **`LocalAuthentication` needs no entitlement and no privileged helper.** The
  match happens in the Secure Enclave and this process only ever sees a yes or
  no, which is why Touch ID was buildable while charge limiting — also filed
  under "security" — is not. `BiometricGate` only *calls* its content closure
  once unlocked, so a gated view is never built; gating with `.opacity` or
  `.blur` would leave the real text one screenshot away. The clipboard panel is
  gated before the panel is constructed for the same reason.
- It evaluates `deviceOwnerAuthentication`, not the biometrics-only policy, so a
  lid-shut Mac or three failed attempts falls back to the login password rather
  than locking the user out. If no policy is available at all it **opens** — this
  is a convenience lock over local UI, not a security boundary.

- **`AnchorAnimations` is not what draws the notch.** It looks like the
  animation owner and carries a TODO saying so, but `ContentView` hardcoded its
  own springs and never read it. Adding a profile there alone would have been
  another dead switch; `activeNotchStateAnimation` reads the profile now.

## Claude usage watcher (Phase 4)

Detects when a Claude Code session hits its usage limit, counts down to the
reset in the notch, notifies the phone, and resumes the halted session.

| File | Role |
|---|---|
| `managers/ClaudeUsage/ClaudeLimitParser.swift` | Banner text → `(resetDate, timeZone)`. Pure, no I/O |
| `managers/ClaudeUsage/ClaudeTranscriptWatcher.swift` | `FSEventStream` on `~/.claude/projects` |
| `managers/ClaudeUsage/ClaudeSessionRegistry.swift` | Live sessions from `~/.claude/sessions/<pid>.json` |
| `managers/ClaudeUsage/ClaudeUsageManager.swift` | State machine, reset timer, resume |
| `managers/ClaudeUsage/PhonePush.swift` | ntfy POST + Keychain topic |
| `components/Live activities/ClaudeUsageLiveActivity.swift` | Notch countdown |
| `components/Settings/ClaudeUsageSettings.swift` | Settings pane |

- **The reset time exists nowhere on disk except a banner string.** There is no
  API, socket, or daemon — `~/.claude/daemon/` holds only an opaque `control.key`.
  The banner is an ordinary `assistant` text event:
  `You've hit your session limit · resets 8:10pm (America/Toronto)`. Separator is
  U+00B7, apostrophe is ASCII `'` (both verified by hexdump). Observed forms:
  `5am`, `12pm`, `1:20pm`, `8:10pm`. **`12pm` is noon and appears 63×** — the
  am/pm split is the highest-frequency place this can go wrong.
- **Parsing is anchored to the line's own `timestamp`, not to now.** The first
  FSEvent for an unseen file scans its existing tail, so a *stale* banner would
  otherwise schedule a phantom reset up to 24 h out.
- **Only `type == "assistant"` lines count.** Quoted banners in prose parse just
  as well as real ones — 23 of 89 fully-matching lines on this machine came from
  `user`/`queue-operation`/`attachment` events, including this feature's own
  plan file. The decode and the type check are **one guard**: splitting them let
  any line that failed to decode skip the check and reach the parser.
- **The real halt test is transcript growth, not `isAlive`.** A session that
  stopped writes nothing after its banner; one that merely quoted the wording
  kept going. The transcript size is recorded at detection and re-checked at
  reset. `ClaudeSessionRegistry.isAlive` cannot do this job — it runs hours
  later, by which point *every* session has exited, so it would wave a false
  positive straight through. Both paths are covered by the fixture test.
- Auto-resume is capped at **3 consecutive resumes of the same session** and
  refuses a reset more than **2 h stale**. A resumed run appends to the very
  transcript being watched, so without the cap a task too large for one window
  re-arms the loop forever, unattended.
- **Phone push is sent on detection, not at reset**, using ntfy's `Delay:` header
  with a Unix timestamp. If the Mac is asleep at 1:40 am no local timer fires, so
  ntfy holds it server-side. Min delay 10 s, **max 3 days**.
- The ntfy topic is the only thing protecting the channel — it lives in the
  **Keychain**, deliberately not in `Defaults` (a world-readable plist).
- Auto-resume runs `claude -r <sessionId> -p "<prompt>"` with `cwd` from the
  **`cwd` field inside the JSONL** — the directory name is lossy for any path
  containing a hyphen. Only the single most recently halted session resumes;
  restarting every queued one would re-exhaust the window in minutes.
- **CPU cost is nil.** A/B on the same Debug build against the real (hot)
  projects directory: watcher on 1.27 % / 31 MB, watcher off 1.29 % / 36 MB —
  the off arm is *higher*, i.e. the difference is noise. Signed Release on an
  idle machine: **0.07 % mean, 0.00 % median, 14 MB**.
  **Never sample while a build is running** — one measurement read 10.6 % mean
  purely because `xcodebuild` was running concurrently, and `ps %cpu` is a
  decaying average, so it stays wrong for a while after the load stops.
- The countdown live activity sits **below** music in `ContentView`'s closed-notch
  chain, and `.claudeUsage` is excluded from the `InlineHUD` /
  `SystemEventIndicator` branches. Both matter: everything ranked above music is
  short-lived, and a usage window lasts hours; and an unhandled sneak-peek type
  in `InlineHUD` renders nothing while still winning the branch.
- **Dev hooks are `#if DEBUG` and must stay that way.** `UISnapshotHarness`
  shipped unguarded in the signed Release, and once it rendered
  `ClaudeUsageSettings` — whose `onAppear` loads the ntfy topic out of the
  Keychain — anyone running as the user could
  `open -n /Applications/Anchor.app --env ANCHOR_RENDER_UI=/tmp/x` and read the
  credential out of a PNG. The Keychain ACL does not help when the process doing
  the reading *is* Anchor. `ANCHOR_CLAUDE_BIN` was the same shape: an env var
  choosing a binary the app then executes. Verify after any Release build:
  ```bash
  strings -a /Applications/Anchor.app/Contents/MacOS/Anchor | grep -c ANCHOR_
  ```
  must be 0. The topic field is a `SecureField` for the same reason.
- Testing hooks, inert unless set: `ANCHOR_CLAUDE_PROJECTS_ROOT` redirects the
  watcher at a fixture tree, `ANCHOR_CLAUDE_BIN` points resume at a stub. Never
  append a test banner to a real transcript — this feature is strictly read-only
  with respect to Claude Code's state.
  ```bash
  open -n <build>/Anchor.app --env ANCHOR_CLAUDE_PROJECTS_ROOT=/tmp/fake \
    --env ANCHOR_CLAUDE_BIN=/tmp/stub-claude
  ```
  Fixture generator and stub live in `scratchpad/usagetest/`.
- A GUI launch from a detached shell exits immediately; use `open -n --env`.


### Verified 2026-08-24

ntfy's scheduled delivery is the load-bearing assumption — the Mac cannot fire a
local timer while asleep, so the push is sent at *detection* time carrying a
`Delay` header and held server-side. Checked end to end against a throwaway
topic:

| Claim | Result |
|---|---|
| `Delay: <unix ts>` accepted | HTTP 200, echoed `time` equal to the requested instant |
| Held, not delivered early | absent from `?poll=1`, present in `?poll=1&sched=1` |
| Delivered on time | arrived at the scheduled second |
| Sub-10s delay rejected | HTTP 400, `{"code":40005,"error":"invalid delay parameter: too small"}` |

That last row is why `makeRequest` sends immediately rather than scheduling when
the reset is nearer than the minimum: a refused schedule delivers nothing at all.

The topic lives in the **Keychain** (`com.arronlingham.Anchor.claudeUsage` /
`ntfyTopic`), never in `Defaults`. The topic name *is* the credential — anyone
holding it can read and publish to the channel — and `Defaults` lands in a
world-readable plist. `Constants.swift` carries a comment saying so; keep it.

**Not yet measured.** The CPU A/B for this feature has not been re-run, because
there is no installed build: `/Applications/Anchor.app` is gone. The FSEvents
callback is the risk and must be sampled with a live Claude session running in
another window, not at idle — `~/.claude/projects` is written on every tool call
in every session.

## Features added 2026-08-25

All four default **off** and cost nothing until enabled.

| Feature | Cat | Cost when on |
|---|---|---|
| Lyrics tab + tap-to-seek | 4 | one timer per lyric line, only while playing |
| Eye break (20-20-20) | 20 | one timer per interval |
| File shelf | 10 | none — event-driven only |
| System stats | 8 | one timer, **only while the Stats tab is open** |
| Window snapping | 16 | none until a drag starts |
| Caffeinate | 20 | none — a kernel power assertion |

Three rules these follow, and the next feature should too:

- **Reference-count anything periodic.** `SystemStatsManager` samples nothing
  unless a view has called `acquire()`. This is the `AudioTap` pattern and it is
  the difference between a stats readout costing nothing and costing 100% of the
  time for a tab that is open 1% of it.
- **Schedule, do not poll.** Eye break and the lyric sync both compute *when* the
  next thing is due and sleep exactly that long. Repeating timers are a last
  resort; when one is unavoidable give it leeway so the system can coalesce it.
- **A loop that no-ops is still a loop.** The lyric task was gated on the feature
  flag but not on whether it could change anything, and woke once a second
  against paused playback and untimed lyrics for 0.24% of a core. Gate on the
  work existing, not on the feature being on.

**Camera mirror (cat 20) and Face ID (cat 15) are deliberately not built.**
`ENABLE_RESOURCE_ACCESS_CAMERA = NO` in both build configurations and
`tests/test_privacy_configuration.py` carries
`test_camera_entitlement_is_not_reintroduced`. Enabling the camera broadens the
app's privacy surface and trips a test written to prevent exactly that; it needs
a decision, not an inference. The same applies to notification mirroring
(cat 19), which needs Full Disk Access.

## Speech API — verified working (Phase 0 spike)

Proven end-to-end on this machine: `en_CA` supported (30 locales), assets auto-download via `AssetInventory`, 8.7 s of audio transcribed in ~3.7 s including model load, punctuation and proper nouns correct.

```swift
let transcriber = SpeechTranscriber(locale: useLocale, preset: .transcription)
if await AssetInventory.status(forModules: [transcriber]) != .installed {
    try await AssetInventory.assetInstallationRequest(supporting: [transcriber])?.downloadAndInstall()
}
// results MUST be drained concurrently with analysis, or it deadlocks
let collector = Task { for try await r in transcriber.results { … } }
let analyzer = SpeechAnalyzer(modules: [transcriber])
_ = try await analyzer.analyzeSequence(from: file)   // or .start(inputSequence:) for live mic
try await analyzer.finalizeAndFinishThroughEndOfInput()
```

Two gotchas:
- **`.progressiveTranscription` emits cumulative volatile results** — each element is the whole utterance so far, not a delta. Concatenating them duplicates text. Use the *latest* for live preview.
- **`.transcription` emits only finalized results**, one per utterance. Use this for the text you actually paste.

Spike source: `/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/speechspike/`

## What was removed (Phase 1)

Shelf/LocalSend, ScreenAssistant, Stats, LLM usage tracking, Webcam/Camera,
ColorPicker, and the whole Extensions system (AtollExtensionKit, XPC host,
JSON-RPC server). **321 files / 100,148 LOC → 227 files / 75,098 LOC.**

Kept: notch core, media/music, lock-screen widgets, Calendar, Clipboard,
Notes + Apple Notes sync, Timer, Terminal, Battery, Bluetooth, HUD/OSD,
Downloads, Shortcuts, Lunar/BetterDisplay.

Cutting Extensions also closed a local security hole — the JSON-RPC server
on `localhost:9020` auto-authorised any local process. Verified nothing
listens on that port now.

Fixed since: `ContentView` rendered `NotchNotesView` for the `.clipboard`
case. `NotchClipboardList` already existed (the notes/clipboard split view
uses it) and was simply never wired to the tab. Also deleted the unreachable
stats-sizing block left behind by the Phase 1 removal — `statsRowCount`,
`enabledStatsGraphCount`, `statsAdditionalRowHeight`, the two `matters.swift`
constants, 5 dead `@Default` keys in `ContentView`, and 6 `Defaults.publisher`
subscriptions in `DynamicIslandApp` that debounce-resized the notch for a tab
that no longer exists.

## CPU offenders — status

Fixed in Phase 0.5 (commit `30e872e`): the `SystemOSDManager` 150 ms `pgrep`
loop, the unconditional 20 Hz hover poll, the flat 0.5 s clipboard poll, the
ungated 3 s Bluetooth poll, and both `/usr/bin/log stream` children. New
`SystemActivityGate` parks pollers on display sleep / screen lock / Low Power.

Still outstanding:
- `MusicManager` publishes 27 properties from one object, including `elapsedTime`.
  `ContentView` never reads it but still re-renders on every tick, because
  `@ObservedObject` invalidates on the object, not the property. The fix is the
  `LiveOutput` pattern below (or an `@Observable` migration); deferred because
  `elapsedTime` alone spans 7 files and the media surface is the most-used one.
  Playback progress itself is already cheap — `TimelineView` interpolates it, and
  the spectrum visualiser is a plain `NSView` driving CALayer animations.
- `ContentView.swift` still re-renders the whole notch on any manager `@Published`
  change (12 `ObservableObject` + 40 `@Default` in one 2,161-line view).
- `DoNotDisturbManager` 2 s assertions poll — mtime-gated and now given 1 s of
  leeway, so it coalesces. Low priority, but it is a poll where an event-driven
  API exists: the assertions plist could be watched with FSEvents, the way
  `ClaudeTranscriptWatcher` watches `~/.claude/projects`.
- `RealTimeWaveformScrubberView` drives a SwiftUI transaction per frame, now at
  30 Hz rather than 60. It starts on `onAppear`, **not** on hover — the older
  note here claiming "only while hovering" was wrong.

**OSD suppression caveat:** only a graceful quit (menu, ⌘Q) runs
`applicationWillTerminate` and resumes `OSDUIHelper`. A force-quit or crash
leaves it SIGSTOP'd, which kills the volume/brightness HUD system-wide until
the next launch re-suppresses a fresh one. Recovery: `killall -CONT OSDUIHelper`.
Trapping SIGTERM was tried and reverted — the dispatch handler never fired while
`SIG_IGN` did, leaving the app unkillable for 11s.

Also note `launchctl kickstart -k com.apple.OSDUIHelper` always fails under SIP
(`150: Operation not permitted`). Harmless — the SIGSTOP fallback is what works.

**Watch out:** `focusMonitoringMode` has two modes. `useDevTools` spawns a
persistent `log stream` on `duetexpertd`; onboarding picks it. `withoutDevTools`
(the code default) uses cheap mtime-gated polling instead. The dev build's
domain is `com.Ebullioscopic.Atoll.dev`, *not* `com.ebullioscopic.Atoll`.
