# Anchor

One native macOS app consolidating three utilities: a dynamic notch bar (from Atoll), dictation (replacing WisprFlow), and an app launcher (LaunchMe, built fresh).

Plan of record: `~/.claude/plans/i-want-to-build-functional-pinwheel.md`

## How to work with me

**Don't narrate.** Do the work, then report the outcome. No running commentary, no "now I'll do X", no explaining tool calls before making them. Skip preamble and postamble.

**Surface decisions, not process.** When you need input, state the choice in one or two lines with a clear recommendation. Don't present an exhaustive survey of options — pick one and say why in a sentence.

**Report at the end, briefly.** What changed, what broke, what's next. Numbers and file paths over prose. If something failed, say so plainly with the error.

**Ask before:** anything outward-facing (pushing, creating repos, publishing), installing tooling, or deleting code that isn't obviously dead. Local edits, builds, and measurements need no confirmation.

**Don't ask about:** which file to edit, whether to run a build, formatting choices, or anything the plan already settles.

## Project constraints

- **Low CPU is the top priority.** Measure before and after any perf change; record idle CPU% and RSS. Never add a polling loop where an event-driven API exists.
- **Native Swift only.** No Electron, no Node, no sidecar processes.
- **macOS 26+ / Apple Silicon only.** Target macOS 15.0, build arm64-only.
- **Personal use only** — never distributed. GPL-3.0 obligations don't apply.
- **Dictation uses Apple's on-device `SpeechAnalyzer`/`SpeechTranscriber`**, not Whisper. Keep it behind a protocol so a swap stays possible.

## Layout

| Path | What |
|---|---|
| `Atoll/` | The host app. Swift/SwiftUI, Xcode project (`DynamicIsland.xcodeproj`, product name `Atoll`). This is where Anchor gets built. |
| `WisprFlow/` | **Reference only.** Electron; being replaced. Read for behaviour, don't port. |

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
- `ContentView.swift` (2,161 lines) observes 12 `ObservableObject`s and 40 `@Default`
  keys. **`@ObservedObject` has no per-property granularity** — any `objectWillChange`
  from any of them re-renders the whole view, even for properties this view never
  reads. Split it before adding to it.
  - Don't try to move its methods into an `extension ContentView` in another file.
    The lifecycle handlers alone touch ~30 `private` members; making them all
    internal to win a line count trades away real encapsulation. The honest fix is
    to lift state into a model object, not to relocate functions.
- `SettingsView.swift` is 8,694 lines.
- `StatsManager.swift:514-548` is the one good throttling pattern in the repo. Copy it.
- **Keep high-frequency `@Published` values on their own nested observable.**
  `DictationManager.LiveOutput` is the reference: `state` changes ~4x per dictation
  and `ContentView` must watch it, but `inputLevel` changes 10-20x a second. On one
  object, the level meter re-rendered the entire notch for the whole dictation.
  Only the leaf view observes `LiveOutput`.
- Five SPM packages are pinned to `main`, not a version — builds can break with no local change.

## CPU measurements

**Every figure before the deadlock fix was measured on a hung app and is
meaningless.** Only these two are real:

| Build | mean | median | p90 | max | RSS mean |
|---|---|---|---|---|---|
| v2.2.0 installed (Release), original baseline | 1.93% | 1.90% | — | 3.00% | 27 MB |
| Debug, steady (`.dev` domain — waveform off) | 0.02% | 0.00% | — | 0.80% | 58 MB |
| Release `e88b20b`, before the AudioTap fix | 0.95% | 0.80% | 1.30% | 8.00% | 27 MB |
| **Release, after the AudioTap fix** | **0.08%** | **0.00%** | **0.10%** | 2.70% | **16 MB** |

The last two are a true A/B: same machine, same 120 s settle + 240 s sample,
120 samples each, pid verified stable throughout both runs. **12x less mean
CPU and 41% less RSS.**

The 0.02% Debug row is not comparable to either. It was measured against the
`.dev` defaults domain, where `enableRealTimeWaveform` is off; the production
domain has it on, which is what the 0.95% row is actually measuring.
| Release, pre-Phase-4, machine in use | 0.72% | 0.70% | 1.90% | 13 MB |
| **Release + usage watcher, idle machine** | **0.07%** | **0.00%** | 1.70% | 14 MB |

The last two are not a clean A/B — the first was taken while the machine was
being worked on. The controlled comparison is the watcher on/off pair in the
Phase 4 section, which shows no difference.

Sampling shows every thread parked in a wait state. RSS is higher than the
27 MB Release baseline mostly because this is a Debug build with the icon
cache warm; it settles around 24-30 MB before the launcher is first opened.

Let the app run for 5+ minutes before sampling — launch transients hit ~28%
and destroy the mean.

```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Anchor 180 "<label>"
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

**Measure with `measure-strict.sh`, not `measure.sh`** — it aborts if the pid
changes mid-run. Two measurements in this environment were silently garbage
because the app was replaced underneath the sampler.

## Verifying the UI

Screen-recording and accessibility grants are both denied here, so UI is
checked by rendering it:

```bash
ANCHOR_RENDER_UI=/tmp/uishots \
  <build>/Atoll.app/Contents/MacOS/Atoll
```

Writes a PNG of the launcher and each new settings pane in light and dark,
then exits. Inert unless the variable is set. See `helpers/UISnapshotHarness.swift`.

- Do **not** use `ImageRenderer` — it draws AppKit-backed controls as a yellow
  placeholder (`TextField`) and never materialises lazy containers, so the app
  grid comes out empty. The harness uses `NSHostingView` in an offscreen window.
- Appearance must be set on the *window*; `.environment(\.colorScheme)` does not
  reach AppKit controls inside a hosting view.
- Settings panes need `.formStyle(.grouped)` and a `SettingsHighlightCoordinator`
  in the environment, or they render as unstyled floating labels.

## Naming

The app is **Anchor** (`/Applications/Anchor.app`, bundle id
`com.arronlingham.Anchor`, process name `Anchor`). Internals are still named
after upstream — the Xcode project is `DynamicIsland.xcodeproj`, the source
directory is `DynamicIsland/`, and types are `DynamicIsland*`. That is
deliberate: renaming ~671 internal references touches the project file
extensively for no user-visible gain.

GPL headers still credit Atoll and boring.notch, and must keep doing so.
`NOTICE` records the fork and rename above upstream's original notice.

Changing the bundle id resets TCC grants (unavoidable — they key on identifier
plus signature) and would have reset ~300 settings; `PreferencesMigration`
carries the settings over from `com.Ebullioscopic.Atoll` on first launch.
Old settings are also exported to `~/Desktop/Atoll-settings-backup.plist`.

## Install / signing

The daily-driver build is a **signed Release** at `/Applications/Anchor.app`,
which is also the login item.

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
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
- Upstream's last build is at `~/Desktop/Atoll-upstream-v2.3.3-backup.app`.

## Build (Debug, for iteration)

```bash
xcodebuild -project DynamicIsland.xcodeproj -scheme DynamicIsland \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

- The project hardcodes upstream's team `9Y64TRM77N`; ad-hoc (`-`) signing is required until it's changed. A real `Apple Development: arronlingham@icloud.com (Q4FNFX8QSH)` identity exists and should be used once TCC grants matter.
- SwiftTerm needs the Metal toolchain (`xcodebuild -downloadComponent MetalToolchain`) — already installed. SwiftTerm is a Phase 1 deletion target, which removes this dependency.
- Build is clean: 0 errors, 2 warnings.

## Git

Repo is **`ArronLingham/Anchor`** — standalone (not a fork), so commits count on the contribution calendar. Local branch `anchor-main` → remote `main`. Upstream Atoll fork is remote `upstream`.

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
- `DoNotDisturbManager` 2 s assertions poll — already mtime-gated and given
  250 ms leeway, so low priority.
- `RealTimeWaveformScrubberView.swift:44` drives a 60 Hz SwiftUI transaction,
  but only while hovering.

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
