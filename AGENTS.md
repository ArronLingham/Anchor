# Anchor project guidance

## Project context

- Anchor is a native macOS app using Swift, SwiftUI, and AppKit. Work from this checkout; older Anchor paths in historical notes may be stale.
- `Anchor/` contains the host app; `Anchor.xcodeproj/` owns the build; `Packages/AnchorUtilities/` contains integrated utilities and package tests.
- Consult `README.md` for current requirements, build/signing/finalization instructions, permissions, and test commands. Verify changing facts against the checkout instead of copying historical results.

## Working defaults

- Carry implementation requests through relevant validation and report the concrete result. For research or planning requests, respect that scope.
- Preserve unrelated changes, credentials, saved preferences, user data, attribution, and licenses.
- Keep updates concise and explain user-visible behavior, evidence, and remaining limits in plain language.

## Performance and architecture

- CPU and memory use are primary constraints. Prefer event-driven work, shared services, bounded caches, and work scoped to visible consumers. Stop unused sampling and release resources when consumers disappear.
- Trace repeated features from UI through preference keys, runtime ownership, and services before consolidating them. Intentional duplicate controls must share a backend and remain synchronized.
- Inspect `UtilityWorkspace`, `FeatureRuntime`, and `UtilityOwnership` when changing native/utility integration. Preserve migration and ownership-handover semantics.
- Shared services must remain active while any consumer needs them; disabling one feature must not stop another consumer's service.
- Reuse existing UI design components and settings patterns. After adding settings, run `bash scripts/regen-settings-indexes.sh`, inspect the changes, and run the settings regression checks listed in the README.

## Validation and installed app

- Choose focused checks from `tests/run_*_tests.sh` and utility package tests according to the affected behavior. Build the host app for changes that affect app compilation or integration. Documentation-only changes need a diff and reference review.
- Follow the README's signed build and finalization process for an installable app. Compilation-only output does not establish working permissions or protected integrations.
- When delivering a change to the installed app, verify the intended bundle at `/Applications/Anchor.app`, its signature, matching built/installed executable hashes, and the active running copy. Preserve saved data and preferences during updates.
- Report compilation, automated checks, installed-app checks, and physical interaction checks accurately. Gestures, held global shortcuts, physical displays, and device transitions may need hands-on verification; identify that gap explicitly.
- For performance work, use `scripts/measure.sh Anchor <seconds> <label>` after at least five minutes of uptime. Compare equivalent configurations and workflows; distinguish RSS from physical footprint. Do not claim an improvement from an isolated or unsettled sample.

## Git workflow

- Inspect the current branch, worktree, and configured remotes before changing Git state. `origin` is the Anchor publication remote; the separate `atoll` remote is upstream reference material.
- Make focused commits at meaningful validated milestones and regularly push completed work to the configured Anchor remote, following repository protections and contribution rules.
- Inspect the staged diff before every commit. Include only intended changes; exclude secrets and generated artifacts unless intentionally tracked.
- Do not force-push, rewrite shared history, or bypass branch protection without explicit authorization.
- Verify successful pushes. In the final update, report meaningful commits, whether they reached GitHub, and any specific blocker or work that remains local.
