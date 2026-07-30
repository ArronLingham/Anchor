# Anchor — manual test checklist

Each item says **what** you're checking, **how** to do it, and **what correct looks like**. Work top-down; §1–§3 are where real bugs would be.

Current build: `/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/dd/Build/Products/Debug/Atoll.app`

**Before you start** — a fresh profile hides most tabs. `Notes` and `Terminal` default to off and clipboard opens as a panel, so you'll only see **Home + Timer** until you enable the rest in Settings.

---

## 0. Already known broken — don't report these

| Thing | Why |
|---|---|
| Settings → "Enable Camera Detection" does nothing | `CameraMonitor` was removed; nothing sets camera state. Mic half works. |
| Bluetooth HUD animations don't render | The 8 `.mov` files are unreachable LFS stubs |
| **⌘F1 / ⌘F2** backlight shortcuts do nothing | Declared but no handler registered — pre-existing |
| Dead Settings toggles | Stats, Color Picker, Mirror, Screen Assistant, Shelf, Extensions |

---

## 1. Smoke — 2 minutes, do this first

**1.1 — App is running clean.** Paste into Terminal:
```bash
pgrep -lx Anchor && pgrep -P $(pgrep -x Anchor) | wc -l && lsof -nP -iTCP:9020
```
✅ Prints a PID, then `0`, then nothing. The `0` means no child processes; empty port means the old extension server is gone.

**1.2 — No crashes.**
```bash
ls ~/Library/Logs/DiagnosticReports/ | grep -i anchor
```
✅ Nothing.

**1.3 — Settings opens.** Menu bar icon → Settings. Click every tab down the sidebar.
✅ All 14 render. ❌ A blank pane means I broke a tab when deleting features.

---

## 2. Launcher — brand new, never run by a human

**2.1 — It opens.** Press **⌥Space** (Option+Space).
✅ A search panel appears centred, slightly above middle, frosted background.
❌ Nothing happens → check Settings → Shortcuts → Launcher, in case ⌥Space is taken by Spotlight or Alfred.

**2.2 — You can type immediately.** With the panel open, just start typing.
✅ Characters appear in the field without clicking it first. *This is the classic failure mode for this kind of panel — if you have to click first, the focus handling is wrong.*

**2.3 — Search finds things.** Type `term`.
✅ **Terminal** is first. Matched letters are bold.

**2.4 — Arrow keys and Enter.** Type `saf`, press ↓ then ↑, press **Enter**.
✅ Selection moves and wraps at the ends; Enter launches Safari and the panel closes.

**2.5 — Escape returns you where you were.** Click into TextEdit, press ⌥Space, then **Esc**.
✅ Panel closes and **TextEdit is focused again** — you can type into it straight away without clicking.

**2.6 — Click-away dismisses.** Open the panel, click any other window.
✅ Panel closes on its own.

**2.7 — Empty query shows everything, most-used first.** Open the panel and don't type.
✅ The grid appears (see 2.12). After you've launched a few apps, the ones you use most drift to the front of the first page.

**2.8 — Frecency learns.** Launch **System Settings** through the launcher once. Reopen and type `ss`.
✅ System Settings should now rank above Screen Sharing. *Both are valid "ss" acronyms — a cold index ranks Screen Sharing first, and one launch is designed to flip it.*

**2.9 — Icons load.** Look over the grid, then search and look at the list.
✅ Every app shows its real icon in both views. The first open may show blank tiles briefly while icons render; the second open should be instant, since they're cached to disk.

**2.10 — Newly installed apps appear.** Install or copy any `.app` into `/Applications`, then reopen the panel.
✅ It's searchable without restarting Atoll.

**2.11 — It's fast.** Type and delete quickly in the search field.
✅ No lag or beachball. Search measures 0.4 ms across 109 apps, so any stutter is a UI bug, not the matcher.

### Grid view (the Launchpad replacement)

**2.12 — Grid appears when the field is empty.** Press ⌥Space and don't type.
✅ A grid of app icons, 7 across and 4 down, with page dots underneath.

**2.13 — Paging works.** Two-finger swipe left/right on the grid, or press → repeatedly past the last icon in a row.
✅ It snaps cleanly to the next page — no half-scrolled state. The dots track the current page.

**2.14 — Arrow keys move in two dimensions.** With the grid showing, press ↓.
✅ Selection moves down a whole row, not one icon. ← and → move one icon.

**2.15 — Grid stops at the ends.** Hold ↓ past the last row, then ↑ past the first.
✅ Selection stops rather than wrapping around. *(The list, when you're searching, deliberately does wrap — different behaviour on purpose.)*

**2.16 — Launch from the grid.** Click any icon, or select with arrows and press ↩.
✅ App launches, panel closes.

**2.17 — Typing switches to the list.** From the grid, type one letter.
✅ It becomes a filtered list. Delete the letter → back to the grid.

### Calculator

**2.18 — Basic maths.** Press ⌥Space and type `18*7.5`.
✅ A large `135` replaces the results, with "Press ↩ to copy" underneath.

**2.19 — Copying the answer.** With a result showing, press ↩.
✅ "Copied" flashes in the search bar. Paste somewhere — you get the number.

**2.20 — Decimals and precedence.** Try `100/3` → `33.333333`, and `(2+3)*4` → `20`.
✅ Both correct. *`100/3` returning a flat `33` would mean integer division crept back in.*

**2.21 — It doesn't hijack normal searches.** Type `Safari`, then `Final Cut Pro`, then `x-code`.
✅ All three still search apps normally — no calculator result. *This is the failure mode that would make the launcher unusable.*

**2.22 — Incomplete input.** Type `2+` and stop.
✅ No result shown until the expression is complete.

---

## 3. Dictation — new, transcription proven but nothing around it

**3.1 — Microphone permission.** Hold **⌘⇧D** for ~2 seconds.
✅ macOS asks for microphone access. Grant it. ❌ No prompt at all is a bug.

**3.2 — Accessibility permission.** System Settings → Privacy & Security → **Accessibility**.
✅ Anchor is listed and switched **on**. Without this the transcript is silently dropped — nothing will paste and there'll be no error.

**3.3 — The core loop.** Click into **TextEdit**, hold **⌘⇧D**, say *"testing one two three"*, release.
✅ The text appears at your cursor within about a second.

**3.4 — Repeat in a browser text field**, then **in Terminal**.
✅ Same result in all three. *These take different injection paths — a bug I fixed showed up as text pasting unformatted or not at all in the browser specifically, so this is worth doing properly.*

**3.5 — Your clipboard survives.** Copy the word `KEEPME`. Dictate something. Now press ⌘V manually.
✅ You get `KEEPME` back, not the transcript.

**3.6 — Clipboard race.** Dictate, then *immediately* (within a second) copy something else. Press ⌘V.
✅ Your new copy is intact. ❌ Getting the old clipboard back means restore is clobbering your data.

**3.7 — Notch shows progress.** Hold ⌘⇧D and watch the notch.
✅ Mic icon → a level meter that moves with your voice → live transcript text → "Transcribing…".

**3.8 — Meter responds.** Speak loudly, then softly.
✅ The bars change height. ❌ A flat meter means the audio format handling is wrong.

**3.9 — Edge cases.** Try each: tap ⌘⇧D without speaking; tap and release instantly several times; press it again while it's still transcribing; hold it in silence; connect AirPods mid-dictation.
✅ Always returns to idle. ❌ Getting stuck showing "Transcribing…" forever is the failure to watch for.

---

## 4. HUD / OSD — highest regression risk

I rewrote the OSD suppression from a 150 ms polling loop to an event-driven watcher. This is the most likely thing to be broken.

**4.1 — Atoll's HUD replaces the system one.** Press volume up/down, then brightness, then keyboard backlight.
✅ You see Atoll's notch HUD. ❌ Seeing macOS's grey square means suppression isn't working.

**4.2 — Confirm suppression is active.**
```bash
ps -o state= -p $(pgrep -x OSDUIHelper)
```
✅ Prints `T` (stopped). That's Atoll holding the system HUD frozen.

**4.3 — ⚠️ The important one: quit Anchor, then press volume keys.**
✅ macOS's own HUD comes back. ❌ **No HUD at all** means Atoll left `OSDUIHelper` frozen on exit — you'd have no volume feedback until you reboot. Test this deliberately.

**4.4 — Toggle it off and on.** Settings → Controls → turn off the system HUD replacement, press volume, turn it back on, press volume.
✅ Native HUD returns, then Atoll's takes over again.

**4.5 — Survives sleep.** Sleep the display (⌃⇧⏻), wake it, press volume.
✅ Atoll's HUD still appears.

**4.6 — Survives lock.** Lock (⌃⌘Q), unlock, press volume.
✅ Same.

**4.7 — Rapid input.** Mash volume up/down for ten seconds.
✅ No stuck HUD, no fan spin-up.

---

## 5. Notch core

**5.1** Hover the notch → opens. Move away → closes.
**5.2** Press **⌘⇧I** → toggles open/closed.
**5.3** Scroll/swipe on the closed notch → gestures respond.
**5.4** Settings → turn on Minimalistic UI → notch becomes the compact player, tabs hide.
**5.5** Plug in an external monitor → notch appears on the screen chosen in Settings. Switch screens there. Unplug while the notch is open. ✅ No crash, notch relocates.
**5.6** Open any app full-screen. ✅ The notch still draws over it. *This uses private macOS APIs and is the most fragile part of the app.*
**5.7** Open Home, Timer, Notes, Terminal in turn. ✅ Each sizes correctly. *Terminal is the one to watch — a sizing bug was fixed next to it in Phase 1.*

---

## 6. Media

**6.1** Play something in **Apple Music** → title, artist, artwork, elapsed time all show.
**6.2** Repeat for **Spotify**, **YouTube Music**, **Amazon Music**, and a **browser video**.
**6.3** Play/pause/next/previous from the notch.
**6.4** Drag the progress scrubber and release. ✅ Playback jumps to that point.
**6.5** Shuffle and repeat buttons toggle.
**6.6** Waveform visualiser animates while playing, stops when paused.
**6.7** Press the media keys (F7/F8/F9). ✅ Atoll handles them.
**6.8** Stop all playback. ✅ Idle animation appears.

---

## 7. Live activities

Start each of these and confirm it appears in the closed notch:

**7.1** Timer running · **7.2** Reminder fires · **7.3** Screen recording · **7.4** Download in Safari, then Chrome · **7.5** Focus mode on · **7.6** Mac locked · **7.7** Mic in use by another app · **7.8** Caps Lock on · **7.9** Power plugged/unplugged · **7.10** AirPods connect/disconnect

**7.11 — Priority.** Start a timer while music is playing.
✅ One takes over cleanly and the other returns afterwards — no flicker or overlap.

---

## 8. Everything else

**8.1** **Calendar** — events show on Home; click through to Calendar.app.
**8.2** **Clipboard panel** — press **⌘⇧C**, pick an item, confirm it pastes.
**8.2a** **Clipboard tab** — set `clipboardDisplayMode` to *separate tab* in Settings, open the notch, pick the Clipboard tab.
✅ You get the clipboard list — header, copy history, trash button. *This used to render the Notes view; it now renders `NotchClipboardList`.*
**8.3** **Timer** — **⌘⇧T** starts the demo timer; presets and pause/reset work.
**8.4** **Notes** (enable first) — create, edit, delete; check Apple Notes sync.
**8.5** **Terminal** (enable first) — **⌃`** toggles it; run `ls`; resize it.
**8.6** **Battery** — percentage and charging state correct.
**8.7** **Bluetooth** — device name and battery percentage on connect.
**8.8** **Lock screen widgets** — lock the Mac; media, weather, focus, reminder, timer widgets appear.
**8.9** **Sneak peek** — **⌘⇧H**.
**8.10** **Settings search** — search "shelf" or "stats". ✅ No results (those features are gone).
**8.11** **Rebind a shortcut** in Settings and confirm the new key works.

---

## 9. Performance

**9.1 — Idle CPU.** Leave the app alone **5+ minutes**, then:
```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure.sh Anchor 180 "manual-check"
```
✅ Mean **0.00–0.05%**, RSS around **40 MB**. *Don't measure right after launch — startup spikes to ~28% and ruins the average.*

**9.2 — During playback.** Repeat while music plays. ✅ Should stay low; the waveform is the expensive path.

**9.3 — Energy.** Activity Monitor → Energy tab, after an hour of normal use.

---

## 10. Stability

**10.1** Leave it running a full day, then check for crash logs (see 1.2).
**10.2** Sleep and wake the Mac several times.
**10.3** Restart; confirm Atoll launches at login.
**10.4** Leave music playing an hour; watch RSS in Activity Monitor for steady growth (a leak).

---

## Reporting back

Give me the item number, what you expected, and what happened. For dictation, say which app you were pasting into — native apps, Electron apps, and terminals each take a different path.
