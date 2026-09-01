# Anchor

A dynamic notch bar for macOS — media controls, dictation, an app launcher and a
pile of system utilities, in one native Swift app.

Personal project. **Private on purpose** — see [Licensing](#licensing), which is
a one-way door.

## Requirements

macOS 26+, Apple Silicon. `MACOSX_DEPLOYMENT_TARGET = 26.0`, arm64 only.
Dictation needs macOS 26's `SpeechAnalyzer`, which is why the floor is that high.

## Build

```bash
xcodebuild -project Anchor.xcodeproj -scheme Anchor \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="Apple Development: arronlingham@icloud.com (Q4FNFX8QSH)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=KLWHJX56T3 \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

Install with `ditto <built>/Anchor.app /Applications/Anchor.app`, then
`open -a /Applications/Anchor.app`.

**Sparkle is deliberately disabled.** Every channel in `UpdateChannel` points at
*upstream Atoll's* appcast, so a live updater eventually replaces Anchor with
upstream — it already did once. Do not re-enable it.

## Test

```bash
for t in tests/run_*_tests.sh; do "$t"; done
python3 tests/test_privacy_configuration.py
```

22 harnesses, 710 assertions. They compile the **real** source files with
`swiftc` rather than a copy, so they cannot drift from the implementation.
No app build or test target is needed.

`scripts/audit_reachability.sh` checks that every feature flag is both acted on
and reachable from Settings — this repo has shipped features with no way to turn
them on more than once.

## Where things are

| Path | What |
|---|---|
| `Anchor/` | The app. See **Source layout** in `CLAUDE.md` for the full tree. |
| `Anchor/Managers/` | All behaviour, in 15 feature folders. |
| `Anchor/Components/` | All SwiftUI views. |
| `tests/` | Standalone harnesses. |
| `scripts/` | CPU sampler, reachability audit. |
| `CLAUDE.md` | The real documentation — architecture, gotchas, measurements. |
| `TESTING.md` | 120-item manual test checklist. |

Read `CLAUDE.md` before changing anything. It records a long list of mistakes
that look reasonable and are not, most of which have been made here at least
once.

## Licensing

Anchor derives from [boring.notch](https://github.com/TheBoredTeam/boring.notch)
via [Atoll](https://github.com/Ebullioscopic/Atoll), both **GPL-3.0**.

The repository is private, and that is load-bearing rather than incidental:
publishing it would be distribution and would trigger their copyleft. Settle the
licence question *before* the repo is ever made public, not after.

`NOTICE` records the fork chain. GPL headers in every source file credit Atoll
and boring.notch and must keep doing so.
