# Settings and fullscreen player fixes — October 26, 2026

## Behavior

Fullscreen desktop and lock-screen players no longer reserve an empty lyrics column. A lyrics column exists only when lyrics are enabled, visible and actually loaded. The artwork and player controls are centered without it. The separate Spotify wallpaper fallback also stacks its controls beneath centered artwork, including on displays with negative screen coordinates. Complete two-column arrangements are fitted to the screen before lower-priority content is dropped. Grid centering accounts for every row occupied by spanning elements. Adaptation does not overwrite saved player layouts, and fitting is cached per layout and viewport.

Anchor Settings is the single window for both original settings and utility editors. Tool settings replace its content instead of creating a second Controls window. General, Dynamic Island and Features links return to their corresponding Anchor settings/library pages. Shared-page tool sections retain their specific destinations. Selecting a sidebar row again resets its page instead of leaving a nested editor in place.

Anchor owns the one Dynamic Island renderer. The imported utility renderer and its island-only services are unavailable, with their saved preferences retained. Dynamic Island in General controls the original native island on every display; turning it off hides both the built-in-screen island and external-screen pill. There is no fallback to a second renderer.

The launch-at-login control is shared by both surfaces and uses SMAppService.mainApp through one service. Startup reconciliation is now actually called. The service runs changes off the main thread, reports approval/error states and refreshes on activation. Explicit white-thumb/blue-track geometry avoids platform switch drawing glitches and preserves toggle accessibility semantics.

Feedback previously copied a diagnostic summary locally in the active Anchor host. Unused upstream code still contained a foreign upload endpoint. The active flow now explicitly offers Anchor's GitHub issue page, local diagnostic copy, or Cancel; nothing is submitted automatically. The obsolete upload implementation is disabled.

Restore Anchor menu bar icon reveals the existing Anchor status icon. The icon is an access point for its menu and Quick Panel, not a feature engine. Hiding it does not stop features. Its label and help now explain this.

## Verification

- Fullscreen regression harness: centered artwork at 1366×768 and 1920×1080 without lyrics; left/right split and aligned title with lyrics; saved layout preserved.
- 13 selected package integration tests passed, including 20,882 native capsule/layout checks.
- Signed Release review build succeeded and was installed for live validation.
- In the installed app, toggling launch at login off changed the real macOS background-item record to disabled, then toggling on restored enabled/allowed. Original on state restored.
- Dynamic Island off produced zero visible Anchor overlay windows. Re-enabling restored one native overlay per connected display. Original on state restored.
- Features in the utility sidebar returned to the native feature library in the same AnchorSettingsWindow.
- Feedback dialog showed GitHub Issues, Copy Diagnostics and Cancel with explicit no-auto-submission text; no feedback was sent.
- Final optimized Release build succeeded. Deep strict signature verification passed. The installed executable matches the build artifact.
- The final installed switch was visually verified with a white thumb on the right and a blue enabled track.
- Final installed Dynamic Island and Features sidebar clicks both reached their canonical pages within AnchorSettingsWindow; only one sidebar toggle remains.
- An isolated native UI harness also verified clicking the already-selected General row invokes its navigation action.
- Actual lock/unlock fullscreen presentation was not exercised; fullscreen placement was checked through the production layout and AppKit frame helpers.

## Git history

The previous uncommitted work was checkpointed separately before these fixes. Fullscreen layout and settings unification were committed and pushed as separate changes. Final validation refinements are a further commit.

## Final installed build

Executable SHA-256: `bac36a45974e0416bb700e0ee3a474ea347f0618d973142ec1b4bf66fd87774a`. Source commit: `804ebf5` (following `00f63ba`, `bc386fd`, `36af62d`, and `b58bdec`). Only validation documentation follows this source commit.
