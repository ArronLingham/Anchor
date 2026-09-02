# Anchor — manual test plan

Everything here needs a human: eyes, ears, a second device, or a permission this
machine has not granted. It is deliberately **not** a list of everything the app
does — most of that is covered automatically and re-testing it by hand is wasted
evenings.

Build under test: the installed signed Release at `/Applications/Anchor.app`.

---

## Don't re-test these — 32 harnesses, 981 assertions cover them

```bash
for t in tests/run_*_tests.sh; do "$t"; done   # excludes the two LIVE suites
python3 tests/test_privacy_configuration.py
```

Already proven, mathematically or structurally:

| | Covered by |
|---|---|
| EQ filter coefficients, stability, limiter ceiling | `run_dsp_tests` (55) |
| Equal-power device crossfade | `run_crossfade_tests` (45) |
| Loudness gain limits, noise floor | `run_loudness_tests` (23) |
| AutoEQ profile parsing, gain signs | `run_autoeq_tests` (30) |
| Window snap geometry, all 16 zones | `run_snapzone_tests` (68) |
| Storage cleaner — what it may and may not touch | `run_cleanup_tests` (92) |
| DDC wire format | `run_ddc_tests` (74) |
| Version comparison, `brew outdated` parsing | `run_version_tests` (60) |
| Apple Shortcuts argv safety | `run_shortcuts_tests` (50) |
| Gemini request/response | `run_gemini_tests` (44) |
| Quit-on-close guards | `run_applifecycle_tests` (33) |
| To-do ordering | `run_todo_tests` (38) |
| Alert hysteresis | `run_alert_tests` (26) |
| …and 17 more | |

Also automated: **226 features enabled at once** (zero crashes), and **hostile
Defaults values** — extreme integers, emoji, 500-character strings, path
traversal, a 200-flip toggle storm (zero crashes). See §14.

**A harness cannot tell you the notch looks right, or that the EQ sounds
correct.** That is what this document is for.

---

## Grant these first — they gate whole sections

| Permission | State | Blocks |
|---|---|---|
| Accessibility | **granted** | — |
| Microphone | **granted** | — |
| Audio capture | **granted** | — |
| Calendar, Reminders, Bluetooth | **granted** | — |
| **Screen Recording** | **NOT GRANTED** | §11 entirely |
| **Full Disk Access** | **NOT GRANTED** | Notification mirroring (§10.4) |
| **Camera** | never prompted | §12.1 — will ask on first use |

**Screen Recording is stranded on the old bundle id.** The system database holds
the grant against `com.Ebullioscopic.Atoll`; `com.arronlingham.Anchor` has no
entry at all. You did grant it — the rename orphaned it. Add Anchor under
System Settings › Privacy & Security › Screen Recording.

---

## Start here — the six things only you can check

Ordered by what would be worst if broken.

| | Item | Why it needs you |
|---|---|---|
| 1 | **Per-app volume and EQ** (§8) | Anchor re-renders another app's audio in real time. The maths is proven; it has never been *listened to*. This is the one feature that can make your Mac sound wrong. |
| 2 | **Camera mirror** (§12.1) | Never opened on this machine. Watch the green indicator go out when you leave the tab — that is the whole privacy claim. |
| 3 | **Multi-display** (§13) | **Two displays are attached now**, and `showOnAllDisplays` is on for your profile. These paths have never run on two screens. |
| 4 | **Gemini** (§12.2) | No API key here, so nothing has ever been sent. |
| 5 | **Dictation end to end** (§6) | Transcription is proven; everything around it (injection, clipboard restore) is not. |
| 6 | **HUD suppression** (§4) | Highest regression risk in the app — a failure here breaks volume and brightness system-wide. |

---

## 1. Smoke — two minutes

**1.1** One process, no children, no stray listener:
```bash
pgrep -lx Anchor && pgrep -P $(pgrep -x Anchor) | wc -l && lsof -nP -iTCP:9020
```
✅ A PID, then `0`, then nothing.

**1.2** No crash reports:
```bash
ls ~/Library/Logs/DiagnosticReports/ | grep -i anchor
```
✅ Nothing.

**1.3** Settings opens; click every sidebar tab.
✅ All **33** panes render. ❌ A blank pane means a tab lost its view.

**1.4** Quit from the menu, then:
```bash
ps -o state= -p "$(pgrep -x OSDUIHelper)"
```
✅ `S`. ❌ `T` means the system volume/brightness HUD is left frozen —
`kill -CONT $(pgrep -x OSDUIHelper)` fixes it. Relaunch Anchor afterwards.

---

## 2. Notch core

**2.1** Hover the notch. ✅ Opens smoothly, every time. Do it twenty times in a
row — an intermittent failure to open is a known past bug.
**2.2** Tabs switch cleanly; no flicker or stuck animation.
**2.3** Resize behaviour: open a tab with more content (Clipboard, To-Do). ✅ The
notch grows and shrinks without jumping.
**2.4** Keep the notch open (Settings › General). ✅ It stays open until toggled off.
**2.5** Animation profiles (Settings › Appearance): bouncy / smooth / snappy /
instant. ✅ Each is visibly different.
**2.6** Desktop number (Settings › General › Desktop). Switch Spaces.
✅ The number tracks. Fullscreen an app — it should **not** count as a desktop.

---

## 3. Launcher — ⌥Space

**3.1** Opens centred, frosted.
**3.2** **Type immediately without clicking first.** ❌ Having to click is the
classic focus bug for this kind of panel. Activation was being requested
before the panel was ordered front, so AppKit handed key to a notch window
instead.

**3.1a Fullscreen.** ✅ The whole display blurs behind it; clicking outside
dismisses. Settings › Launcher › Panel › "Fill the screen" turns it off.
**3.1b Paging.** Move the pointer into the left or right edge of the grid.
✅ The page turns, and does not keep turning while the pointer rests there.
Try each Paging setting: dots, scroll bar, both.
**3.1c Order.** Settings › Launcher › Grid › Order. Under **Custom**, drag an
icon — it moves and stays moved. ❌ Under the other three, dragging must do
nothing (their positions are derived).
**3.1d Folders.** ⌥-drag one app onto another. ✅ A folder appears with both in
it. Drop a third app on the folder to file it. Click the folder to open it,
rename it, and right-click an app inside to move it back out. Emptying a folder
removes it.
**3.1e Recall.** Type something, dismiss, reopen within 5 seconds.
✅ The search is still there. Wait longer and it opens empty.
**3.1f Widgets.** Settings › Launcher › Widgets. Turn on clock, weather and now
playing. ✅ Clicking the record opens the vinyl player.

**3.2a Apple Shortcuts.** With Settings › Launcher › "Show Apple Shortcuts" on,
open the launcher and type the name of one of your shortcuts.
✅ It appears, labelled "Apple Shortcut". ❌ Never appears — the list is loaded
by a subprocess and nothing used to recompute when it answered.
**3.3** Type `term` → Terminal first, matched letters bold.
**3.4** Arrows move and wrap; Enter launches; Esc returns focus to where you were.
**3.5** Click away → dismisses.
**3.6** Frecency: launch System Settings once, reopen, type `ss`.
✅ System Settings now outranks Screen Sharing.
**3.7** Grid (empty query): 7×4, page dots, swipe pages, ↓ moves a whole row,
selection stops at the ends rather than wrapping.
**3.8** Calculator: `18*7.5` → 135; `100/3` → 33.333333 (**not** 33);
`(2+3)*4` → 20; ↩ copies.
**3.9** It must **not** hijack searches: `Safari`, `Final Cut Pro`, `x-code` all
search normally.
**3.10** Install any `.app` into `/Applications` → searchable without restarting.
**3.11** Apple Shortcuts (Settings › Launcher). ✅ Your 8 shortcuts appear and run.
**3.12** Ring app switcher (⌥Tab, and ⌥⇧Tab to reverse).
✅ Reversing must **not** disturb the app you were in.

---

## 4. HUD / OSD — highest regression risk

**4.1** Volume, brightness, keyboard backlight keys. ✅ Anchor's HUD, not macOS's
grey square.
**4.2** Each HUD style: inline, circular, vertical, custom OSD.
**4.3** Brightness keys specifically — **this has been broken before.** If F1/F2
do nothing, check Input Monitoring, and note which keyboard you're using.
**4.4** Sneak peek appears and dismisses on its own.
**4.5** Caps Lock indicator.

**4.6 The volume HUD — this was the broken one.** Press a volume key.
✅ Only Anchor's HUD. ❌ macOS's grey square appearing alongside or instead.
The signal was briefly SIGKILL, which left no OSDUIHelper at all; volume is the
one key that respawns it (Anchor's own CoreAudio write does), so it drew before
the watcher could catch it. Confirm the helper is alive and stopped:

```bash
ps -o state= -p "$(pgrep -x OSDUIHelper)"    # must print T
```

An empty result means no helper exists and suppression is broken again.

**4.7 Turning the HUDs off must give the system HUD back.** Switch off volume,
brightness and keyboard-backlight HUDs. ✅ macOS's own HUD returns.
❌ *No* HUD at all — that was the bug: Anchor stopped drawing while keeping the
native one suppressed. `pgrep -x OSDUIHelper` should show a process in state `S`.

**4.8a Drag to set.** Turn on Settings › HUD › "Drag the HUD to set the value".
Press and drag on a volume or brightness HUD. ✅ It scrubs like a slider, on all
four styles — inline, circular, vertical, custom OSD. ❌ Music, battery,
Bluetooth and caps lock HUDs must NOT respond; they are notifications.

**4.8 External keyboard brightness.** With Settings › HUD › "Use F1 and F2 for
brightness" **on**, press F1/F2 on the external keyboard. ✅ Anchor's HUD.
The guard rejected any event carrying `.function`, and macOS sets that bit on
every F-key event — so this path could never run.

---

## 5. Media

**5.1** Play in Spotify, Apple Music, and a browser. ✅ Title, artist, artwork
and progress all correct in each.
**5.2** Inline controls: play/pause, skip, scrub.
**5.3** Artwork colour tinting.
**5.4** Lyrics tab (Settings › Media). ✅ Lines highlight in time; tap a line to seek.
**5.5** Live stream (a radio station or live YouTube). ✅ Elapsed time shows
`--:--` rather than crashing. *A NaN duration used to SIGTRAP here — now fixed,
worth confirming.*
**5.6** Vinyl widget (Settings › Vinyl). ✅ **Does the window appear at all?**
It could never be verified headlessly. Record turns while playing, stops when
paused, album art is round and centred.
**5.7** Music control window on each display (§13).

---

## 6. Dictation — ⌘⇧D

**6.1** Hold ⌘⇧D in TextEdit, say *"testing one two three"*, release.
✅ Text appears at the cursor within about a second.
**6.2** Repeat in a **browser field** and in **Terminal** — different injection
paths; a past bug only showed in the browser.
**6.3** Copy `KEEPME`, dictate, then ⌘V. ✅ You get `KEEPME`, not the transcript.
**6.4** Dictate, then copy something else **within a second**, then ⌘V.
✅ Your new copy is intact.
**6.5** Notch shows: mic icon → level meter that moves with your voice → live
transcript → "Transcribing…".
**6.6** Edge cases — tap without speaking; tap-release rapidly several times;
press again mid-transcription; hold in silence; connect AirPods mid-dictation.
✅ Always returns to idle. ❌ Stuck on "Transcribing…" is the failure to watch for.

---

## 7. Clipboard & text

**7.1** Copy several things → history appears, newest first.
**7.2** Pin an item, **restart Anchor**. ✅ Still pinned. *This silently broke once.*
**7.3** Copy an image, a file, a colour. ✅ Each renders correctly.
**7.4** Clean link (Settings › Clipboard). Copy a URL with `utm_*`.
✅ Stripped, real params kept. *Automated in `run_functional_live.sh`.*
**7.5** Auto-clear after N seconds, and on lock.
**7.6** Paste as plain text — ⌥⇧⌘V.
**7.7** Text snippets (Settings › General). Type a trigger. ✅ Expands.
Placeholders `{clipboard}`, `{date}`, `{time}` all resolve.
✅ **It must not expand in a password field.**
**7.8** Colour picker — ⌘⇧P. Pick a colour; each of the eight formats pastes correctly.
**7.9** Touch ID lock (Settings › General). ✅ Prompts before revealing clipboard
history; cancel reveals nothing.

---

## 8. Audio engine — listening tests

**8.0a Per-app row.** Settings › Media › Per-app audio, with something playing.
✅ Row reads `[icon] [name] ... [volume] [mute?] [EQ] [output]`.
Click the volume icon repeatedly — the soundwave count cycles and wraps, and the
level changes audibly.
Switch Volume control between **Preset volumes** and **Volume booster**:
✅ presets has four steps including a muted one and shows NO separate mute
button; booster has three steps, never quieter than normal, and DOES show a
headphones-with-a-line mute button.
**8.0b Output routing.** Click the output icon and pick another device.
✅ That app alone moves to it. The icon tints while Anchor is engaged.
**8.0c EQ.** Click the EQ icon. ✅ Ten vertical sliders labelled 32, 64, 125,
250, 500, 1k, 2k, 4k, 8k, 16k, a Preset dropdown showing the preset in force,
and Custom once you move a band.

**The maths is proven; the sound is not.** Headphones, on material you know.

**8.1 Per-app EQ.** Apply a strong preset to a running app. ✅ Audible and in the
right direction. Set every band to 0 dB → **indistinguishable from bypass**.
Sweep one band −12 → +12 dB while playing: smooth, no clicks, no ringing at high Q.
**8.2 Limiter.** Large boost on a loud track. ✅ Gets louder then stops — never
crackles. Crackle means the limiter is being bypassed, not that the maths is wrong.
**8.3 Loudness leveler.** Wide-dynamic-range material (a film score).
✅ Quiet passages lift without loud ones distorting.
⚠️ **Known rough edge:** a hard 5.5 dB step at −40 dB with no hysteresis, so
material sitting there may audibly *pump*. The smoother should make it a swell —
**a click there means the smoother is not being applied.**
**8.4 Device crossfade.** With per-app volume active on a playing app, switch the
system output device. ✅ Seamless — no gap, no dip at the halfway point.
A dip means the fade has gone linear instead of equal-power.
**8.5 AutoEQ import.** Import a real profile for headphones you own. ✅ Preamp is
negative; filter count and frequencies match the file. Then import a broken file
(truncated, or every filter `OFF`) → rejected, not half-applied.
**8.6 Per-app mute**, and **mute-all-microphones** (Settings › Shortcuts) during a call.
**8.7 Output device cycling** (Settings › Shortcuts). ✅ Walks the list and wraps.
With one device it should do **nothing** — no HUD.
**8.8 Pin the microphone** (Settings › Media & Display). Connect AirPods.
✅ The pinned mic stays selected. Unplug it → macOS takes over rather than
leaving you with no input.

---

## 9. Windows & input

**9.1** Snap: drag a window to each edge and corner. ✅ Lands cleanly, no gap or overlap.
**9.2** The 16 zone shortcuts (Settings › Shortcuts).
**9.3** Quit on last window close (Settings › General › Windows). **Test with
nothing unsaved open.** ✅ Closing TextEdit's last window quits it. Then the
guards: **minimise** instead → must *not* quit; close a window within ten seconds
of launch → must survive; Finder must never quit.
**9.4** Focus follows mouse. ✅ Raises after the dwell; suspended while dragging,
while a modifier is held, and while a menu is open.
**9.5** Key debounce (Settings › General › Keyboard). ✅ Ordinary fast typing is
untouched. Watch the "filtered so far" count.
**9.6** Mouse: invert wheel (trackpad unaffected), side buttons → back/forward.

---

## 10. System utilities

**10.1** Menu bar shrinker (Settings › Menu Bar). ✅ Chevron appears; ⌘-drag to
arrange; hidden icons reappear on click. ⚠️ On a notched display, check the
hidden icons are not pushed *under* the notch.
**10.2** Menu bar readout. ✅ **Nothing to its left shifts** as the numbers
change — run a build and watch. All three off → the item disappears entirely.
**10.3** Alerts (Settings › General › Alerts). Battery: one alert, not one per
sample; plugging in clears it promptly. CPU: nothing for five minutes, then one.
⚠️ **Your disk is 92% full**, so the disk alert fires immediately at its 90%
default — correct, not a bug.
**10.4** Notification mirroring — **needs Full Disk Access**.
**10.5** Eye break, keep-awake, file shelf, system stats, to-do list, daily commit
(use a **throwaway repo**), battery history and health, downloads, timer, calendar,
notes and Apple Notes sync.

---

## 11. Screen capture — blocked

Nothing in this section can run until Screen Recording is granted (see above).
**11.1** ⌥Space → "screenshot". **11.2** → "copy text" (OCR). **11.3** QR decode.

---

## 12. New and never used

**12.1 Camera mirror** (Settings › Media & Display › Camera). Turn on, open the
notch, pick Mirror. ✅ macOS prompts for camera access — **read the prompt text**
and check it describes what actually happens. Preview is flipped by default.
✅ **Switch away from the tab and watch the green indicator go out.** It must be
lit only while the preview is visible. Try a Continuity Camera too.
**12.2 Gemini** (Settings › Gemini). Paste a key from Google AI Studio.
```bash
security find-generic-password -s com.arronlingham.Anchor.gemini   # key is here
defaults read com.arronlingham.Anchor | grep -i gemini             # must NOT contain it
```
✅ Ask something; ask a follow-up that only makes sense with context. Turn
"Remember the conversation" off and relaunch → history gone. Set context to 6
turns and hold a long conversation — *this is the case that 400s if the trim is wrong.*
Remove the key → the tab explains itself rather than failing silently.
**12.3 Storage** (Settings › Maintenance). Scan. ✅ Sizes roughly match `du -sh`
(Anchor uses decimal units so reads **higher** — 183 MiB shows as 191.9 MB).
Defaults must be logs / crash reports / simulator caches only.
Move something small to Trash → **open the Trash and check it is there.** That is
the entire safety guarantee. There is deliberately no "empty Trash" button.
**12.4 Updates** (same pane). ✅ Homebrew packages list with `installed → available`;
pinned formulae show "pinned" and offer no button; Upgrade opens Terminal showing
the command **before** anything runs.
**12.5 Disk image installer.** Mount a `.dmg` with one app. ✅ Prompt appears;
**Cancel copies nothing and leaves the image mounted.** Then Install → lands in
`/Applications`, image ejects, and replacing an existing copy puts the old one in
the **Trash**. A multi-app DMG and a USB stick must stay silent.
**12.6 External display brightness** (Settings › Media & Display).
⚠️ This monitor reported **no DDC response** — twelve read attempts across three
timings. Before assuming a bug: turn **DDC/CI on in the monitor's own OSD menu**
(off by default on many models) and try connecting it directly rather than
through a hub.

---

## 13. Multi-display — two displays are attached

Never run on two screens. `showOnAllDisplays` is on for your profile.

**13.1** A notch/pill on each display; both live and independent.
**13.2** **"Always show on external displays"** — the pill must be visible on the
external monitor. ⚠️ If it is missing, check you are **not mirroring**:
`NSScreen.screens` returns one screen when mirrored, which looks identical to a bug.
**13.3** Music control window: present on the display you are using; hiding it on
one must not tear down the other's.
**13.4** Unplug the external display while both are showing. ✅ No orphaned window,
no crash.
**13.5** Change resolution / arrangement. ⚠️ This exercises the `assumeIsolated`
paths, which **trap rather than warn** if an assumption is wrong.
**13.6** Vinyl widget and lock-screen widgets on the second display.

---

## 14. Performance & stability

Already measured — reproduce only if something feels wrong:

| Configuration | mean | median | RSS |
|---|---|---|---|
| real config, settled 13 min | 0.50% | 0.47% | 27.7 MB |
| all 226 features on | 2.59% | 2.40% | 49.7 MB |

```bash
scripts/measure.sh Anchor 180 "<label>"
```
⚠️ **Let it run 12+ minutes first** — RSS needs that long to settle, and a
5-minute reading has been wrong by 4×. Never sample while a build runs, and note
that sampling from a Claude session measures the session too.

**14.1** Leave it running a full day. ✅ RSS flat, no crash reports.
**14.2** Sleep/wake, and lock/unlock. ✅ Recovers; pollers park while asleep.

---

## Known broken / won't fix

| Thing | Why |
|---|---|
| Bluetooth HUD animations don't render | The 8 `.mov` files are unreachable LFS stubs |
| Screen capture, OCR, QR | Screen Recording not granted |
| Notification mirroring | Full Disk Access not granted |
| Face ID, Bluetooth proximity unlock | Needs a Developer ID identity and a privileged helper |
| Lid-angle automation | No such sensor on `Mac14,2` |
| Sports, finance widgets | Not built — need live APIs |
| DDC on this monitor | Reports no DDC response; likely off in its OSD menu |

---

## Reporting back

For anything that fails, the useful shape is: **what you did**, **what you
expected**, **what happened**, and whether it repeats. If the app crashed:

```bash
ls -t ~/Library/Logs/DiagnosticReports/ | grep -i anchor | head -1
```
