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
| ~~Per-app **EQ**~~ | **Built** — `Audio/PerApp/`, ported from FineTune. This row was stale. |
| Face ID / proximity unlock | Needs the privileged-helper story settled, and only an *Apple Development* identity exists here — no Developer ID Application. |
| Notification mirroring | Full Disk Access. |

**Per-app volume was on this list and should not have been.** The entry claimed
it needed a virtual audio driver in `/Library/Audio/Plug-Ins/HAL` and admin
rights. It does not: a process tap with `muteBehavior = .mutedWhenTapped`, a
private aggregate device combining that tap with the real output, and an IOProc
that scales what it reads is the whole mechanism, and it needs only the
**audio-capture** grant — the same one the existing mute path already uses.
Vorssaint ships exactly this. It is now implemented in
`Audio/PerApp/` (the FineTune-derived engine). The lesson is the one this file keeps
re-learning: a "needs admin/entitlement" claim is worth re-checking against an
app that actually does the thing.

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
- ~350 `Defaults` keys in `Models/Models/Constants.swift:833+` — the de-facto feature-flag registry. Flip switches before deleting code.
- `ContentView.swift` observes **14** `ObservableObject`s and ~34
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
- **Adding a `SettingsTab` case does not put it in the sidebar.**
  `SettingsView.availableTabs` is a *hardcoded ordered array*, not `allCases`,
  and it is what draws the list. A tab with an enum case, a `detailView`, an
  icon and a tint but no entry there is invisible, with no build error and no
  other symptom — the pane renders perfectly in the harness sweep, so even that
  does not catch it. **Five had gone missing this way**: Vinyl, Menu Bar,
  To-Do and Daily Commit on the day they were written, and `claudeUsage`, which
  had never been reachable at all since the usage watcher shipped. There is now
  an `assert` in `availableTabs` naming any case that is missing.
- **Settings panes are one file each** under `Components/Settings/`.
  `Components/Settings/SettingsView.swift` is now the shell — the two tab enums,
  `SettingsHighlightCoordinator`, the search/highlight plumbing, `SettingsForm`
  and the container. It was 7,784 lines holding eighteen panes; it is 1,062.
  Add a new pane as its own file and register it in `SettingsTab`, and add it to
  `UISnapshotHarness.settingsPanes` so it is covered by the render sweep.
- `Managers/System/SystemStatsManager.swift` is the one good throttling pattern in the repo — reference-counted `acquire()`/`release()` so nothing samples unless a view is watching. Copy it. (This entry used to name `StatsManager.swift:514-548`; that file no longer exists and the line numbers were stale long before it went.)
- **A `Defaults` key referenced only inside `Components/Settings/` is a dead
  switch.** This repo produces them steadily — Phase 1 alone left several
  behind. The audit that finds them:
  ```bash
  # keys whose only references live in the settings panes
  grep -oE 'static let [a-zA-Z0-9_]+ = Key<' Anchor/Models/Models/Constants.swift |
    awk '{print $3}' | while read -r k; do
      refs=$(grep -rln "\.$k\b" Anchor --include='*.swift' | Models/Models/Constants.swift)
      # NB: excluding Models/Constants.swift hides keys used by the migration code
      # *inside* it. Ten of thirteen "orphans" found that way were false —
      # only the build caught it. Grep for `\.$k` without the exclusion too.
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
| **Release 2026-08-25, end of session, quiet machine** | **0.03%** | **0.00%** | **0.00%** | 0.48% | **21.6 MB** |
| **Release 2026-08-26, full sweep, all features present** | **0.08%** | **0.00%** | **0.00%** | 2.40% | 42 MB falling to 34 |
| Release 2026-08-28, seven features added, **all off**, 9 min uptime | 0.03% | 0.00% | 0.00% | 0.48% | 19.4 MB |
| Release 2026-08-28, the same seven **all on**, 9 min uptime | 0.03% | 0.00% | 0.00% | 0.48% | 82.5 MB (**unsettled**) |
| **Release 2026-08-28, all on, settled (21 min)** | **0.03%** | **0.00%** | **0.00%** | 0.48% | **18.5 MB** |

**The 2026-08-28 pair is the cleanest evidence yet that the RSS settle is real,
and it nearly produced a false regression.** Same build, same 6-minute settle,
same 180 s sample, 87 samples each: seven features off read 19.4 MB, the same
seven on read **82.5 MB**. That looks like 63 MB of new cost and is not — left
running to 21 minutes and re-sampled, the "on" arm reads **18.5 MB**, *below*
the "off" arm. CPU is identical across all three runs: 0.03% mean, 0.00 median,
0.00 p90. The features cost nothing on either axis. **Do not quote an RSS figure
from an app that has been up for under about fifteen minutes**, however flat the
samples look — 82.5 mean against an 83.6 max is as flat as the 18.5 reading is,
and it is still wrong.

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

**The last row is the honest idle figure, and it invalidates the "0.33% floor"
claim above it.** 87 samples with **median and p90 both 0.00** and RSS flat to
0.2 MB — a far cleaner signature than the 0.30/0.35 rows, whose medians were
0.47. Those were taken shortly after builds; this one had a quiet seven-minute
settle with nothing else running. Lifetime cputime agrees: 1.70 s over 13
minutes.

So the earlier attribution of a floor to `__proc_info` was over-stated. `ps`
observing the process does cost something, but it is not a 0.3% floor — with the
machine actually quiet this app is at **0.03%**, and p90 of 0.00 means it is
doing nothing at all in the overwhelming majority of samples.

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
and read the topic out of a PNG. See `Helpers/UISnapshotHarness.swift`.

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
  `settingsPanes`. All panes share one 720x2400 canvas; a pane that outgrows it
  is visibly cut off, which is the signal to raise it rather than a failure.
  (It was 720x1200 until Appearance outgrew it.)
- **A short sweep means it was killed, not that a pane failed.** The full run
  writes **62 PNGs — 31 light, 31 dark** — and takes ~90 s at the 2400 canvas.
  (It was 1800 until General outgrew it; the keep-awake triggers were the rows
  that pushed it over.)
  It renders every pane dark first, then every pane light, so a run cut off
  early looks exactly like "all the dark ones worked and the light ones are
  broken". Three runs here returned 37, 33 and 50 PNGs purely from where the
  kill landed. Count the PNGs and check for both appearances before reading
  anything into a missing pane.

## TESTING.md

Rewritten 2026-09-01. It had grown chronologically — "Added 2026-08-25", "Added
since the checklist was written", "Waves 12–16" — so finding whether a feature
was covered meant reading 770 lines of archaeology, and several entries were
flatly wrong (it still said the camera mirror had been removed, and that there
were 14 settings panes rather than 33).

It is now **375 lines, 19 sections, 83 checkpoints**, organised by *what you
need in order to run it* rather than by when it was written:

- What is **already proven** by the 30 harnesses, so it is not re-tested by hand.
- Which **permissions gate which sections** — Screen Recording blocks §11
  entirely, Full Disk Access blocks notification mirroring.
- **Six things only a human can check**, ordered by what would be worst if
  broken.
- Then feature areas, each stating what to do and what correct looks like.

**Keep it that shape.** The reason it silted up is that every session appended a
dated section rather than filing items where they belonged. New tests go in the
relevant section; if a section does not exist, add one — do not add another
date.

Cross-references from this file use section numbers (`§1.4`), not item numbers,
because renumbering is what broke them last time.

## Source layout

Reorganised 2026-09-01. The Xcode project uses **file-system-synchronized root
groups**, so the folder tree *is* the project structure — moving a file on disk
is all that is needed, and there is no `.pbxproj` surgery to do. There is
exactly one explicit `.swift` file reference left in the whole project file.

```
Anchor/
  AnchorApp.swift            app entry point, manager start-up
  ContentView.swift          the notch itself
  AnchorViewCoordinator.swift  notch state, tabs, sneak peeks
  Managers/                  all behaviour, grouped by feature
    Audio/                    7 files
    Battery/                  3 files
    ClaudeUsage/              5 files
    Clipboard/                3 files
    Dictation/                4 files
    Display/                  8 files
    Gemini/                   3 files
    HUD/                      6 files
    Input/                    6 files
    Launcher/                 8 files
    LockScreen/               9 files
    Media/                    8 files
    Productivity/            12 files
    System/                  13 files
    Tools/                   10 files
  Components/                all SwiftUI views
    Battery/                  2 files
    Calendar/                 2 files
    Clipboard/                3 files
    Downloads/                2 files
    Launcher/                 5 files
    Live activities/         13 files
    LockScreen/              10 files
    Music/                    6 files
    Notch/                   17 files
    OSD/                      4 files
    Onboarding/               7 files
    Settings/                41 files
    Tabs/                     2 files
    Timer/                    5 files
    UI/                       2 files
    Vinyl/                    2 files
  Animations/                 2 files
  Audio/                     50 files
  Enums/                      2 files
  Extensions/                12 files
  Helpers/                   22 files
  MediaControllers/           9 files
  Models/                    18 files
```

Three rules the layout follows, so it does not silt up again:

- **No directory holds one file.** Eleven did before this pass (`strings/`, `sizing/`, `services/`, `private/`, `observers/`, `Shortcuts/`, `Providers/`, and three one-file `components/` folders whose contents were all live activities). A single-file folder is a decision someone deferred.
- **One name per idea.** `helpers/` and `utils/` were the same thing under two names; `utils/` is gone.
- **PascalCase throughout.** It was half `managers/` and half `MediaControllers/`.

`Managers/` held **84 files at its top level** before this. It is the directory most likely to become a dumping ground again — put a new manager in the feature folder it belongs to, or add a folder if it genuinely starts a new area.
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
- **`Helpers/Logger`'s subsystem must match the diagnostic collector's
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

### The volume HUD bug was a settings interaction, not a signal

Diagnosed live, and it is the actual cause of "the volume HUD suppression is
still broken":

`resolvedControlFlags()` surrenders channels to a third-party DDC helper when
one is running. With `enableThirdPartyDDCIntegration` on, `thirdPartyDDCProvider`
= lunar, Lunar actually running, **and `enableExternalVolumeControlListener` on**,
it sets `volumeEnabled = false` alongside brightness and backlight. All three
flags then read false, which means:

- `interceptVolume` is false, so `MediaKeyInterceptor` **passes the volume key
  straight through** — macOS services it and draws its own HUD. No amount of
  suppressing OSDUIHelper can prevent that, because the key was never claimed.
- Lunar sends volume payloads for a *monitor's* DDC speakers, not for the Mac's
  system audio, so nothing replaced what Anchor stopped doing.

Turning `enableExternalVolumeControlListener` off restores it — verified:
OSDUIHelper went from `S` to **`T` within three seconds** of the restart.

The toggle is reachable (HUD › Enable third-party DDC app integration › Enable
external volume control listener) and its own caption says "Anchor's built-in
volume key interception is disabled while external volume listening is on", so
this is working as designed. It is recorded here because the *symptom* — the
native volume HUD appearing while brightness behaves — points at suppression,
which is the wrong subsystem entirely, and two separate investigations went
there first.

**Check the flags before touching SystemOSDManager:**

```bash
defaults read com.arronlingham.Anchor enableExternalVolumeControlListener
```

### Measured: no programmatic volume write spawns OSDUIHelper

The comment at `SystemOSDManager.swift:227` — and a diagnosis built on it —
claimed "the CoreAudio volume write wakes/respawns the helper to draw the native
OSD". **That is wrong.** Measured with Anchor quit and the helper killed first,
four times across two APIs:

| path | helper spawned |
|---|---|
| `AudioObjectSetPropertyData(kAudioDevicePropertyVolumeScalar)` | **no** |
| `osascript -e "set volume output volume N"` | **no** |

So the native volume HUD is drawn by the **key-handling path**, not by the volume
change. The consequence for design is large: suppression is the wrong lever
entirely. If Anchor intercepts the key, no helper is ever asked to draw; if it
does not, no amount of SIGSTOP/SIGKILL wins, because the system draws it as part
of servicing a key Anchor never claimed.

A synthesized `NX_SYSDEFINED` key could not be used to complete the experiment —
posting one needs Accessibility for the *posting* process, and the volume did not
move, so that arm is inconclusive rather than negative.

**Which is why F10/F11/F12 now have a fallback.** `handleFunctionKeyDown`
handled only F1/F2 (brightness). A keyboard that sends plain function keys rather
than media keys therefore had its volume keys pass straight through to macOS —
the "external keyboard shows the system HUD" report. `treatFunctionKeysAsVolume`
(off by default, sibling of `treatFunctionKeysAsBrightness`) claims F10 as mute
and F11/F12 as volume.

### Grants: Screen Recording IS granted — this file said otherwise

Read from the system TCC database, current bundle id, all `auth_value = 2`:
`kTCCServiceAccessibility`, `kTCCServiceListenEvent` (Input Monitoring),
`kTCCServiceSystemPolicyAllFiles` (Full Disk Access) **and
`kTCCServiceScreenCapture`**. The "Screen Recording is stranded on the old bundle
id" section below is **stale** — window thumbnails, Dock Preview and the wave-6
capture/OCR path are no longer blocked on a grant.

`com.arronlingham.Anchor.dev` has Accessibility but `SystemPolicyAllFiles = 0`,
which is consistent with the note that a Debug build cannot test Full Disk Access.

```bash
sqlite3 "/Library/Application Support/com.apple.TCC/TCC.db" \
  "select service, client, auth_value from access where client like '%Anchor%';"
```

### OSD suppression must be SIGSTOP, and volume is what proves it

`suspendOSDUIHelper()` was briefly changed to **SIGKILL** (in `4ced65d`, with a
commit note saying it was unverified). It broke volume suppression specifically,
and the mechanism is worth not re-deriving:

- OSDUIHelper is **spawned on demand**, not persistent. SIGKILL therefore leaves
  *no process at all* — `pgrep -x OSDUIHelper` returned nothing with Anchor up
  seven hours, so TESTING.md §1.4's `ps -o state=` → `T` could not pass.
- **Volume is the one channel that resurrects it.** Anchor swallows the volume
  key and then performs its own CoreAudio HAL write
  (`kAudioDevicePropertyVolumeScalar`), and *that write* is what makes launchd
  spawn a fresh helper — which draws before the watcher's 1 s no-helper poll.
  Brightness never showed it because it goes through
  CoreBrightness/DisplayServices/Lunar, which never wake the helper.
- Every suppression path is **scan-then-signal**, so with nothing alive it is a
  no-op. The race cannot be won by killing faster: the helper is created by the
  write that happens *after* the scan.

SIGSTOP makes it structurally impossible — the helper is always present and
never able to execute. `resumeOSDUIHelperProcess` had also become a
`launchctl kickstart`, which this file already records as always failing under
SIP; it is SIGCONT again.

**Suppression is now derived from the resolved control flags**
(`SystemHUDManager.applyOSDSuppression`). It used to be an unconditional
`disableSystemHUD()` in `startSystemObserver`, while the seven per-control
`Defaults.publisher` sinks only called `changesObserver?.update(...)` — so
turning every HUD off left Anchor drawing nothing with the native HUD still
suppressed, i.e. **no HUD at all**, which reads exactly like "the setting is
ignored".

### A view that reads `Defaults[...]` imperatively never redraws

Twenty-six settings controls wrote their value and kept rendering the old one.
Two shapes, one cause — an imperative read records no SwiftUI dependency:

```swift
Binding(get: { Defaults[.key] }, set: { Defaults[.key] = $0 })   // 12 controls
if Defaults[.key] { …sub-options… }                              // 14 sections
```

The write always landed; only the invalidation was missing. `@Default`
subscribes to the key and republishes, so every one of these now reads through a
declared property. **Four were named `xBinding` properties and eight were inline
at the call site** — a first pass that grepped only for named properties found
four of twelve. `tests/run_settingsbinding_tests.sh` found the rest.

Twenty-one other bindings in these panes were fine: they transform a value that
is itself `@Default`-backed. The rule the harness pins is therefore not "no
hand-rolled bindings" but "if a pane reads `Defaults[.key]`, that pane must
declare `@Default(.key)`".

### The settings search index had drifted by a third

`settingsSearchIndex` is hand-written. 317 rows across the panes carry a
`.settingsHighlight(id:)`; **217 were listed**, so 121 settings could not be
found by searching for their own name, and four entries named rows that had been
deleted — switching tab and then scrolling to nothing. Entries are now generated
from the panes' own highlight ids and pinned by
`tests/run_settingssearch_tests.sh`.

**That harness's dead-entry check was vacuous on the first attempt** — it matched
each entry against a corpus that included `SettingsView.swift`, which is the file
holding the entries, so every entry matched its own text. It passed while unable
to fail. Excluding the shell is what made it real, and it then found all four.
**This is the third time in this repo a guard has looked correct while being
inert**; the negative control is the only thing that catches it.

### Quitting restores the system OSD — verified

Anchor SIGSTOPs `OSDUIHelper` to suppress the native HUD, so a build that dies
without running its termination handler leaves the volume and brightness keys
showing nothing at all until reboot. TESTING.md §1.4 is the check, and it
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
- Build is clean: **0 errors, 19 warnings** in a clean Release build, from 94
  at the start of this pass (82 → 69 → 58 → 52 → 37 → 21 → 19). Swift 6 language-mode
  errors 5 → 1, deprecated `onChange(of:perform:)` 6 → 0, macOS 12 constant
  renames 10 → 0, redundant `await` 5 → 0, unused results 4 → 1.
- **Reading the warnings was worth it.** Two of them were live bugs: pinned
  clipboard items silently breaking on every restart, and the download
  listener toggle doing nothing until relaunch. Both had been sitting in the
  build output.
- **Sixteen main-actor isolation warnings are now `MainActor.assumeIsolated`.**
  Thirteen were `NotificationCenter.addObserver(..., queue: .main)` blocks and
  three were `NSAnimationContext.runAnimationGroup` completion handlers. Both
  are main-thread by guarantee — NotificationCenter honours the queue it is
  given, and AppKit drives animation completions on the main run loop — so
  `assumeIsolated` states what was already true instead of assuming it silently.
  **It traps rather than warns if that ever stops holding**, which is the point:
  a violated assumption becomes a crash at the site instead of a data race
  somewhere else.
  - **Only the thirteen NotificationCenter ones use `assumeIsolated`.** The
    three `NSAnimationContext` completions use `Task { @MainActor in }` instead.
    AppKit does invoke them on the main thread, but that is convention rather
    than a documented contract the way `queue:` is, and these fire every time
    the music control window, timer window or vertical HUD hides — a trap there
    would crash a common path. The deferred hop cannot crash.
  - Verified only that the app runs 45 s without trapping. The geometry
    observers fire on display changes, which could not be triggered here without
    altering the user's display settings, so **those paths are unexercised** —
    TESTING.md §13.5 covers them.

- The **five non-Sendable capture warnings are deliberately left**. They are
  Swift 6 annotation friction on callbacks that run *synchronously* —
  `AVAudioConverter.convert`'s input block, `Timer` blocks, CoreAudio
  callbacks. None is a real race, and changing isolation in the audio and
  dictation paths cannot be verified without a microphone and a person. The "2 warnings" recorded here
  previously was long stale. What is left is mostly deprecated
  `onChange(of:perform:)`, `Text` `+`, and main-actor isolation notes.
  **An incremental build reports far fewer — it only recompiles what
  changed — so only compare clean builds.**
- **All four `forming 'UnsafeRawPointer' to a variable of type 'T'` warnings
  are gone.** They were the ones worth caring about: generic CoreAudio
  helpers in `SystemMediaControllers` passing `&data` for an unconstrained
  `T`, plus the two CFString reads. They now go through
  `withUnsafe(Mutable)Bytes`, which says "raw bytes" explicitly instead of
  forming a pointer to a possible object reference.
  **An incremental build reports far fewer — it only recompiles what changed —
  so only compare clean builds.**

## Tests

Neither harness needs an app build or a unit-test target — the project has only
a UI-test target, and adding one would mean surgery on a `.pbxproj` that uses
file-system-synchronized groups. Both compile the *real* source files with
`swiftc`, so they cannot drift from the implementation.

```bash
./tests/run_parser_tests.sh       # 19  banner wordings
./tests/run_watcher_tests.sh      #  7  real FSEventStream over a temp dir
./tests/run_launcher_tests.sh     # 25  fuzzy matching and the calculator
./tests/run_color_tests.sh        # 24  the eight clipboard colour formats
./tests/run_gitcommit_tests.sh    # 16  the git contract the daily commit relies on
./tests/run_urlclean_tests.sh     # 19  tracking-parameter stripping
./tests/run_snippet_tests.sh      # 18  trigger matching and placeholders
./tests/run_uninstaller_tests.sh  # 16  which files belong to an app
./tests/run_snapzone_tests.sh     # 68  the 16 zone geometries
./tests/run_debounce_tests.sh     # 17  keyboard chatter filtering
./tests/run_focusfollow_tests.sh  # 18  when to raise the window under the pointer
./tests/run_audiodevice_tests.sh  # 27  output cycling and mic-pin loop guards
./tests/run_applifecycle_tests.sh # 33  when it is safe to quit someone else's app
./tests/run_alert_tests.sh        # 26  threshold hysteresis and latching
./tests/run_menubar_tests.sh      # 28  fixed-width readout formatting
./tests/run_dmg_tests.sh          # 29  what a mounted volume is offering
./tests/run_cleanup_tests.sh      # 92  what the cleaner may and may not touch
./tests/run_version_tests.sh      # 60  version ordering and brew outdated parsing
./tests/run_ddc_tests.sh          # 74  the DDC/CI wire format
./tests/run_shortcuts_tests.sh    # 50  Apple Shortcuts argv safety
./tests/run_dsp_tests.sh          # 55  biquad coefficients, limiter, dB maths
./tests/run_autoeq_tests.sh       # 30  AutoEQ profile parsing
./tests/run_loudness_tests.sh     # 23  the leveler's gain curve and smoother
./tests/run_crossfade_tests.sh    # 45  equal-power device crossfade
./tests/run_todo_tests.sh         # 38  to-do ordering, including the nil-due-date case
./tests/run_frecency_tests.sh     # 25  launcher decay, ntfy delay window
./tests/run_sessionrecord_tests.sh # 29 Claude session JSON version tolerance
./tests/run_batteryhistory_tests.sh # 16 battery sample coalescing and pruning
./tests/run_netrate_tests.sh      # 12  network rate deltas and counter resets
./tests/run_settingsbinding_tests.sh #  4  settings controls that actually redraw
./tests/run_settingssearch_tests.sh #  5  every settings row is findable
python3 tests/test_privacy_configuration.py

# LIVE suites — these drive the running app and are NOT part of the unit run:
./tests/run_functional_live.sh    #  5  clipboard URL cleaning, end to end
./tests/run_runtime_stress.sh     #     hostile Defaults values (see Stress results)
./tests/run_gemini_tests.sh       # 44  Gemini request/response wire format
```

**981 assertions across 32 harnesses** (counted, not estimated — run the
loop in `Tests` above rather than trusting a number in a commit message; two
figures in this repo's history were quoted without being measured). Every one of the later harnesses was
proven non-vacuous by deliberately breaking the guard it covers and checking the
harness went red — the `ignoredNames` set in `DiskImageInstaller` is what
happens when that step is skipped: it survived review looking like a safety
check while being provably inert.

Three harnesses pin behaviour that was **measured rather than assumed**, and
each records where the value came from: `run_dmg_tests.sh` (volume properties
of a real mounted image), `run_audiodevice_tests.sh` (a real device UID) and
`run_gitcommit_tests.sh` (real repositories in real states).

`run_launcher_tests.sh` pins the behaviours this file records as having been
wrong: that `ss` ranks *System Settings* above *Chess* (the greedy-vs-DP bug),
that the acronym bonus makes initials win, that `100/3` is decimal rather than
integer `33`, that the integer rewrite does not split `7.5`, and that `%` is
refused. `FuzzyMatcher` and `CalculatorAction` are pure and import only
Foundation, so this harness needs no stub — unlike the watcher tests.

`run_gitcommit_tests.sh` is a shell harness rather than a Swift one, because
`GitCommitManager` is `@MainActor` and `Defaults`-backed and cannot be compiled
standalone the way `FuzzyMatcher` can. What it pins is the thing that would
actually break: the behaviour of the exact git invocations the manager makes,
against real repositories in real states. It records that
`rev-parse --git-dir` returns a *relative* `.git` (the manager joins it onto the
repo path), that `symbolic-ref` exits non-zero on a detached HEAD, that
`MERGE_HEAD` exists during a conflicted merge, that an empty commit changes no
files and carries no co-author trailer, and that a push to an unreachable remote
fails fast rather than hanging.

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

`tests/support/LoggerStub.swift` stands in for `Helpers/Logger.swift`, which drags
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
| `Managers/Dictation/SpeechTranscribing.swift` | Backend protocol — swap engines here |
| `Managers/Dictation/AppleSpeechTranscriber.swift` | macOS 26 `SpeechAnalyzer` impl |
| `Managers/Dictation/DictationManager.swift` | `AVAudioEngine` capture, state machine |
| `Managers/Dictation/TextInjector.swift` | Pasteboard + synthesized ⌘V |
| `Components/Live activities/DictationLiveActivity.swift` | Notch UI |

- **Deployment target is now macOS 26.0** (was 14.6) — `SpeechAnalyzer` requires it.
- Requires **Microphone** and **Accessibility** grants. Without Accessibility, `CGEvent.post` is silently dropped and nothing pastes.
- Injection synthesizes ⌘V rather than setting the AX value, because the AX route silently fails in Electron apps, terminals, and custom text views. Prior clipboard contents are restored 250 ms later.
- Nothing runs while idle — the audio engine only exists between key-down and key-up.

## Launcher (Phase 3)

**Option+Space** opens a Spotlight-style search panel.

| File | Role |
|---|---|
| `Managers/Launcher/FuzzyMatcher.swift` | DP best-alignment scoring + acronym bonus |
| `Managers/Launcher/AppIndex.swift` | Directory scan, ranking, launching |
| `Managers/Launcher/AppIconCache.swift` | Memory + on-disk icon cache |
| `Managers/Launcher/LaunchHistory.swift` | Frecency, 10-day half-life |
| `Components/Launcher/LauncherPanel.swift` | Non-activating `NSPanel` |
| `Components/Launcher/LauncherView.swift` | Search field, switches grid/list/calc |
| `Components/Launcher/LauncherGridView.swift` | Paged 7x4 Launchpad-style grid |
| `Managers/Launcher/CalculatorAction.swift` | Inline arithmetic |

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

## Fixed 2026-08-29 — two "looks wired, isn't" bugs

- **`syncNotchSpaceMembership()` had exactly one call site.** It was correct —
  reads `alwaysShowOnExternalDisplays`, pins the right windows — and it never
  ran, because the only trigger was a `Defaults.publisher(.hideNotchOption)`
  sink. Nothing called it at launch, when the external-display setting itself
  changed, or when a monitor was plugged in. The setting existed, had correct
  logic, and did nothing, which is a worse failure mode than a missing feature
  because there is no error to find. Now has three triggers: launch (right
  after every window for the launch is created), its own `Defaults.publisher`,
  and `screenConfigurationDidChange`.
- **`activateSelection()` called `activate()` before un-minimising.** A running
  app with every window minimised has nothing to bring forward, so `activate()`
  succeeded and did nothing visible; un-minimising afterward animated the
  window out of the Dock but did not raise it, which reads as "the switcher
  says it worked and nothing happened." The fix is ordering, not a new API:
  clear `AXMinimized`, `AXRaise` the window, *then* `activate()`. Windows are
  raised in reverse of what AX returns, since AX orders them front-to-back and
  raising in that order would leave whichever was raised last on top rather
  than the app's own frontmost window.

## Features added 2026-08-28

Seven asks from the app-parity list. All default **off**.

| Feature | Where | Replaces |
|---|---|---|
| ~~Keep-awake triggers~~ | **Removed** in `d4d0228` ("drop keep-awake"). `CaffeinateManager.swift` no longer exists; this row was stale. Sapphire still has it. | Amphetamine |
| To-do list | `Managers/Productivity/TodoManager.swift`, `Models/TodoItem.swift` | — |
| Daily git commit | `Managers/Productivity/GitCommitManager.swift` | — |
| Ring app switcher | `Managers/Input/AppSwitcherManager.swift`, `Components/Launcher/AppSwitcher*.swift` | Launchy |
| Menu bar shrinker | `Managers/System/MenuBarShrinkManager.swift` | Ice |
| Vinyl desktop widget | `Managers/Media/VinylWidgetWindowManager.swift`, `Components/Vinyl/` | VinylPod |
| Per-app volume | `Audio/PerApp/` (the FineTune-derived engine) | Fine Tune |

- **The menu bar shrinker uses no API for hiding other apps' items, because
  there is none.** The menu bar lays out right to left, so a status item that
  makes itself 10,000 points wide pushes everything to its left off the screen.
  That is what Ice, Bartender and Hidden Bar all do. Nothing is injected into
  another process and no permission is involved; the cost is that the user
  arranges their own bar by ⌘-dragging. `autosaveName` persists both their
  positions and the divider's — **changing that string moves everyone's divider
  back to the default position**, so do not edit it casually.
- **The vinyl record is CALayers, not SwiftUI.** A record turns for as long as
  music plays, and a SwiftUI rotation is a per-frame main-thread transaction —
  the shape removed from the waveform in the AudioTap fix. A `CABasicAnimation`
  is handed to the render server once. It is *removed* on pause rather than left
  running at zero speed, and the window is torn down while the display sleeps.
  - `CALayer.contents` set from an `NSImage` honours neither `contentsGravity`
    nor the layer's corner radius. The square album cover sat on a round record
    until it was converted to a `CGImage` and masked with a shape layer.
  - `layout()` runs inside a `CATransaction` with actions disabled, or the
    record visibly swells whenever the window moves between displays.
- **The app switcher's panel never takes key focus.** Taking it would deactivate
  whatever app the user is in, and on dismissal macOS would hand focus back to
  *that* app — fighting the activation the switcher exists to perform. Keys come
  from `NSEvent` monitors, which need Accessibility but leave focus alone.
- **⌘Tab is deliberately not taken over.** That needs an event tap that swallows
  it, and an app that swallows ⌘Tab and then hangs leaves the user with no way
  to switch apps at all.
- **The daily commit runs entirely off the main actor, and that is
  load-bearing.** An `await MainActor.run` before the git loop made the commit
  depend on the UI being free and deadlocked outright in a headless run. A
  housekeeping job must not miss its day because something upstream is busy. The
  spinner and the results list are fire-and-forget; the commit is not.
- **It commits empty by default and does not push.** `git add -A` running
  unattended at 21:07 will eventually sweep in a half-finished edit or a secret
  with nobody watching, and a local commit is undoable where a push is not.
  Pushing is a separate confirmed toggle.

### Testing a GUI build headlessly: what does and does not work

Verifying these cost several hours of blind alleys, all from one cause.

- **`open -n` is required; running the binary from a detached shell exits
  immediately.** CLAUDE.md already said so. It is still the first thing to get
  wrong.
- **In a headless second instance the main *dispatch queue* stops draining
  shortly after launch, while the main *thread* sits idle in the run loop.**
  Measured, not guessed: a `DispatchQueue.global` block and a `Task.detached`
  scheduled at the same moment both fired; a `DispatchQueue.main.asyncAfter` and
  a `Task { @MainActor }` never did, and `sample` showed the main thread parked
  in `_DPSNextEvent` the whole time.
  - Anything `await`ing the main actor hangs for ever. That is what stopped the
    daily commit, and the fix — doing the work off the main actor — was worth
    making permanently.
  - `NSWindow.orderFrontRegardless()` sets `isVisible = true` but the window
    never reaches the window server, so it is absent from
    `CGWindowListCopyWindowInfo`. **The vinyl widget's panel could not be
    verified this way and is the one thing here that needs a real look.**
- **`log show --predicate 'process == "Anchor"'` returns nothing for an ad-hoc
  signed Debug build**, and `open --stderr` only catches output from early
  launch. Writing a marker file is the only diagnostic that reliably works.
- **Status items do not appear in a `CGWindowList` query at all**, so the menu
  bar divider is verified by rendering its settings pane, which reports the
  manager's real state.
- **`pkill` leaves `OSDUIHelper` SIGSTOPped**, which kills the volume and
  brightness HUD system-wide. Run `kill -CONT $(pgrep -x OSDUIHelper)` after
  every force-kill during testing.
- **A properly launched Release instance behaves normally**, which is the
  control that makes all of the above an artefact rather than a regression:
  `tell application id "com.arronlingham.Anchor" to quit` returned it cleanly
  and `OSDUIHelper` went back to `S`, where the same AppleScript against the
  headless Debug instance timed out. When something looks broken in a headless
  Debug run, reproduce it in a Release instance before believing it.

## Features added 2026-08-31

Five waves, all defaulting **off**. Each has a test harness whose guards were
proven non-vacuous by deliberately breaking them first.

| Feature | Where | Harness |
|---|---|---|
| Output cycling, mic pin, mute-all-mics | `Managers/Audio/AudioDeviceToolsManager.swift` | `run_audiodevice_tests.sh` (27) |
| Quit on last window close, media auto-launch block | `Managers/Tools/AppLifecycleManager.swift` | `run_applifecycle_tests.sh` (33) |
| Battery / disk / sustained-CPU alerts | `Managers/System/SystemAlertManager.swift` | `run_alert_tests.sh` (26) |
| Menu bar CPU / RAM / network readout | `Managers/System/MenuBarReadoutManager.swift` | `run_menubar_tests.sh` (28) |
| Disk image installer | `Managers/Tools/DiskImageInstaller.swift` | `run_dmg_tests.sh` (29) |

### A DMG reports `isInternal == true`, and the unit tests agreed with the bug

`DiskImageContents.isDiskImage` first tested `isRemovable && !isInternal`, which
is what "disk image" sounds like it should mean. A real mounted DMG on this
machine reports:

| | removable | internal | ejectable | rootFS | DA protocol |
|---|---|---|---|---|---|
| mounted DMG | true | **true** | true | false | `Virtual Interface` |
| startup disk | false | true | false | true | `Apple Fabric` |

So the gate returned false for every disk image and **the feature could never
once have fired**. The unit tests passed throughout, because they encoded the
same assumption the code did — a pure test cannot catch a wrong belief about
the world, only a wrong transformation of it. Nothing but `hdiutil create` and
an actual mount found it.

Two things changed as a result, and both are the general lesson:

- The tests now carry the measured values with a `MEASURED:` comment naming
  where each came from, plus an explicit regression case
  (`internal=true is not disqualifying`) that fails if anyone reintroduces the
  term.
- The protocol string is a **refinement, not the gate**. `Virtual Interface` is
  undocumented, so it is used only to *reject* known-physical buses (USB, SATA,
  Thunderbolt…). If Apple renames it, the feature degrades to occasionally
  offering on a USB stick rather than silently going dead again. Choose the
  failure direction deliberately when depending on an undocumented value.

Note also that `diskutil` **displays** `Disk Image` where DiskArbitration
reports `Virtual Interface`; do not grep for the string diskutil shows you.

### A guard that no negative control can break is not a guard

`DiskImageContents` also had an `ignoredNames` set skipping `Applications`,
`.background`, `.DS_Store` and so on. Deleting it entirely changed **no test
result**, because every name in it already fails the `.app` suffix check. It
was dead code wearing the costume of a safety check, and it is gone. Run the
control before believing a guard does something:

```bash
# delete the guard, run the harness. If it still passes, the guard is inert.
```

The two filters that remain are both load-bearing, verified the same way — and
the symlink one genuinely matters, because most DMGs ship an `Applications`
alias next to the app and copying *that* into `/Applications` would be a
catastrophe.

### The features shipped unreachable, twice

Key debounce (wave 10) and focus-follows-mouse (wave 11) were built, tested,
installed and reported done while having **no settings UI at all**. Their
`Defaults` keys were referenced only by their own managers, so there was no way
for a user to switch either on. This is the mirror image of the dead-switch trap
already documented above — a key referenced *only* by its manager is just as
broken as one referenced only by its pane, and the existing audit did not look
for it.

The audit that finds both, and which now also checks the manager is actually
started:

```bash
# for each key: is it read outside Settings? exposed in Settings? manager started?
# read:0 -> nothing consumes it.  ui:0 -> the user cannot reach it.
```

Beware two known false positives on the "started" column: `SystemStatsManager`
is reference-counted (`acquire`/`release`) and `SnapZoneManager` self-starts
from its own `init` via `_ = SnapZoneManager.shared`. Neither has, or needs, a
`start()`.

Restructuring the panes to fix this also turned up two live UI defects that the
render sweep shows and no build catches: three unrelated features (scroll
inversion, side buttons, snippets) had accreted under a single **"Window
snapping"** header, and `SettingsSnippets` rendered *two* headed sections for
one feature — a toggle under "Text snippets" and a list under "Snippets" — with
the list offered even while the feature was off, so snippets could be written
that silently never fired.

### Two features shipped posting notifications nothing observed

`AudioDeviceToolsManager` and `SystemAlertManager` each ended their work by
posting a `Notification.Name` — `.anchorAudioDeviceChanged` and
`.anchorSystemAlert` — that **no part of the app listened for**. The detection
logic was right, the tests were green, `enableAudioDeviceHUD` defaulted to
*true*, and every alert the manager correctly raised went nowhere at all.

This is the publisher-side twin of the dead-switch trap, and the audit that
finds it is one line:

```bash
# for each posted Notification.Name: is there a matching addObserver / publisher(for:)?
```

Both were fixed by routing to surfaces that already render:

- **Mic mute** now calls `toggleSneakPeek(type: .mic, value: muted ? 0 : 1)`.
  `.mic` is one of the eight types `InlineHUD` actually handles, and it already
  draws a mic glyph that gains a slash at `value <= 0`. Adding a *new*
  `SneakContentType` case would have been worse than the bug — an unhandled
  type wins the branch and then draws nothing, which this file already records.
- **Alerts** got `SystemAlertLiveActivity`, following `EyeBreakLiveActivity`
  exactly: the manager publishes `visibleAlert`, the view draws it, and
  `ContentView` picks it in the closed-notch chain below the eye break (a
  twenty-second ask that must not queue) and above the usage countdown (which
  sits for hours).

**The output-device HUD was deliberately not built**, and the setting no longer
claims it. `InlineHUD.Type2Name` derives its label from the sneak-peek *type*,
ignoring the `title:` passed to `toggleSneakPeek` — `.bluetoothAudio` hardcodes
`BluetoothAudioManager.shared.lastConnectedDevice?.name ?? "Bluetooth"`, so a
wired output would announce itself as "Bluetooth". Switching output is audible,
which is the feedback that matters; a settings row promising a HUD that never
appears is the exact failure this section is about.

### The menu bar readout is fixed-width on purpose

`MenuBarReadoutFormatter` pads everything: `  5%` and `100%` are both four
characters, every rate is five. The menu bar is shared, so a readout that grows
by a character when CPU crosses 10% shoves every icon to its left, once a
second, for as long as the feature is on. The font is
`monospacedDigitSystemFont` for the same reason — a proportional `1` is
narrower than a `0`, so even fixed *character counts* jitter without it. The
harness asserts character counts and whole-line widths, not just values.

Verified live via the accessibility API rather than a screenshot, since status
items never appear in `CGWindowListCopyWindowInfo`:

```bash
# AXExtrasMenuBar on the app element lists the status items and their titles
```

which read `CPU  41%  ↓   4K ↑   8K` against real load.

### `kAXUIElementDestroyedNotification` on an app element is not "window closed"

`AppLifecycleManager` watches for a window closing so it can quit the app. The
obvious observer — `kAXUIElementDestroyedNotification` on the *application*
element — fires for **every** destroyed accessibility element in that process:
menu items, buttons, sheets, popovers. Closing one window can produce dozens of
callbacks, and the first version scheduled its own deferred AX window-count
query from each one.

It now coalesces to one check per app per burst (`pendingCheck`), which is
sufficient because the check reads the live window list rather than counting
events. The cost only exists while quit-on-close is enabled, which is off by
default.

Two other things in that manager are worth not re-deriving:

- The refcon handed to `AXObserverAddNotification` is a manually allocated
  `UnsafeMutablePointer<pid_t>` and **cannot be freed while the observer is
  alive** — AX dereferences it on every callback. They are held in `refcons`
  and released alongside their observer, after the run loop source is removed.
  Freeing before that races a callback already in flight.
- `for pid in observers.keys { removeObserver(for: pid) }` mutates the
  dictionary it is iterating, which is undefined behaviour. It snapshots with
  `Array(observers.keys)` now.

### Alerts latch, and that is the whole feature

`AlertThreshold` is not `value < threshold`. A battery sitting at 20% crosses
back and forth on every sample, and a bare comparison notifies each time.
Hysteresis (recover past a margin, not merely back across), latching (an active
alert does not re-fire) and a re-arm interval are all pinned, including an
end-to-end case asserting that ten samples oscillating 19–21% produce exactly
**one** alert. Sustained-CPU is gated separately so a build or a page load —
100% for a minute — never reaches the threshold rule at all.

### Microphone and output devices

- Store input devices by **UID, not `AudioDeviceID`**. IDs are assigned per boot
  and per connection, so a stored ID points at a different device, or nothing,
  after exactly the reconnect this feature exists to survive. Verified: the
  built-in mic's UID is the stable `BuiltInMicrophoneDevice`.
- The pin decision has a settle window because re-asserting in response to the
  change notification *our own assertion caused* is an infinite loop against the
  HAL, plus a burst cap for a device that refuses to stay selected.
- `muteAllInputs` mutes **every** input, not the default one — a call app can
  hold a non-default device, and a "mute all microphones" that leaves one live
  is worse than not offering it. It records prior mute state and restores it,
  so a device the user had muted themselves stays muted. It reports failure
  rather than claiming success when no device exposes a mute property.
- Round-trip verified on real hardware: `false → true → false`.

### The cleaner is an allowlist, and never empties the Trash

`CleanupManager` reclaims space from eight named locations. Two rules make it
safe enough to ship, and both are pinned by 92 assertions with five negative
controls:

- **It never scans.** Every location is an explicit `CleanupCategory` case. A
  heuristic that decides what "looks like" a cache is wrong once and has then
  deleted someone's work. `CleanupSafety.isForbidden` is a second layer:
  anything outside the home directory, and `Desktop`/`Documents`/`Downloads`/
  `Pictures`/`Movies`/`Music`/`Public`/`Applications` inside it, is refused
  whatever a category resolves to.
- **Everything goes to the Trash**, via `trashItem`, exactly as
  `AppUninstaller` does. **Emptying the Trash is deliberately not offered** —
  it is the one irreversible step, and a cleaner that also emptied the Trash
  would quietly destroy the undo the rest of the design depends on. `~/.Trash`
  is explicitly in `isForbidden` so no future category can reach it.

The defaults are the cheap choices only: logs, crash reports and simulator
caches. Application caches (some apps sign you out), Xcode derived data (your
next build of every project becomes a full build), device support, npm and
Homebrew all start **unticked**, and every row states its consequence in the
UI — "caches" sounds free and several of these are not. A negative control
asserts derived data is not default-selected, because that is the one most
likely to be flipped by someone tidying the code.

It removes directory *contents*, not the directories: deleting
`~/Library/Caches` itself makes macOS and several apps recreate it, and some
handle that badly.

Sizes are decimal (Finder's convention), so they read higher than `du -sh`,
which is binary — 191.9 MB here is 183 MiB there. Verified against `du` on four
real directories.

### External display brightness needs DDC — DisplayServices will not do it

Measured on this machine, not assumed:

| | `DisplayServicesGetBrightness` |
|---|---|
| built-in panel | status **0**, value readable |
| attached external (EK271 GD) | status **1000** |

So `DisplayServicesDynamic` covers the built-in screen and nothing else, and an
external display genuinely needs DDC/CI over `IOAVService` —
`IOAVServiceCreateWithService`, `ReadI2C` and `WriteI2C` are all present, with a
`DCPAVServiceProxy` node per display whose `Location` is `Embedded` or
`External`. That is the same path MonitorControl and Lunar use.

**Also measured: `DisplayServicesGetContrast` and `DisplayServicesSetContrast`
do not exist.** `dlsym` returns nil for both, so the contrast members of
`DisplayServicesDynamic` can never do anything on this OS.

**This machine's monitor does not answer DDC.** Twelve read attempts across
three timing profiles all returned the null message `6E 80 BE`. That is normal:
DDC/CI is frequently switched off in a monitor's own OSD menu and rarely
survives a hub or adapter. The consequence for the design is the important
part — **a display that does not answer a read is never written to**. Without a
working read there is no way to restore the previous brightness, so a blind
write would change someone's monitor with nothing able to put it back.

`DDCPacket` is pure and carries 74 assertions, including the real null reply
from this monitor verbatim. Two things it pins that are easy to get wrong:

- The value is **big-endian across two bytes**. Sending only the low byte works
  for every value under 256 and then silently fails on a monitor whose range
  goes to 1000 or 65535.
- A reply must be checked against the VCP code that was *asked for*. Monitors
  answer late, and a stale reply for a different code otherwise parses as a
  plausible brightness.

**A guard no negative control can break is not a guard — again.** The
`reply[1] != 0x80` null-message check turned out to be redundant: a real null
message carries its checksum in the opcode position, so the opcode guard
already rejects it, and removing the length check left every test green. It was
kept, but the comment now says what it actually does and a crafted case was
added so it is exercised. This is the second time this pattern appeared in one
session — run the control before believing a guard does anything.

### Camera mirror — "nothing is recorded" is structural, not a promise

The permission dialog tells the user nothing is recorded, so that has to be
true by construction. `CameraMirrorManager`'s session has **no output of any
kind attached** — no `AVCaptureMovieFileOutput`, no photo output, no
`AVCaptureVideoDataOutput`, no sample-buffer delegate. Its only consumer is an
`AVCaptureVideoPreviewLayer`, which draws frames and keeps none. There is
therefore no code path by which a frame could be written anywhere.

`test_camera_mirror_has_no_recording_path` pins that by scanning the source
with comments stripped — the class documents the APIs it deliberately does not
use, and matching those would make the test pass for the wrong reason. A
negative control adding an `AVCaptureMovieFileOutput` fails it.

The session is **built on appear and torn down on disappear**, not paused. The
green camera indicator is lit for exactly as long as the preview is visible and
never otherwise, which is the only honest behaviour for a camera feature. This
is the `AudioTap` pattern: nothing exists while the feature is off.

The preview is horizontally flipped by default, because a mirror in which
raising your right hand raises the image's left hand is not a mirror.

### Gemini — the key is not in the URL, and the model cannot act

Two decisions worth not re-deriving:

- **The API key travels in the `x-goog-api-key` header**, not as `?key=…`.
  Google's own examples use the query parameter, and copying that puts a
  billable credential into every proxy log, crash report and `nettop` line. A
  test asserts the endpoint has no query string at all.
- **The key lives in the Keychain** (`com.arronlingham.Anchor.gemini` /
  `apiKey`), never in `Defaults` — same reasoning as the ntfy topic, and the
  settings field is a `SecureField` because `ANCHOR_RENDER_UI` renders every
  pane to a PNG. The conversation history *is* in `Defaults`, which is fine: it
  is the user's own words, not a secret.

**Trimmed history must never begin with a `model` turn.** Gemini rejects that
with a 400, so a naive "keep the last N" fails on roughly half of all cut
points — intermittently, which is the worst way for it to fail.
`GeminiProtocol.trimmed` drops a leading model turn, and the test asserts the
property at *every* limit from 1 to the conversation length.

**Tool execution and screen awareness are deliberately not built**, and the
settings pane says so rather than quietly omitting them:

- *Screen awareness* needs Screen Recording, which is not granted to this
  bundle id (see the TCC note below).
- *Tool execution / computer use* turns model output into actions on the
  machine, which means anything the assistant reads can steer it. The parse
  path here cannot cause an action at all — replies are appended as text and
  rendered as text, never matched against a command table. If tool use is
  wanted, it needs **per-action confirmation rather than autonomy**, and that
  is a design decision, not a missing afternoon.

### Sapphire audit — 22 of 29, and what the remaining seven are blocked on

Done against Sapphire's own feature list, verified by grep rather than memory.
**Present: 19.** Notch shapes, live activities, widgets, theming, HUD overlays,
snap zones, file shelf, clipboard history, quick notes, per-app volume + EQ, now
playing, system stats, battery monitoring, lock screen widgets, Bluetooth
manager, notification mirroring, weather, calendar/reminders, eye break.

**Absent: 10**, and the reasons differ in kind — worth keeping straight:

| Missing | Why |
|---|---|
| ~~Camera mirror~~ | **Built 2026-09-01** — restored at the user's request; entitlement back to `YES`, privacy test reversed. |
| Caffeinate | **The user dropped it** in `d4d0228`. Trivial to restore if wanted. |
| Lid-angle automation | **No sensor on this hardware.** `ioreg -c AppleHIDLidAngle` returns nothing on `Mac14,2`. |
| Face ID engine | Needs a Developer ID identity and the privileged-helper story; also needs the camera entitlement the user turned off. |
| Bluetooth proximity unlock | Same blocker family as Face ID. |
| Nearby Share (NearDrop) | Buildable — reimplementing Google's Nearby protocol. Large, and unverifiable without an Android device. |
| Sports scores | Buildable; needs a live sports API and a key. |
| Finance / stocks | Buildable; needs a market data API. |
| ~~Gemini Live agent~~ | **Built 2026-09-01** — chat, memory and Keychain key. Tool use and screen awareness deliberately excluded; see below. |
| ~~Shortcuts launcher~~ | **Built** — see below. |

Note the distinction that matters when re-reading this: three of the ten are
**decisions already made** (camera, caffeinate, and the entitlement behind Face
ID), one is **hardware** (no lid sensor), and only the rest are unbuilt work.

### Apple Shortcuts run through argv, and must never be "sanitised"

`ShortcutsCatalog.isRunnable` is deliberately permissive: it accepts `;`,
`$(…)`, backticks, quotes and `rm -rf /` as shortcut names. That looks wrong and
is not. The name is handed to `Process.arguments` as **one argv element**, so
there is no shell to escape for and those characters are inert — while
stripping them would break a shortcut the user genuinely named `Backup; now`.

The real defence is the absence of a shell, and the test that protects it
asserts a name full of shell syntax stays a **single** argv element. A negative
control that split on whitespace produced
`["run", "Backup;", "rm", "-rf", "/", "#now"]`, which is exactly the shape that
would matter if a shell were ever reintroduced. Only an empty name, a
whitespace-only name, an embedded NUL (truncates the argument) and an embedded
newline (impossible in a real name) are rejected.

Verified against the 8 real shortcuts on this machine: all parse, all produce
correct argv, none listed-but-unrunnable.

### The per-app audio engine had no tests at all

~1,800 lines of pure DSP ported from FineTune, untested until 2026-09-01. It is
the worst thing in the repo to leave uncovered, because every failure is
**audible rather than visible**: a wrong biquad coefficient is distortion, a
missing limiter guard is clipping, a mis-parsed AutoEQ line is the wrong
equalisation applied silently. None of it crashes, and none of it looks wrong in
review.

Four harnesses now cover it, and the useful pattern is that they test
**properties, not values**:

- `run_dsp_tests.sh` evaluates the actual frequency response `H(e^jw)` from the
  returned coefficients and checks it against the requested gain. That is what
  catches a bad normalisation — reading the formula does not. It also asserts
  **pole stability across 105 frequency/gain/Q combinations**, because an
  unstable biquad does not sound wrong, it screams.
- `run_crossfade_tests.sh` asserts **equal power**: `primary² + secondary² == 1`
  at every point. A linear fade instead of `cos/sin` gives 0.5 at the midpoint
  instead of 0.707 — the "hole in the middle" you hear when a crossfade dips.
- `run_loudness_tests.sh` sweeps 561 input levels asserting the gain never
  exceeds `maxBoostDb`, never cuts past `maxCutDb`, and never amplifies digital
  silence into hiss.
- `run_autoeq_tests.sh` uses real oratory1990-format fixtures and pins the sign
  of every gain, because a dropped minus turns a -6 dB cut into a +6 dB boost.

### Finding: the loudness leveler has a hard knee at the noise floor

Not fixed, deliberately. `GainComputer`'s curve is monotonic everywhere except
**one 5.5 dB step at exactly -40 dB**, where the low-level boost cap is
released. It is a threshold with no hysteresis, so material sitting near -40 dB
crosses back and forth and the desired gain flaps between 0.5 dB and 6 dB — the
same shape as an alert threshold that pumps.

`GainSmoother` absorbs it: the 250 ms attack turns the step into a swell rather
than a click, and a test asserts the smoother takes more than five hops to
cross it. So it is a rough edge, not a defect.

It was left alone because **this is ported DSP and it cannot be verified by
listening from here**. Changing a gain curve blind is how audio gets quietly
worse. The tests pin the current shape — one discontinuity, at the threshold,
exactly the size of the cap being released — so anyone who soft-knees it later
can see what the old behaviour was.

### `Int(someDouble)` traps on NaN, and live streams report NaN

Same class as the stats bug below, found by auditing for the pattern after it.
`timeString(from:)` — in **both** `NotchHomeView` and `TimerManager` — did:

```swift
let totalMinutes = Int(seconds) / 60      // SIGTRAP if seconds is NaN or ±inf
```

This is not a theoretical input. A live stream reports a NaN duration as a
matter of course — the repo has a `LiveStreamProgressIndicator` precisely
because live content is handled — so playing one could take the app down while
simply drawing the elapsed time. Both now guard with
`seconds.isFinite, seconds >= 0` and render `--:--` otherwise.

The audit that found it, worth re-running after adding numeric formatting:

```bash
# floating-point values converted to Int/UInt without exactly:/clamping:
```

Fifteen sites matched; **thirteen were safe** because their inputs are bounded
(battery percentage comes from IOPS as an integer, EQ frequencies come from a
fixed table, timer durations are user-set). Only the two `timeString` sites took
an unbounded value. Checking where the value comes from is the whole job — the
grep is the easy half.

### A trapping conversion in the stats path, found by stress testing

`SystemStatsManager.readNetworkRates` accumulated its session totals as:

```swift
sessionInBytes &+= UInt64(dIn)   // &+= is wrapping; UInt64(someDouble) TRAPS
```

The wrapping `&+=` shows overflow was thought about. The **conversion** was not:
`UInt64(aDouble)` traps when the value does not fit, so a byte-counter delta
large enough to exceed `UInt64.max` as a `Double` took the entire app down with
SIGTRAP — not an exception, a hard crash.

Reachable only from a garbage counter read, which is unlikely. But the same
function already handles a counter going *backwards*, so the code's own premise
is that these counters cannot be trusted. It now uses
`UInt64(exactly:) ?? 0`, matching what the reset branch above it already does.

`run_netrate_tests.sh` pins it: with the old line restored the harness exits
**133** (SIGTRAP) instead of failing an assertion, which is worth knowing —
a crashing test looks like a broken harness rather than a caught bug.

### Stress results, 2026-09-01 — every feature on at once

**226 boolean flags enabled simultaneously**, which no real configuration would
be. The app survived it: one process, **zero crash reports**, 14 threads, 89 file
descriptors, still answering AppleScript, `OSDUIHelper` still suppressed. RSS
settled 170 -> 50 MB over thirteen minutes, which is the usual curve.

| Configuration | mean | median | p90 | RSS |
|---|---|---|---|---|
| everything **off**, settled | 0.38% | 0.47% | 0.96% | 15.6 MB |
| all **226 on**, settled | **2.59%** | **2.40%** | 3.36% | 49.7 MB |

The median of 2.40 matters more than the mean: that is steady-state cost, not
bursts. Nobody will run this configuration, but it bounds the total.

**Hostile input, all survived with zero crashes:** 128 extreme integers
(`INT_MIN`, -1, 0, `INT_MAX`) across 32 `Int` keys; 126 hostile strings across
21 `String` keys (empty, whitespace-only, emoji, 500 characters, `../../etc/passwd`,
`'; DROP TABLE --`); a 200-flip toggle storm; and type confusion (strings
written into `Int` keys).

**One A/B was thrown away and must not be quoted.** Turning the menu bar readout
*off* appeared to make CPU six times worse (14.70% mean, RSS spiking to 125 MB).
It was sampled 25 seconds after flipping three keys — manager churn, not steady
state. A measurement taken during reconfiguration measures the reconfiguration.

### The Bluetooth poll still polls

`BluetoothAudioManager.schedulePollingTimer` is the **largest non-idle
main-thread leaf** in a 5-second profile of the all-features-on build — 36 of
3,952 samples, against 3,845 parked in `mach_msg2_trap`. The main thread is 97%
idle; this is what the other 3% mostly is.

It calls `IOBluetoothDevice.pairedDevices()` every **15 s idle / 3 s while a
Bluetooth audio device is connected**. It *is* gated on `SystemActivityGate` so
it parks on display sleep, and it has 50% timer tolerance for coalescing — so it
is much better than the "ungated 3 s poll" this file records as fixed in Phase
0.5. But it is still a poll, and it is not gated on any feature flag: the
manager polls whenever it is alive, whether or not anything uses the result.

Not changed. `IOBluetoothDevice` has delegate callbacks that would remove the
poll entirely, but CLAUDE.md's own warning applies — IOBluetooth blocks on a
main-queue semaphore during `init`, which is what deadlocked the whole app once
before. Rewiring it needs a real Bluetooth device to test against.

### Screen Recording is stranded on the old bundle id

`kTCCServiceScreenCapture` has **no entry at all** for
`com.arronlingham.Anchor`, so `CGPreflightScreenCaptureAccess()` returns false
and the wave-6 capture / OCR / QR code has never captured a pixel. The reason is
not that anyone refused it. The system TCC database still holds:

```
com.Ebullioscopic.Atoll  | 2   (granted)
com.arronlingham.Anchor  | (absent)
```

The grant was made before the rename and is keyed to the dead identifier, which
is exactly the consequence the Install/signing section already warns about for
settings. Fix is one line of user action — add Anchor under System Settings ›
Privacy & Security › Screen Recording — but **nothing built on capture can be
verified until then**, which is why window thumbnails and Dock Preview are not
built rather than built-and-untested.

Check it without triggering a prompt:

```bash
# CGPreflightScreenCaptureAccess() — never prompts. CGRequest… does.
```

### Two shortcuts had handlers and no way to bind them

`pickColor` and `togglePinNotch` had working `onKeyDown` handlers in
`AnchorApp` and **no `KeyboardShortcuts.Recorder` row anywhere**, so neither
could ever be triggered. Same family as the sidebar and dead-switch traps: the
feature is complete, the wiring is complete, and the user has no route in.

The audit is cheap and worth running after adding any shortcut — note that the
fourteen `snap*` names are a **false positive**, because they are bound in a
loop (`for (name, zone) in snapBindings`) so `for: .snapLeft)` never appears
literally:

```bash
# for each Self("…") in ShortcutConstants: is there a Recorder row, and a handler?
```

Settings tabs have an equivalent check already asserted in code
(`Set(SettingsTab.allCases).subtracting(ordered).isEmpty`), and it currently
passes for all 23.

## Smaller features

| Feature | Where | Notes |
|---|---|---|
| Desktop number | `Managers/Display/SpaceIndicatorManager.swift` | Off by default |
| Battery history | `Managers/Battery/BatteryHistoryManager.swift` | Off by default |
| Colour picker | `Managers/Tools/ColorPickerManager.swift` | Cmd+Shift+P |
| Animation profiles | `Animations/drop.swift` | Bouncy / smooth / snappy / instant |
| Touch ID lock | `Managers/System/BiometricAuthManager.swift` | Off by default |

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
  `Models/PickedColor.swift`, which survived Phase 1 and already carries all
  eight output formats — a first pass here defined a second `PickedColor` and
  `ColorFormat` and collided at build time. Check `Models/` before adding a type.
- **Battery health is read-only and needs no privileges.** The
  `AppleSmartBattery` IORegistry node exposes `CycleCount`, `DesignCapacity`,
  `NominalChargeCapacity`, `Temperature` and `PermanentFailureStatus` to any
  process. `MacBatteryManager.currentHealth()` reads them and
  `BatteryHealthView` shows them. There is deliberately no charge *limit*
  control — that feature was dropped, and `utils/SMC.swift` (deleted) with it. Verified against this machine: 386 cycles,
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
- **Per-app audio is volume, mute and EQ, and the engine is ported from
  FineTune** (`Audio/PerApp/`, GPL-3.0, © 2026 Ronit Singh; see `NOTICE`).
  There is no per-process volume property in CoreAudio — `kAudioProcessProperty*`
  covers PID, bundle id, devices and is-running only — so gain means: tap with
  `muteBehavior = .mutedWhenTapped`, build a private aggregate device from the
  real output plus that tap, and re-render from an IOProc.
- **A hand-written version of this shipped first and did not work.** All four
  mistakes looked reasonable and are worth knowing before touching this again:
  - It tapped **one** process object. `AudioApp.processObjectIDs` is *plural* —
    Spotify and Chrome play through helper processes, so tapping the main
    process's single object taps something making no sound.
  - It started the IOProc immediately. An aggregate device is not ready when
    `AudioHardwareCreateAggregateDevice` returns; wait on `waitUntilReady`.
  - It omitted `kAudioAggregateDeviceTapAutoStartKey` and
    `kAudioAggregateDeviceClockDeviceKey`.
  - It applied gain instantly rather than ramping over 30 ms, and ignored drift
    compensation — which must be **off** for Bluetooth outputs, where tap and
    output share a clock and leaving it on makes the HAL insert or delete a
    sample every ~0.7 s. That is the rhythmic crackle on calls.
- **It was not a permissions problem, which is worth stating** because that was
  the first guess. `kTCCServiceAudioCapture` reads ALLOWED for
  `com.arronlingham.Anchor` in the TCC database. The engine was simply wrong.
- **Anchor declares its own `Logger`, which shadows `os.Logger` inside the
  module.** Every ported file that logs needs `os.Logger(...)` spelled out, or
  it fails with "argument passed to call that takes no arguments" — an error
  that says nothing about the actual cause.
- What is deliberately **not** ported from FineTune: the HUD, the menu bar
  shell, media keys, DDC, Bluetooth monitoring and the updater. Anchor has its
  own of each, and duplicating them would fight the existing code.

- **`LocalAuthentication` needs no entitlement and no privileged helper.** The
  match happens in the Secure Enclave and this process only ever sees a yes or
  no, which is why it needs neither an entitlement nor a helper. `BiometricGate` only *calls* its content closure
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

## Notification mirroring

Mirrors macOS notifications into the notch. Off by default; **needs Full Disk
Access**, which is why it is opt-in and the Settings row says what that costs.

There is no public API for another app's notifications — `UNUserNotificationCenter`
only ever reports your own. The only record is Apple's private store at
`~/Library/Group Containers/group.com.apple.usernoted/db2/db`.

- **Schema**, verified against the live database: `record(rec_id, app_id, uuid,
  data, request_date, delivered_date, presented, style, ...)` joined to
  `app(app_id, identifier)`. `data` is a `bplist00` whose `req` dictionary holds
  four-character keys — `titl`, `subt`, `body`. All 13 records on this machine
  parsed; rows without a title are the system's bookkeeping entries and are
  skipped. `delivered_date` is seconds since 2001.
- Opened **`SQLITE_OPEN_READONLY`**. This is the system's own notification store
  and nothing here has any business writing to it.
- **FSEvents does not work for this path, and that was measured, not assumed.**
  A notification arrived, the record landed, `db-wal`'s mtime moved — and the
  stream fired **zero** times. Group Containers appear not to be reported to an
  unprivileged watcher. A kqueue `DispatchSource` on `db-wal` sees the same
  commit as five `write`/`extend` events, so that is what it uses. The WAL,
  because SQLite is in WAL mode and commits land there before folding into `db`.
- **`db-wal`, not `db.wal`.** SQLite appends a *hyphenated* suffix, so
  `appendingPathExtension("wal")` yields a file that does not exist and opens as
  fd -1. That bug shipped in the first version and was caught only by tracing
  the real app.
- The watch re-arms on `.delete`/`.rename`/`.revoke`, because a checkpoint
  replaces the WAL and invalidates the descriptor.
- **Only counts and bundle ids are logged, never titles or bodies.** The point
  of mirroring someone's notifications is that they stay theirs.

### TCC grants bind to the code signature, not the bundle id

**An ad-hoc signed Debug build does not inherit Full Disk Access**, even though
`com.arronlingham.Anchor.dev` is listed as allowed in TCC. Traced directly:
`isReadableFile` returned **false** under `CODE_SIGN_IDENTITY=-` and **true** in
the same code signed with the Apple Development identity. Anything gated on FDA
— this feature, the Focus assertions read — can only be tested in a **signed**
build. Testing it in Debug will look like a broken feature.

## Claude usage watcher (Phase 4)

Detects when a Claude Code session hits its usage limit, counts down to the
reset in the notch, notifies the phone, and resumes the halted session.

| File | Role |
|---|---|
| `Managers/ClaudeUsage/ClaudeLimitParser.swift` | Banner text → `(resetDate, timeZone)`. Pure, no I/O |
| `Managers/ClaudeUsage/ClaudeTranscriptWatcher.swift` | `FSEventStream` on `~/.claude/projects` |
| `Managers/ClaudeUsage/ClaudeSessionRegistry.swift` | Live sessions from `~/.claude/sessions/<pid>.json` |
| `Managers/ClaudeUsage/ClaudeUsageManager.swift` | State machine, reset timer, resume |
| `Managers/ClaudeUsage/PhonePush.swift` | ntfy POST + Keychain topic |
| `Components/Live activities/ClaudeUsageLiveActivity.swift` | Notch countdown |
| `Components/Settings/ClaudeUsageSettings.swift` | Settings pane |

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
world-readable plist. `Models/Constants.swift` carries a comment saying so; keep it.

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

**Battery charge limiting and fan control were dropped at the user's request**
and their code is gone, along with `utils/SMC.swift` (deleted). Fan control was never
applicable anyway — `Mac14,2` is a fanless MacBook Air M2.

**The camera mirror was also dropped, and then restored on 2026-09-01 at the
user's request.** `CameraMirrorManager` and `NotchCameraMirrorView` are back,
`ENABLE_RESOURCE_ACCESS_CAMERA` is `YES` in **both** build configurations, and
the privacy test was **reversed rather than deleted** — see
`test_camera_access_is_declared_consistently`. What that test protects is not
the direction of the decision but that the two places declaring camera access
agree with each other, which is worth pinning either way. Fan control was never applicable anyway — `Mac14,2` is a
MacBook Air M2 and is fanless.

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
`enabledStatsGraphCount`, `statsAdditionalRowHeight`, the two `Models/Sizing.swift`
constants, 5 dead `@Default` keys in `ContentView`, and 6 `Defaults.publisher`
subscriptions in `DynamicIslandApp` that debounce-resized the notch for a tab
that no longer exists.

## CPU offenders — status

Fixed in Phase 0.5 (commit `30e872e`): the `SystemOSDManager` 150 ms `pgrep`
loop, the unconditional 20 Hz hover poll, the flat 0.5 s clipboard poll, the
ungated 3 s Bluetooth poll, and both `/usr/bin/log stream` children. New
`SystemActivityGate` parks pollers on display sleep / screen lock / Low Power.

Still outstanding:
- `MusicManager` publishes 27 properties from one object, including
  `elapsedTime`, and `@ObservedObject` invalidates on the object rather than the
  property — so a publish does re-render `ContentView`.
  **This note used to say that happened "on every tick". It does not, and
  acting on that would have been a bad trade.** Measured by reading the call
  path rather than assuming:
  - Spotify, Apple Music and the MediaRemote `NowPlayingController` are
    **event-driven**. `updateFromPlaybackState` runs on a controller publish,
    and `elapsedTime` is only assigned when `timeChanged`. No tick.
  - YouTube Music prefers a **WebSocket**; the 2 s `updateTimer` is the fallback
    when that is unavailable, and only while YT Music is the active source.
  - Progress in the notch is drawn by
    `TimelineView(.animation(paused: isProgressTimelinePaused))` in
    `NotchHomeView`, which **interpolates locally** — it does not need a publish
    per frame.

  So the worst case is a 2 s re-render in one fallback path of one source. The
  `LiveOutput` split is still the correct shape if this is ever touched, but it
  is a 7-file change to the most-used surface in the app buying a cost that
  mostly does not exist. **Do not start it expecting a measurable win.**
  Playback progress itself is already cheap — `TimelineView` interpolates it, and
  the spectrum visualiser is a plain `NSView` driving CALayer animations.
- `ContentView.swift` still re-renders the whole notch on any manager `@Published`
  change (12 `ObservableObject` + 40 `@Default` in one 2,161-line view).
- ~~`DoNotDisturbManager` 2 s assertions poll~~ — **done.** It now watches the
  Focus assertions **directory** with `FSEventStream` at 0.5 s latency and wakes
  only when the file changes. The directory rather than the file, because
  `Assertions.json` is rewritten atomically and a descriptor-based watch would
  hold the old inode after the first change. Verified with a probe: the callback
  fires on `replaceItemAt` (5 events for 3 replaces — the temp files count too,
  and the existing mtime guard absorbs the extras).
  **Do not expect this to show in a CPU measurement.** A gated, mtime-guarded
  2 s timer was already cheap; the run-to-run spread is wider than the effect.
  It was worth doing because "never add a polling loop where an event-driven API
  exists" is a project rule and this was the last unconditional poller, not
  because a number moved.
- `RealTimeWaveformScrubberView` drives a SwiftUI transaction per frame at
  30 Hz. **It only runs while the pointer is over the progress bar**, and this
  file previously said otherwise — "it starts on `onAppear`, not on hover" —
  while "correcting" an earlier note that had been right. `NotchHomeView` builds
  it inside `if showScrubber`, and `showScrubber` is
  `isHovering && enableRealTimeWaveform && enableWaveformScrubber`. A SwiftUI
  `if` does not construct the view when false, so `onAppear` cannot fire.
  **Check the call site before trusting a lifecycle claim about a view.**
- It is now also gated on `musicManager.isPlaying`: hovering a *paused* player
  animated a flat waveform thirty times a second, which is the same
  "a loop that no-ops is still a loop" mistake already made once with lyric
  sync. `startTimer` returns before `AudioTap.acquire()` and `stopTimer` guards
  on `timer != nil`, so the reference count stays balanced on every path.

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
