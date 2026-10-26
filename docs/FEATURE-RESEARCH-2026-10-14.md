# Anchor: comparative feature research and implementation

Researched 14 October 2026. This review compares official product documentation with Anchor's current source. Competitor products were not installed or tested; advertised behavior is distinguished from behavior verified in Anchor. Existing uncommitted launcher, widget, and Lunar work was preserved.

## Selection criteria

The most valuable additions shorten common workflows, work inside Anchor's existing surfaces, and avoid a second background service. Features were selected when they add a missing capability with a clear native implementation. Existing features were extended instead of duplicated. Clipboard data, file processing, and focus history stay local. Quicklink web searches and system sharing start only after an explicit action.

## Products and useful patterns

| Product and primary source | Useful pattern | Anchor decision |
| --- | --- | --- |
| [NotchNook](https://getnotchnook.com/dynamic-island-for-mac) | A persistent file tray, clipboard input, AirDrop, compact calendar, notes and timers | Anchor already contains the main media/calendar/notes/timer surfaces. Extend the shelf with paste and sharing. |
| [Boring Notch](https://boringnotch.com/) | Music, calendar, camera mirror, battery, file shelf, replacement HUDs | These surfaces are present in Anchor's source. Improve the existing HUD geometry and lock-screen behavior. |
| [Atoll](https://github.com/Atoll-Labs/Atoll/blob/main/ReadMe.md) | Modular notch controls and system information | Anchor derives from this architecture. Reuse its managers in a central dashboard. |
| [OneNotch](https://www.tryonenotch.com/features) | Clipboard type/app filters, boards, privacy controls, text transformations, file actions | Add full-content search, app/type/collection filters, capture pause, ignored apps, private-pasteboard markers, retention, and native file actions. |
| [Dropover](https://dropoverapp.com/) | Multi-file staging, Quick Look, sharing, ZIP archives, image resizing and OCR | Extend Anchor's reference-based shelf with selection and these actions. Keep original files intact during processing. |
| [Dropzone](https://apps.apple.com/us/app/dropzone-4/id1485052491?mt=12) | Action-oriented file staging, AirDrop, image conversion | Add system Share menus and explicit image conversion destinations. |
| [Droppy](https://getdroppy.app/docs/shelf) | Shared trays and pinned files that survive cleanup | Use one shelf model in the notch and dashboard. Add pinning and clear-unpinned. |
| [Raycast clipboard](https://manual.raycast.com/clipboard-history) and [Quicklinks](https://manual.raycast.com/quicklinks) | Searchable copies, format-aware actions, reusable keyword links | Search full stored content; preserve original text while copying transformations. Add editable website/file/folder quicklinks and encoded search arguments. |
| [Alfred](https://www.alfredapp.com/help/features/web-search/) | Keyword web searches, custom URL templates, direct domain recognition | Add keyword searches and direct HTTP/HTTPS results to Anchor's launcher. Only whole keywords consume arguments. |
| [Maccy](https://github.com/p0deje/Maccy) | Capture pause and ignoring confidential/transient copy types | Apply privacy checks before reading or rewriting clipboard contents. Resume skips copies made while capture was paused. |
| [Pastebot](https://tapbots.com/pastebot/) | Durable collections, text filters and full-content previews | Add named pinned collections, eight text transformations and a selectable full-text preview. |
| [Session](https://stayinsession.com/) | An explicit work intention and reviewable focus history | Add an optional intention and locally saved completed sessions. |
| [Focus To-Do](https://www.focustodo.cn/) | Pomodoro cycles and historical work statistics | Add configurable focus/short-break/long-break cycles, pause/resume, skip break, daily totals and saved progress. |
| [Amphetamine](https://apps.apple.com/us/app/amphetamine/id937984704?mt=12) | A direct temporary keep-awake control | Add a one-hour native power assertion to the dashboard, with an explicit off button and automatic expiry. |

Alcove was also investigated, but its referenced official site/release links were unavailable during this run. No feature decision relies on unverified Alcove descriptions.

## Implemented workflows

### Dashboard

Open **Dashboard** from Anchor's menu, the notch's grid button, or by typing **dashboard** in the launcher. Assign a global shortcut under **Settings → Shortcuts → Navigation**.

The dashboard provides output volume/mute and device selection; brightness and display selection; media transport, shuffle, repeat and seeking; focus cycles and quick timers; task creation/completion/undo; the shared file shelf; clipboard access and capture pause; upcoming calendar events and Join buttons; app audio volume/mute; quicklinks; a color picker; Notes and Terminal access; system appearance; Mac locking; notch pinning; temporary keep-awake; and arranging the previously active app's window. Unsupported hardware controls show a useful fallback rather than a working-looking slider.

The dashboard subscribes to existing hardware notifications while visible. It does not take over the callbacks used by HUDs, and it adds no polling loop.

### Shelf

- Add files/folders with drag and drop, the plus button, or paste copied Finder files.
- Search; sort by date, name, or file kind; select with a click and add selections with Command-click.
- Preview selected files with Space or Quick Look. Share through the native Share menu, including AirDrop when available.
- Copy references, pin important files, and clear only unpinned items.
- Create a ZIP archive; combine images/PDFs into a PDF; convert images to PNG/JPEG; resize to a 1600-pixel maximum edge; recognize image text locally and copy it.
- Choose output destinations explicitly. Processing creates new files. Image outputs use distinct names and preserve aspect ratio. PDFs follow the displayed selection order.
- Keep unavailable volumes in the shelf instead of silently discarding their entries.

### Clipboard

- Search the complete stored text, file paths, source labels and collections, including content beyond the old 50-character preview.
- Combine filters such as `@text @app:Safari needle`, `@image`, `@file report`, `@link`, and `@board:Work`.
- Pause/resume capture from either clipboard surface or the dashboard. Paused copies are skipped when resuming.
- Ignore selected applications and confidential/transient pasteboard markers. App labels use the application active at capture time; macOS does not provide definitive clipboard authorship.
- Choose a history limit up to 500 entries and optional expiry for unpinned copies. Pins and named collections survive expiry.
- Copy text with trim, uppercase, lowercase, title case, join lines, remove empty lines, remove duplicate lines, or natural line sorting. Original entries remain available.
- Export/import local JSON backups with images. Imports merge, skip duplicates, bound payload sizes, and generate their own image filenames.

### Launcher

- Starter searches: `g`, `ddg`, `gh`, `yt`, followed by a query.
- Add, edit, enable/disable or remove custom quicklinks in **Settings → Launcher**.
- Use `{query}` in a search URL. Arguments are percent-encoded so spaces, Unicode, `&`, `+` and `#` cannot alter the template's parameters.
- Link directly to websites, local files or folders. Type a domain or HTTP/HTTPS URL to open it from launcher results.
- Dashboard, focus, clipboard library and add-to-shelf actions are searchable commands. These remain available while typing in either launcher layout.

### Focus

- Configurable focus duration, short/long breaks and rounds before a long break.
- Start with an intention, pause/resume, skip a break, or end the cycle.
- Explicit next-phase confirmation by default; automatic continuation is optional.
- Saved cycle state and local completion history with today's session/minute totals.
- System sleep pauses a running focus session. A stale deadline restored after relaunch completes at most one phase and does not manufacture unattended cycles.
- Manual timers use a deadline rather than decrementing once per callback, so delayed callbacks do not lengthen a countdown.

## Circular controls and settings repairs

The numeric label used fixed-width string formatting (`%3d`), adding invisible leading spaces to short numbers. The circular view also used a flexible host frame and recalculated the native window mainly when the size preference changed. Together these could produce misleading or stale alignment.

The circular control now uses bounded, shared layout metrics; a centered fixed canvas; unpadded percentage text; a centered icon/value group; normalized progress; and explicit hosting-view sizing. Window placement is reconciled when the control is shown or displays change. Brightness dragging carries the HUD's actual screen instead of resolving a potentially different screen later.

Controls settings now start with a compact style chooser. Circular settings group Preview, Size, Placement, Appearance/interaction, and selected system controls. Small/Medium/Large presets supplement a diameter slider and proportional ring thickness. External-display integrations and keyboard steps live under a disclosure group.

## Lock-screen logic repairs

- Cancelled hide tasks previously continued past `try? await Task.sleep`, allowing an old task to hide a newly presented player. Lifecycle tokens and cancellation checks now invalidate stale show/hide work.
- Unlock hides and clears the shielding-level player immediately.
- A view-local `isActive` flag was set false when media content disappeared, while also gating whether that same content could reappear. Remove that self-blocking lifecycle dependency.
- Hide the native window when the media session ends, restore it when media returns, and share expansion state between the native window and SwiftUI player.
- Reset immersive/expanded state for a new lock session; keep native and SwiftUI content sizes synchronized; update layout when inline lyrics, output controls or panel width change.
- Reset scrub interaction when tracks change. Limit compact progress redraws to 15 Hz while playback is active.
- Respect cancellation for artwork/video transition cleanup and deferred refreshes. Present artwork on the lock-screen display context.
- Cancel stale timer-widget hiding, and hide that companion widget immediately on unlock.

## Deliberate boundaries

This implements every selected gap above. Cloud clipboard sync, hosted uploads, browser extensions, third-party AI-agent approval bridges, notification interception, and a new iPhone app are separate products/integrations and were not selected. Anchor already has Reminders/iCloud task integration; this work does not claim a new physical-phone round trip. No competitor source code or assets were copied.

## Verification

- Signed Release and Debug builds passed. Strict code-signature and Info.plist validation passed.
- 106/106 workflow regressions passed, covering encoded queries, clipboard filters/privacy, legacy decoding, focus cycles, bounded circular geometry, and stale presentation tasks. This includes a 10,000-cycle rapid lock/unlock/lock stress case and media-end/resume visibility cases.
- 14/14 native file-action checks passed: image resizing and JPEG encoding, original-byte preservation, PDF page merging, local OCR, ZIP extraction with duplicate basenames, and the real Quick Look panel opening the chosen file.
- Existing regressions passed: launcher 27/27; tasks 49/49; persistence/sync/layout 64/64; settings bindings 4/4; settings search 5/5; settings sections 4/4; shortcuts 50/50; plus the launcher-experience suite. There are 323 counted checks in total, in addition to that last suite.
- Rendered 44 UI previews, including wide/narrow dashboards, dark/light controls, focus and compact lock-screen playback, and circular volume/brightness at four sizes and four values. Reviewed the main layouts and all 32 circular-control states visually, including minimum/maximum sizes and 0%, 6%, 65%, and 100%.
- Installed `/Applications/Anchor.app`, preserving the previous bundle at `/private/tmp/anchor-enhancements/Anchor.previous.app`. The running process uses that installed bundle, finishes launching, and its dashboard responds to Accessibility queries.
- Built and installed executable SHA-256: `52bc1b792fcaa1506d576f5e7a0b1c4cb66ba0aa700df4fe47a9c0c27fd6f5fd`.
- After at least five minutes of runtime, a 60-second sample with Dashboard visible recorded mean CPU 0.36%, median/p90 CPU 0.00%, and mean resident memory 48.4 MB (maximum 65.4 MB). The earlier baseline was an interactive ambient sample, so these measurements do not establish a controlled before/after improvement.
- All 15 unrelated files from the existing uncommitted launcher/widget/Lunar work remained byte-for-byte identical to their starting contents. No Git commit or push was made.

Actual lock-screen interaction, physical external displays, and AirDrop delivery still require hands-on device validation. Automated lifecycle checks and rendered previews do not establish those external outcomes.
