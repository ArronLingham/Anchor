# Desktop docks and workspace modes

## Setup

- **Settings → Docks → Add Dock** creates a left, right, center, or bottom starting layout. Every dock has its own apps, orientation, icon size, position, visibility, and display. Drag its handle anywhere, use position sliders for precision, or select a display. Add apps with the picker or drag `.app` bundles from Finder. Reorder pinned apps with the arrow buttons. A dot marks running apps.
- **Settings → Workspace Modes** starts with Travel and Desktop templates. Choose a mode, arrange windows, then use **Capture Current Apps & Layout**. Capture replaces that mode's window layout and adds the captured apps to its open list. Remove apps/windows you don't want, or add app windows manually and choose halves, centered, or custom proportions.
- Configure specific apps to open or quit, output volume, built-in display brightness, visible Anchor docks, and an optional named macOS Shortcut. Shortcut actions can extend a mode with Focus or other settings supported by Shortcuts.
- Apply a mode from settings or the **Anchor menu → Workspace Modes** submenu. Stop an in-progress application there or in settings; completed actions remain in place.
- Enable a rule for each desired mode, choose its display and power conditions, and enable automatic switching. All conditions in one rule must match. The first matching mode wins; adjust priority in the editor. Both the master switch and starter rules are off initially.

## Behavior

Anchor creates independent nonactivating floating panels. The system Dock continues to work separately. Panels join Spaces, support horizontal/vertical scrolling when the app list exceeds the usable display, and use stable display UUIDs. A disconnected dock display temporarily falls back to the primary display without losing its saved display identity.

Window geometry is normalized to each display's usable frame. Accessibility coordinates use the primary display's top-left origin, including displays above or to the left. Missing saved displays fall back to the primary display and frames are clamped into view. Exact window titles are reserved first, then unmatched slots use app window order. A window cannot fill more than one slot, including across launch retries.

Window capture and restoration require Accessibility permission. Capture skips full-screen windows. Restore reports full-screen windows, unsupported sizes, unavailable apps, and missing windows in settings. Existing documents must remain open or be restored by the app itself; Anchor does not recreate documents, browser tabs, or Spaces. Launching a selected app does not force it to create another window. Slow launches get approximately eight seconds of window retries.

Only explicitly listed apps receive ordinary quit requests. Finder and Anchor are excluded; apps required by the same mode take precedence over quit entries. Save dialogs can prevent termination, which is reported. No force termination is used.

Display, power, and wake events are coalesced for two seconds. Power conditions distinguish battery, external power (including a full battery), and active charging. A rule with no conditions is inert. Repeated events with the same context do not reapply a mode. Manual selection holds until the display/power context changes, or **Resume Automatic Switching** is chosen. Editing a rule schedules a fresh evaluation. When no rule matches, the current configuration remains.

Mode application is serialized. A named Shortcut runs last through `/usr/bin/shortcuts` with separate arguments and no shell interpolation. Its wait is cancellable and limited to two minutes. Enabled settings are applied on entry; applying another mode changes only that mode's specified settings. Configuration is stored locally in `Anchor.desktopWorkspace.v1` in Anchor preferences, separate from existing Anchor settings. Volume support depends on the output device; fixed-volume outputs can reject changes. Brightness targets the built-in display when available.

## Research and design choices

- [Apple: use the Dock](https://support.apple.com/en-gb/guide/mac-help/mh35859/26/mac/26) documents the system Dock's bottom/left/right placement. Independent Anchor panels provide multiple arbitrary positions without changing Dock preferences.
- [Apple: NSPanel](https://developer.apple.com/documentation/appkit/nspanel) supports auxiliary app windows. Nonactivating borderless panels avoid taking keyboard focus while showing pinned apps.
- [Apple: AXUIElementSetAttributeValue](https://developer.apple.com/documentation/applicationservices/1460434-axuielementsetattributevalue) supports window position and size changes through Accessibility. Its error outcomes inform partial-result reporting rather than assuming every app accepts a saved size.
- [Apple: display configuration notifications](https://developer.apple.com/documentation/appkit/nsapplication/didchangescreenparametersnotification) provide attachment/configuration events.
- [Apple: power-source notifications](https://developer.apple.com/documentation/iokit/1523868-iopsnotificationcreaterunloopsou?language=occ) provide battery/adapter state events without permanent polling.

## Verification

Run `bash tests/run_desktop_workspace_tests.sh`, `bash tests/run_settingssections_tests.sh`, and `bash tests/run_settingssearch_tests.sh`.

A Debug build supports isolated runtime/UI review with `ANCHOR_RENDER_UI=<output directory>` and `ANCHOR_WORKSPACE_REVIEW=1`. It uses a temporary preference suite, creates three real dock panels, verifies placement and persistence, renders both settings panes, and applies a dock-only mode. If Accessibility is already allowed and `ANCHOR_WORKSPACE_FIXTURE_APP` points to a disposable test app with windows named Fixture One and Fixture Two, it also checks real launch, window restoration, and normal quit behavior. It never prompts for permission or changes the user's apps/settings during review. Reported skips are not passes for live window restoration.

Verified on 2026-10-22:

- 34 focused model checks passed, including combined conditions, rule priority, manual holds, duplicate suppression, negative display origins, resolution changes, clamping, window matching, and serialization.
- Settings checks passed: 4 binding checks, 4 section-index checks, and 5 search-index checks. All 29 panes are represented in the sidebar.
- 14 native runtime checks passed in the full signed Debug app, with no skipped Accessibility checks. A disposable app opened, restored two real windows side by side, reappeared after being hidden, and quit normally. Dock checks covered three simultaneous nonactivating panels, bounds, independent visibility, display fallback, mode selection, and preference reload.
- Signed Debug and optimized Release builds succeeded. The Release app was installed at `/Applications/Anchor.app`, its deep signature verified, and its executable hash matched the build product (`b55e323475bdc81c6651ee31e3d5077a5472cc90e56df55cd95672854e61b5dc`). The installed app was launched and both new panes were verified through the native UI.
- Both settings panes were visually reviewed. The full settings window uses the same scrollable form layout as existing panes.
- The installed app's Add Dock and Center controls were exercised through the native UI. A temporary dock persisted across an app restart and was removed after verification.

Physical monitor unplug/replug, charger transitions, cross-Space interaction, and pointer dragging of a dock handle still require hands-on validation.
