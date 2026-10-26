# Launcher, switcher and Dashboard updates — October 19, 2026

## Wheel at screen edges

The switcher continues to shift inside the active display's visible frame. Its native pointer tracker is seeded from the actual clamped window origin, with the screen-to-view vertical coordinate conversion applied before the window appears. The native host uses a fixed size.

The old hover handler compared every callback to the first hover point. Once the mouse moved away from that point, a repeated callback could keep selecting the same wedge and undo keyboard navigation. It also discarded the first callback after every entry, which could make moving directly to an app near an edge fail to select it.

The new handler compares against the last accepted pointer position, ignores stationary callbacks and small jitter, and handles leaving/reentering the wheel explicitly. A native tracking area remains active while another app has focus; keyboard redraws do not recreate that area. The first click is accepted while Anchor is inactive. Clicking still selects the visible wedge before committing.

## Dashboard

- Task priority menus are available beside each open task and while adding a task: None, Low, Medium and High. They use the existing task manager and persistent task model, including the existing Reminders sync path.
- **Customize** chooses cards independently for Overview, Productivity, Media and System. All ten card types can appear on any tab.
- Choices persist between launches. An intentionally empty tab provides a Choose Dashboard cards button. Restore defaults applies only to the current tab.
- Wide layouts pair cards, narrow layouts stack them, and the file shelf keeps a full row. Hidden cards are not constructed.

## Launcher

Built-in maintenance tools are hidden from the empty-query grid/list, folders and categories. They remain indexed, searchable and launchable, and appear below regular apps among matching search results. Font Book, Disk Utility, Activity Monitor, Console and Apple's utility folders are included; Terminal, System Settings, Safari, Preview and third-party utilities remain regular apps. No installed application or saved folder assignment is deleted.

## Locking and feedback

- macOS has bottom-left Hot Corner action `13` (Lock Screen), with modifier `0`. The initial physical corner tests entered that corner and caused test-time locks; those tests were stopped. All subsequent native corner checks deliver simulated events directly to the wheel without moving the real cursor, posting system input, or changing Hot Corner preferences. Earlier unexplained locks were not proven to originate in Anchor.
- Anchor's two explicit lock entry points are Dashboard and the launcher command. Both now record the request source in the existing lifecycle log. The launcher only offers Lock Screen for an explicit lock query, preventing loose matches such as `screen` or `away` from selecting it.
- Distributed lock/unlock notifications are checked against the current macOS session state. Late events cannot reverse a newer known state. Missing session snapshots retain the notification fallback; a failed snapshot is not treated as a confirmed unlock.
- Sound preparation and MP3 decoding now run on a serial audio queue, preloaded during configuration instead of blocking the lock event on the main thread. The bundled lock sound contains about 228 ms of silent lead-in; playback skips about 213 ms while retaining 15 ms before the attack. Unlock retains the same short lead-in. Superseded or more-than-350-ms-old queued chimes are discarded.
- The small lock indicator starts before optional media/weather/timer windows. Their construction is deferred by 250 ms, and cancelled if the session unlocks or changes meanwhile.
- Pausing lock-screen canvas playback no longer suspends macOS wallpaper processes while the Mac is locked. Anchor pauses its own video player while allowing macOS to render its transition.

## Verification

- 416/416 new regression checks passed for pointer movement/reentry, dashboard persistence/empty tabs, utility classification, explicit lock intent and stale lock/unlock events.
- Real audio resources prepared successfully on a background queue without playing a chime. Measured silence offsets: lock 0.213254 seconds; unlock 0.014524 seconds.
- Existing checks passed: launcher 27/27, launcher paging 402/402, tasks 49/49, task storage/sync/layout 64/64, productivity workflows 106/106, shortcuts 50/50, and launcher experience.
- Signed Debug and Release builds passed; strict signatures and Info.plist validation passed.
- Native window/coordinate checks passed 24/24 across all four clamped corners on the connected screen. These directly deliver simulated AppKit events; no real pointer movement, system key posting or lock request is involved.
- Actual launcher index checks passed 11/11: the home/category exclusions, Font Book/Disk Utility discoverability, lower utility ranking, and explicit/ambiguous lock-command searches.
- Reviewed wide/narrow Dashboard, priority controls, card chooser, custom/empty layouts and launcher previews. Fixtures use isolated task/support directories.
- Installed and launched `/Applications/Anchor.app`; verified the running bundle and its responsiveness through Accessibility. Opened Dashboard and verified its new-task priority control, Customize action, and all ten card choices.
- Built and installed executable SHA-256 both equal `322d7c90c671e3fc2d3a23ee084faba56661ffb4f1e09eccd812907250a3592e`.
- Previous app preserved at `/private/tmp/anchor-corner-fix/Anchor.previous.app`. All 419 unrelated Swift files present at the start of this request remained byte-for-byte unchanged. No commit or push was made.
- Ambient before/after CPU and memory samples were captured locally. The post-install sample was taken during startup, so it does not establish steady-state memory usage or a controlled performance improvement.

A final physical macOS lock/unlock was deliberately not triggered after the Hot Corner warning. The actual transition's perceived smoothness and audible latency remain a hands-on validation limit; the changes above remove measured delay sources and stale-event paths rather than establishing a system-wide cause for all historical locks.
