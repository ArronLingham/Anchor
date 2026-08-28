# Anchor — manual test plan

## Before you start

Camera mirror, battery charge limiting and fan control were dropped and their
code removed. The Spotify cookie has been rotated. The old commit trailers are
left alone.

Seven new features landed on 2026-08-28 — §13. All default off. One of them,
per-app volume, puts Anchor in the real-time path of your audio, so read item
101 before turning it on.

Worth doing first, because these are the checks I could not run myself:

| | What | Why it needs you |
|---|---|---|
| 1 | **Per-app volume** (item 101) | Anchor now re-renders another app's audio in real time. It has never been *listened to*. Dropouts, crackle or a lag behind video are the failure modes, and this is the only feature that can make your Mac sound wrong. |
| 2 | **Vinyl widget appears at all** (item 102) | The window is created with the right geometry and reports itself visible, but never reached the window server in a headless test. I could not tell whether that is the code or the test rig. |
| 3 | **Menu bar shrinker vs the notch** (item 104) | On a notched display the hidden icons are pushed under the notch rather than off the edge. I have no way to see what that looks like. |
| 4 | **Multi-display control windows** (item 93) | Needs a second monitor. Still never run on two screens, and `showOnAllDisplays` is on for your profile. |
| 5 | **`assumeIsolated` paths** (item 99) | These crash rather than warn if an assumption is wrong. Triggering them means changing display settings, which I would not do to your machine. |

---

Each item says **what** you're checking, **how** to do it, and **what correct looks like**. Work top-down; §1–§3 are where real bugs would be.

Build under test: the installed signed Release at `/Applications/Anchor.app`.

**Before you start** — a fresh profile hides most tabs. `Notes` and `Terminal` default to off and clipboard opens as a panel, so you'll only see **Home + Timer** until you enable the rest in Settings.

---

## 0. Already known broken — don't report these

| Thing | Why |
|---|---|
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
✅ It's searchable without restarting Anchor.

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

**4.1 — Anchor's HUD replaces the system one.** Press volume up/down, then brightness, then keyboard backlight.
✅ You see Anchor's notch HUD. ❌ Seeing macOS's grey square means suppression isn't working.

**4.2 — Confirm suppression is active.**
```bash
ps -o state= -p $(pgrep -x OSDUIHelper)
```
✅ Prints `T` (stopped). That's Anchor holding the system HUD frozen.

**4.3 — ⚠️ The important one: quit Anchor, then press volume keys.**
✅ macOS's own HUD comes back. ❌ **No HUD at all** means Anchor left `OSDUIHelper` frozen on exit — you'd have no volume feedback until you reboot. Test this deliberately.

**4.4 — Toggle it off and on.** Settings → Controls → turn off the system HUD replacement, press volume, turn it back on, press volume.
✅ Native HUD returns, then Anchor's takes over again.

**4.5 — Survives sleep.** Sleep the display (⌃⇧⏻), wake it, press volume.
✅ Anchor's HUD still appears.

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

**6.6a — The waveform is the one thing I changed and could not test.** The audio
tap no longer runs all the time; it now starts when a visualiser appears and
stops when it goes away. Four cases, all need a real look:

- Notch already open with music playing → **bars move with the audio.** If they
  sit flat, the tap is not starting.
- Pause, wait a few seconds, play again → bars come back.
- Close the notch, reopen it while still playing → bars come back.
- **Music app launched *after* the notch is already open** → open the notch
  first with nothing playing, *then* start Apple Music. Bars must still appear.
  This is the case a bug of mine broke and I then fixed; it is the most likely
  place for it to still be wrong.

**6.6b** Settings → turn **Real-time waveform** off and on while music plays.
✅ Off: bars fall back to the fake randomised visualiser. On: real bars return.

**6.6c** The scrubber waveform now redraws at 30 fps instead of 60. ✅ Should
look the same. If it looks choppy, say so.
**6.7** Press the media keys (F7/F8/F9). ✅ Anchor handles them.
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

**9.1 — Idle CPU.** Leave the app alone, then:
```bash
/private/tmp/claude-501/-Users-arronlingham-Anchor/afa47fe6-293c-4cd3-aa73-51fa1a67c979/scratchpad/measure-strict.sh Anchor 240 "manual-check" 120
```
✅ Mean **under 0.10%**, median **0.00%**, RSS around **16 MB**.

Use `measure-strict.sh`, not `measure.sh` — it settles first and aborts if the
pid changes mid-run instead of quietly reporting nonsense. Measured on this
build: mean 0.08%, median 0.00%, p90 0.10%, RSS 16 MB, against 0.95% / 0.80% /
1.30% / 27 MB before the audio-tap change.

**Never measure while a build is running** — `ps %cpu` is a decaying average, so
a concurrent `xcodebuild` poisons the number and keeps poisoning it for a while
after it finishes.

**9.2 — During playback.** Repeat while music plays with the notch open. ✅ This
is now the expensive case rather than idle, because the tap only runs here.
Expect it to be clearly higher than idle — that is correct and intended.

**9.3 — Energy.** Activity Monitor → Energy tab, after an hour of normal use.

---

## 10. Stability

**10.1** Leave it running a full day, then check for crash logs (see 1.2).
**10.2** Sleep and wake the Mac several times.
**10.3** Restart; confirm Anchor launches at login.
**10.4** Leave music playing an hour; watch RSS in Activity Monitor for steady growth (a leak).

---

## 11. Added 2026-08-25 — all default OFF, enable before testing

Every feature below is off out of the box. Turn each on in Settings first, or it
will correctly appear to do nothing.

### Lyrics (cat 4) — Settings › Media › Enable lyrics
- A track with timed lyrics: the sheet fills, the current line is bold and
  centred, and lines advance in step with the music.
- **Tap a line** — playback seeks there. Try Spotify *and* Apple Music; they take
  different paths through `MusicManager.seek(to:)`.
- Timing feels right. If lines land early, pull **Lyrics timing** toward 0. It
  defaults to +0.20s, calibrated to one report on Spotify over built-in speakers
  — a guess, not a measurement.
- A track LRCLIB has no timing for (Drake — *Janice STFU*): the tab reads as a
  plain sheet headed "Timing unavailable", and the notch and lock screen show
  **no lyric row at all** rather than an empty gap.
- A track LRCLIB has nothing for: "No lyrics found", no hang.
- **Translate lyrics** on: a translation appears under the current line only.
  macOS may ask to download a language model. A failure must leave the lyrics
  readable, not blank.
- The notch lyrics tab does **not** scroll — it fits lines to the height.

### Lock screen immersive player — no setting, tap the artwork
- Lock with music playing, tap the album art: blurred artwork behind, large
  cover, transport along the bottom.
- With lyrics: five lines beside the cover, one behind and three ahead.
- Without lyrics the cover centres instead of sitting off to one side.
- Escape dismisses; so does a tap on the backdrop, but **not** on the artwork.
- Unlock while it is open — no full-screen window left behind.
- **Never exercised.** Only the layout was verified, by render. The window
  resize, the transition and dismissal are all unproven.

### Eye break (cat 20) — Settings › General
- Set "Break every" to 5 minutes rather than waiting 20. The notch shows
  "Look 20 feet away" and counts down.
- The × skips; skips are counted separately from completions.
- Sleep the display mid-interval and return: the interval restarts rather than
  firing immediately.

### File shelf (cat 10) — Settings › General
- Drop files on the Shelf tab; thumbnails appear.
- Drag one out to Finder — it moves the **original**, not a copy.
- Double click opens; right click reveals or removes; Clear empties it.
- Quit, move a file elsewhere on disk, relaunch: the item survives, because these
  are bookmarks rather than paths. Delete a file instead and its row disappears.

### System stats (cat 8) — Settings › General
- The Stats tab shows CPU, memory, network. Compare CPU with Activity Monitor;
  they should agree within a few points.
- **The point of the design:** close the Stats tab and sampling stops. Anchor's
  own CPU should fall back to idle.

### Window snapping (cat 16) — Settings › General
- Needs Accessibility, which dictation already required. Drag a window against
  the left or right edge to tile it; top edge fills the screen.
- Try a second display if you have one — the coordinate conversion differs there
  and is the likeliest thing to be wrong.

### Caffeinate (cat 20) — Settings › General
- On, then from Terminal:
  ```bash
  pmset -g assertions | grep Anchor
  ```
  Expect `NoDisplaySleepAssertion named: "Anchor: keeping this Mac awake"`.
- Off — the assertion disappears. Quit with it on and relaunch: it is re-taken,
  because assertions die with the process.

### The rename — no user-visible change intended
- Settings all still hold their values; the bundle id did not change.
- Idle animations and shelf contents survived the Application Support move from
  `DynamicIsland/` to `Anchor/`.
- **Export logs** produces a non-empty archive. It was searching for files named
  "Anchor" and finding none, since crash logs are named after the product.

## Reporting back

Give me the item number, what you expected, and what happened. For dictation, say which app you were pasting into — native apps, Electron apps, and terminals each take a different path.

## 12. Added since the checklist was written

Each is off by default unless noted — turn it on in Settings first.

87. **Desktop number** (Settings → General → Desktop). Enable, then switch
    desktops with Ctrl+Arrow. The badge in the notch header should track it and
    match Mission Control. Fullscreen an app: the number must **not** change,
    because a fullscreen Space is not a desktop.
88. **Battery history** (Settings → Battery → History). Enable and leave it a
    while; the graph fills as the level moves. It samples on power-source
    change, not on a timer, so a machine held at 100% on mains legitimately
    shows "Collecting…" for a long time. Unplug to make it move.
89. **Colour picker** — **⌘⇧P**. The system eyedropper appears; pick a colour
    and it lands on the clipboard. Change the format under Appearance → Colour
    picker and confirm the pasted text changes. Click a swatch in Recent to
    copy it again.
90. **Notch animation profile** (Settings → Appearance → General → Open and
    close). Try all four. **Bouncy is the default and must feel exactly as it
    did before** — it reproduces the values that were previously hardcoded.
    Instant should have no animation even with "Use simpler close animation"
    toggled either way.
91. **Download icon style** (Settings → Downloads). Start a download in a
    Chromium browser and check the live activity shows the file's icon on
    "Only app icon" (the default), the arrow on "Only download icon", and both
    on the third. It is the icon of the *file*, not of the browser — this
    watches the Downloads folder and cannot tell which app started a download.
92. **Diagnostic log collection** should now actually contain the app's own log
    lines; before this it filtered on a subsystem the logger never used.

93. **Multi-display control window** (needs a second monitor; `showOnAllDisplays`
    is already on for this profile). With music playing, open the notch on both
    screens: each should get **its own** floating control bar, not one bar that
    jumps between them. Close the notch on one screen — the other screen's bar
    must stay up and must still respond. Drag the notch to the other display
    while a bar is showing; it should follow. Unplug the second monitor with a
    bar visible: that bar should disappear rather than reappear stranded on the
    remaining screen. **This code has never run on two displays.**

94. **Touch ID lock** (Settings → General → Touch ID). Turn on "Lock clipboard
    history" and "Lock notes". Open the clipboard panel with ⌘⇧C — Touch ID
    should be asked for **before** the panel appears, not after. Cancel: nothing
    should open. Open the notes and clipboard tabs in the notch — each shows a
    lock until unlocked. Within the grace window it should not re-ask; lock the
    screen and it should ask again. Set "Always ask" and confirm every open
    prompts. **Also confirm the fallback**: three failed fingerprints should
    offer your login password rather than locking you out.

95. **Per-app mute** (Settings → Media → Per-app audio). Turn it on; the list
    shows apps using audio, with the ones currently playing first and a speaker
    icon. Play something in Spotify, mute it from the list — audio should stop
    while system volume is untouched and other apps keep playing. Unmute and it
    should come back. Quit the muted app and confirm it drops off the list
    rather than staying stuck as muted. **Then quit Anchor while an app is
    muted** — that app must go back to normal on its own, because macOS destroys
    the tap with the process. **This is the one feature verified only by
    construction**: a standalone probe could not create a real tap (no audio TCC
    grant), so the mute has never actually been heard to work.

96. **Battery health** (Settings → Battery → Health). Shows condition, maximum
    capacity, cycle count, capacity in mAh and temperature, read from the
    battery's own registers. Cross-check against System Information → Power:
    cycle count and maximum capacity should match. Read-only; there is no charge-limit control.

97. **Pinned clipboard items survive a restart.** Enable the clipboard manager,
    copy a few things, pin one, then quit and relaunch Anchor. The pin must
    still be there. This was broken: `ClipboardItem.id` was a `let` with an
    initial value, which Codable encodes but cannot decode, so every launch
    minted fresh UUIDs — and pinning matches `$0.id == item.id` across two
    separately-persisted arrays, so the same item ended up with two different
    ids and never matched.
98. **Toggling "enable download listener" takes effect immediately.** Turn it
    off, start a download, confirm no live activity; turn it on, start another,
    confirm it appears — without restarting Anchor. The Combine subscription
    watching that setting was discarded at creation, so the toggle previously
    did nothing until relaunch.

99. **Display changes and lock-screen widgets, after the isolation change.**
    Sixteen notification and animation callbacks were wrapped in
    `MainActor.assumeIsolated`, which **crashes rather than warns** if one ever
    arrives off the main thread. The notification ones could not be exercised
    here. Do each of these and confirm no crash: change display resolution or
    scaling; plug and unplug an external monitor; sleep and wake the display;
    lock and unlock; let the music control window animate closed; let a
    vertical HUD fade out. A crash log naming `assumeIsolated` means one of the
    sixteen was wrong and should be reverted to `Task { @MainActor in ... }`.

100. **Notification mirroring** (Settings → Live Activities → Mirror
     notifications). Needs Full Disk Access for Anchor — already granted. Turn
     it on; an "Alerts" tab appears in the notch. Trigger a notification (send
     yourself an iMessage, or run
     `osascript -e 'display notification "x" with title "y"'`) and it should
     appear in that tab within about a second, with the sending app's icon.
     Verified working end to end on a signed build: the kqueue watch armed, the
     commit fired it, and the record parsed. **It will look broken in a Debug
     build** — TCC grants bind to the code signature, so an ad-hoc signed build
     reports the database as unreadable.

## 13. Added 2026-08-28 — the seven app-parity features, all default OFF

These are the checks I could not run. Everything below builds, renders and
passes what could be tested headlessly; what is left needs eyes, ears, or a
second monitor.

**Do 101 first.** It is the only one that puts Anchor in the real-time path of
your audio.

101. **Per-app volume — needs listening to** (Settings → Media → Per-app audio).
     Turn per-app audio on, play something in Spotify, and drag its slider.
     - At **100%** nothing should be engaged: no blue waveform badge on the row,
       and audio should be bit-identical to the feature being off. Moving away
       from 100% and back must tear the engine down, not leave it running.
     - At **50%** that app should get quieter while everything else stays where
       it was. At **150%** louder. Listen for **dropouts, crackle, stutter or a
       change in stereo image** — an IOProc sits in the real-time path and those
       are the failure modes.
     - Check **latency**: audio should not lag video.
     - Switch output device (headphones in/out) while a slider is off 100%. The
       aggregate device is built around the output that was default at the time,
       so this is the most likely thing to misbehave.
     - Quit Anchor with a slider off 100%. **Audio must come straight back to
       normal** — the OS destroys our taps with the process.
     - If anything sounds wrong, set every slider to 100% and turn per-app audio
       off; that removes the whole path.

102. **Vinyl widget — does the window actually appear?** (Settings → Vinyl).
     Turn it on with music playing. A record should appear near the bottom-right
     of the main screen, turning while playing and stopping when paused, with
     the album art as a round label and the tonearm swung on.
     **This is the one thing I could not verify at all.** The panel is created
     with the right geometry and reports itself visible, but in a headless test
     instance it never reached the window server, and I could not tell whether
     that was the code or the test environment. If nothing appears, that is the
     bug — say so and I will fix it properly.
     Then: drag it somewhere, quit and relaunch (should return to where you left
     it); try all four sizes and all three layers; hover for the transport
     controls; turn the tonearm, progress ring and title on and off.

103. **Ring app switcher** (Settings → Launcher → App switcher). Turn on, then
     **⌥Tab**. A ring of running apps appears, centred on the screen the pointer
     is on, with the app you were *last* in highlighted — one press and release
     should behave like ⌘Tab. Hold ⌥ and tap Tab to go round; release to switch.
     Check Escape cancels, Return confirms, and the pointer can hover and click
     any icon. **W** should close the highlighted app.
     Keyboard control needs Accessibility — if the ring opens but Tab does
     nothing, that grant is the reason, and the pointer should still work.

104. **Menu bar shrinker** (Settings → Menu Bar). Turn on: a chevron appears in
     the menu bar. **⌘-drag** some menu bar icons to the *left* of it, then click
     it — those icons should disappear, and clicking again brings them back.
     Restart Anchor and confirm both the divider and your icon arrangement come
     back where you left them.
     Then try "hide again after" and the always-hidden section.
     Watch for it fighting the notch: on a notched display the hidden items are
     pushed under the notch rather than off the screen edge, and I could not
     check how that looks.

105. **Keep-awake triggers** (Settings → General → Keep awake). Turn on "Also
     stay awake while plugged in", then unplug and replug. The status line under
     the toggles should say "Awake: on power" while plugged and disappear when
     not — **and your own "Prevent this Mac from sleeping" switch must not
     change state either way**, which is the whole reason they are separate.
     Same for the external-display trigger. Add an app under "Also stay awake
     while these apps run", quit it, and confirm the reason drops.
     `pmset -g assertions` should show the assertion appear and disappear.
     "Nudge the pointer" needs Accessibility; with it on, the pointer should
     twitch once a minute *only while the Mac is being kept awake*.

106. **To-do list** (Settings → To-Do). Turn on; a "To-Do" tab appears in the
     notch. Type a task and press Return — the field should keep focus so you
     can type several. Tick one: it should move below the divider with a
     strikethrough. Double-click a title to rename. Right-click for priority and
     due dates; an overdue item's date should go red. Try each sort order.
     Quit and relaunch — everything should still be there.

107. **Daily git commit** (Settings → Daily Commit). **Add a throwaway
     repository first, not one you care about.** Press "Commit Now": the result
     line should say "Empty commit on <branch>". Check `git log` — one empty
     commit, your usual author, no co-author trailer.
     Then set the time a couple of minutes ahead, leave it, and confirm it fires
     on its own. Relaunching the same day must **not** commit again.
     Only turn "Push after committing" on if you actually want that; it is
     confirmed separately because a push cannot be undone.
     Verified end to end against a scratch repo, including the once-a-day guard.
