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

- ~93 `static let shared` singletons; no central store.
- ~350 `Defaults` keys in `models/Constants.swift:833+` — the de-facto feature-flag registry. Flip switches before deleting code.
- `ContentView.swift` (2,979 lines) observes 17 `ObservableObject`s and 40 `@Default` keys — any `@Published` change re-renders the whole notch. Split it before adding to it.
- `SettingsView.swift` is 8,694 lines.
- `StatsManager.swift:514-548` is the one good throttling pattern in the repo. Copy it.
- Five SPM packages are pinned to `main`, not a version — builds can break with no local change.

## CPU measurements

| Build | mean | median | max | RSS mean |
|---|---|---|---|---|
| v2.2.0 installed (Release), Phase 0 baseline | 1.93% | 1.90% | 3.00% | 27 MB |
| Phase 0.5 patched (Debug), steady | 0.40% | 0.20% | 8.40% | 58 MB |
| **Phase 1 stripped (Debug), steady** | **0.00%** | **0.00%** | **0.00%** | **27 MB** |

Idle CPU is now unmeasurable by `ps` (below 0.005%) across 90 samples, down
from 1.93%, and RSS is back to the Release baseline despite this being a
Debug build. Always let the app settle for a few minutes before sampling —
launch transients spike to ~28% and wreck the mean.

```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Atoll 180 "<label>"
```

## Build

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

Known upstream bug, not yet fixed: `ContentView` renders `NotchNotesView`
for the `.clipboard` case.

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

**Watch out:** `focusMonitoringMode` has two modes. `useDevTools` spawns a
persistent `log stream` on `duetexpertd`; onboarding picks it. `withoutDevTools`
(the code default) uses cheap mtime-gated polling instead. The dev build's
domain is `com.Ebullioscopic.Atoll.dev`, *not* `com.ebullioscopic.Atoll`.
