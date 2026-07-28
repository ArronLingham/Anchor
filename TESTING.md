# Anchor — manual test checklist

## Context

Three phases have shipped since the last build was known-good end-to-end:

- **Phase 0.5** rewrote the always-on pollers (OSD suppression, hover, clipboard, Bluetooth), added `SystemActivityGate`, and flipped two defaults off.
- **Phase 1** deleted seven subsystems — ~25k LOC, 108 files — and with them a set of enum cases, settings tabs, and a sizing helper that other code referenced.
- **Phase 2** added native dictation and raised the deployment target to macOS 26.

Idle CPU went 1.93% → ~0.00%, but **almost none of this has been exercised by a human**. Automated checks cover transcription and the build; everything involving the window server, TCC permissions, real audio hardware, or the notch UI is unverified. This enumerates every surviving feature and how to check it.

Build under test: `/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/dd/Build/Products/Debug/Atoll.app`

---

## 0. Known broken — skip these, they're already logged

| Thing | Why |
|---|---|
| Clipboard tab shows the **Notes** view | Upstream bug, `ContentView.swift:993` |
| Settings → **Enable Camera Detection** does nothing | `CameraMonitor` removed in Phase 1; `cameraActive` is never set. Mic half still works. |
| **Bluetooth HUD animations** don't render | The 8 `.mov` files are unreachable LFS stubs |
| **⌘F1 / ⌘F2 backlight shortcuts** do nothing | Defined in `ShortcutConstants.swift` but no handler is registered anywhere — pre-existing |
| Dead Settings toggles | Stats, Color Picker, Mirror, Screen Assistant, Shelf, Extensions — features are gone, switches remain |

## Defaults to know before testing

`enableNotes` = **false**, `enableTerminalFeature` = **false**, `clipboardDisplayMode` = **panel**. So a fresh profile shows only **Home + Timer** tabs. Enable the others in Settings before testing them.

---

## 1. Smoke (2 min — do this first)

1. Launch. Notch appears; menu bar icon present.
2. `pgrep -P $(pgrep -x Atoll)` → **empty** (no child processes).
3. `lsof -nP -iTCP:9020` → **empty** (extension RPC server is gone).
4. No crash logs in `~/Library/Logs/DiagnosticReports/`.
5. Open Settings; all 14 tabs render without a blank pane.

## 2. Notch core

6. Hover to open, move away to close.
7. Click to open when `openNotchOnHover` is off.
8. **⌘⇧I** toggles the notch open/closed.
9. Scroll/swipe gestures on the closed notch (`enableGestures`).
10. Haptics fire on open (`enableHaptics`, needs a trackpad).
11. **Minimalistic UI** on → notch collapses to the compact music player; tabs hide.
12. **Multi-display**: plug in an external monitor. Notch follows `selectedScreen`; try switching it in Settings. Unplug while the notch is open.
13. **Full-screen app** — notch should still draw above it (this is the private SkyLight/`CGSSpace` path, most likely to break on an OS update).
14. Notch geometry per tab: open Home, Timer, Notes, Terminal in turn and confirm each sizes correctly. *Terminal is the risky one* — it computes a screen-height fraction, and the sizing helper next to it had a real bug fixed in Phase 1.

## 3. Media & music

15. Play in **Apple Music** — title, artist, artwork, elapsed time.
16. Repeat for **Spotify**, **YouTube Music**, **Amazon Music**, and a **browser tab** (NowPlaying fallback).
17. Play/pause/next/previous from the notch.
18. Scrub the progress bar; drag and release.
19. Shuffle / repeat toggles (`showShuffleAndRepeat`).
20. Media output/device switcher (`showMediaOutputControl`).
21. **Waveform visualiser** animates during playback and stops when paused.
22. Album-art colour tinting; animated artwork if the track has it.
23. **Full-screen artwork** window.
24. **Media keys** (F7/F8/F9) — `MediaKeyInterceptor` should route them.
25. Idle animation appears when nothing is playing (`showNotHumanFace`).

## 4. Live activities (closed notch)

Each of these is a separate branch in `ContentView`; they're mutually exclusive and prioritised, so also check that a higher-priority one preempts a lower one.

26. **Music** — playing track shows in the closed notch.
27. **Timer** — start a timer, watch it count down.
28. **Reminder** — a Reminders alert fires.
29. **Screen recording** — start a QuickTime/system recording.
30. **Download** — download a file in Safari and in a Chromium browser.
31. **Do Not Disturb / Focus** — toggle a Focus mode.
32. **Lock screen** — lock the Mac.
33. **Privacy indicator** — start a mic-using app (camera half is dead, see §0).
34. **Caps Lock** — press Caps Lock.
35. **Battery** — plug/unplug power; low-battery and full-battery HUDs.
36. **Bluetooth** — connect/disconnect AirPods.
37. **Dictation** — see §6.
38. **Preemption**: start a timer while music plays; the higher-priority activity should win and restore cleanly.

## 5. HUD / OSD — highest regression risk

The OSD suppression watcher was rewritten from a 150 ms `pgrep` loop to an event-driven process source. This is the change most likely to have broken something.

39. **Volume keys** → Atoll's HUD, never macOS's.
40. **Brightness keys** → same.
41. **Keyboard backlight keys** → same.
42. Verify suppression is live: `ps -o state= -p $(pgrep -x OSDUIHelper)` prints **`T`** (SIGSTOP'd).
43. **Quit Atoll → the system OSD must come back.** If `OSDUIHelper` is left frozen, your volume keys show no HUD at all until reboot. This is the single worst possible failure; test it deliberately.
44. Toggle `enableSystemHUD` off and on in Settings — native OSD returns, then is suppressed again.
45. **Inline HUD** vs standard HUD styles.
46. Optional variants: `enableCustomOSD`, `enableVerticalHUD`, `enableCircularHUD` (all default off).
47. **Sleep the display, wake it** — suppression resumes.
48. **Lock, unlock** — same.
49. **Low Power Mode on/off** — `SystemActivityGate` should park and resume pollers.
50. Mash volume keys rapidly for ~10 s — no stuck HUD, no runaway CPU.

## 6. Dictation (Phase 2 — newest)

Transcription is proven by harness; **everything around it is unverified.**

51. First hold of **⌘⇧D** → **Microphone prompt** appears. No prompt at all = bug.
52. Confirm Atoll is listed and enabled under **Privacy & Security → Accessibility**. Without it the paste is silently dropped.
53. First run may pause while the speech model downloads.
54. Dictate into **TextEdit**, a **browser field**, and **Terminal** — three different injection paths.
55. **The bug I fixed** would appear as: text pasted wrong/unformatted in the browser, or nothing at all — a still-held ⇧ turning ⌘V into ⌘⇧V.
56. **Clipboard preservation**: copy something distinctive, dictate, then ⌘V manually — you should get your original back.
57. **Clipboard race**: dictate, then copy something else within ~250 ms. Your new copy must survive.
58. **Notch UI**: mic icon → level meter responding to your voice → live transcript → "Transcribing…".
59. Speak loud then quiet — the meter must track it, not sit flat.
60. Edge cases: tap without speaking; release during startup; re-trigger while transcribing; dictate silence; connect AirPods mid-dictation; dictate into a field that can't take text; revoke Accessibility then dictate (expect a visible error, not silence).

## 7. Notch tabs

61. **Home** — music + calendar.
62. **Timer** — presets, start/pause/reset; **⌘⇧T** starts the demo timer.
63. **Notes** (enable first) — create, edit, delete; Apple Notes sync.
64. **Clipboard** — expect the Notes view (§0); check history still records.
65. **Terminal** (enable first) — **⌃`** toggles it; run a command; resize. Note this is the SwiftTerm/Metal path.
66. Switch rapidly between all tabs — no crash, no stuck sizing.

## 8. Other features

67. **Calendar** — events show; click through to Calendar.app; multi-day; all-day events.
68. **Clipboard panel** — **⌘⇧C** opens it; pick an item; history limit respected.
69. **Downloads** — progress, completion, Safari + Chromium.
70. **Battery** — percentage, charging state, low/full HUDs.
71. **Bluetooth** — connect/disconnect, battery percentage text, name marquee.
72. **Lock screen widgets** — media, weather, focus, reminder, timer (all default on).
73. **Lunar / BetterDisplay** integration (only if you run those apps).
74. **Sneak peek** — **⌘⇧H**.

## 9. Settings

75. Open all 14 tabs; no blank panes, no empty sidebar groups.
76. **Search** — results must not reference Stats, Shelf, Color Picker, Screen Assistant, or Extensions.
77. Search-highlight jumps to and highlights the right row.
78. Rebind each of the 6 live shortcuts; confirm the new binding works.
79. Toggle each live feature flag off and on; confirm the UI responds.

## 10. Performance

80. Settle **5+ minutes**, then:
    ```bash
    /private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Atoll 180 "manual-check"
    ```
    Expect **~0.00–0.05% mean CPU, ~40 MB RSS**. Sampling before it settles gives a meaningless number — launch transients hit ~28%.
81. Re-measure during music playback (waveform is the expensive path).
82. Activity Monitor → **Energy Impact** over an hour of normal use.

## 11. Stability

83. Run a **full day**; check for `Atoll*` crash logs.
84. Sleep/wake the Mac several times.
85. Restart; confirm launch-at-login.
86. Leave music playing an hour — watch RSS for a leak.

---

## Verification

The suite passes when: §1 smoke is clean, §5 items 42–43 behave (OSD suppressed while running, restored on quit), §6 dictation completes a round trip in all three app types with the clipboard intact, and §10 idle CPU stays at or below **0.05% mean**.

Report failures as: step number, expected, actual. For dictation, name the target app — the injection path differs between native, Electron, and terminal apps.
