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
- `ContentView.swift` (2,979 lines) observes 17 `ObservableObject`s and 40 `@Default` keys — any `@Published` change re-renders the whole notch. Split it before adding to it.
- `SettingsView.swift` is 8,694 lines.
- `StatsManager.swift:514-548` is the one good throttling pattern in the repo. Copy it.
- Five SPM packages are pinned to `main`, not a version — builds can break with no local change.

## CPU measurements

**Every figure before the deadlock fix was measured on a hung app and is
meaningless.** Only these two are real:

| Build | mean | median | max | RSS mean |
|---|---|---|---|---|
| v2.2.0 installed (Release), original baseline | 1.93% | 1.90% | 3.00% | 27 MB |
| **Current (Debug), steady** | **0.02%** | **0.00%** | 0.80% | 58 MB |

Sampling shows every thread parked in a wait state. RSS is higher than the
27 MB Release baseline mostly because this is a Debug build with the icon
cache warm; it settles around 24-30 MB before the launcher is first opened.

Let the app run for 5+ minutes before sampling — launch transients hit ~28%
and destroy the mean.

```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Atoll 180 "<label>"
```

Every poller now parks on display sleep / screen lock / Low Power Mode via
`SystemActivityGate`. `AudioTap` only runs when `enableRealTimeWaveform` is on
(it defaults off).

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

## Install / signing

The daily-driver build is a **signed Release** at `/Applications/Atoll.app`,
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
- `ContentView.swift` re-renders the whole notch on any manager `@Published`
  change (17 `ObservableObject` + 40 `@Default` in one 2,979-line view).
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
