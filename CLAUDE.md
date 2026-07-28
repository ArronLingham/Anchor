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

- `git-lfs` is required (`*.gif`/`*.mov`/`*.mp4`). Without it, plain `git status`/`checkout` error out. Workaround: `git -c filter.lfs.smudge= -c filter.lfs.process= -c filter.lfs.required=false <cmd>`.
- ~93 `static let shared` singletons; no central store.
- ~350 `Defaults` keys in `models/Constants.swift:833+` — the de-facto feature-flag registry. Flip switches before deleting code.
- `ContentView.swift` (2,979 lines) observes 17 `ObservableObject`s and 40 `@Default` keys — any `@Published` change re-renders the whole notch. Split it before adding to it.
- `SettingsView.swift` is 8,694 lines.
- `StatsManager.swift:514-548` is the one good throttling pattern in the repo. Copy it.
- Five SPM packages are pinned to `main`, not a version — builds can break with no local change.

## Baseline (Phase 0, 2026-07-27)

Installed Atoll **v2.2.0**, idle, 60 samples over 120 s:

```
CPU%  mean=1.93  median=1.90  min=1.20  max=3.00
RSS   mean=27 MB  max=34 MB
```

**This is the number to beat.** A well-behaved menu-bar app idles near 0.0–0.3%, so ~1.9% is roughly 6–10× where it should be. Re-run after every perf change:

```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Atoll 120 "<label>"
```

Confirmed live: `OSDUIHelper` is absent from the process list, meaning the suppression watcher is active and the 150 ms `pgrep` loop is running right now.

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

## Known CPU offenders

Documented with line numbers in the plan (§4). Highest-value target: `SystemOSDManager.swift:379` fork/execs `/usr/bin/pgrep` every 150 ms, and it *is* on by default via `enableSystemHUD` → `startSystemObserver()` → `disableSystemHUD()`.
