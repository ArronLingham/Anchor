<div align="center">

# ⚓️ Anchor

### *Dynamic Notch Bar, System Utility Hub & Productivity Suite for macOS*

[![macOS](https://img.shields.io/badge/macOS-26.0%2B-000000?style=for-the-badge&logo=apple&logoColor=white)](https://apple.com)
[![Architecture](https://img.shields.io/badge/Architecture-Apple%20Silicon%20(arm64)-FF9500?style=for-the-badge)](https://apple.com)
[![Swift](https://img.shields.io/badge/Swift-6.0%20%7C%20SwiftUI-F05138?style=for-the-badge&logo=swift&logoColor=white)](https://swift.org)
[![CPU](https://img.shields.io/badge/Idle%20CPU-0.00%25%20Median-brightgreen?style=for-the-badge)](CLAUDE.md)

<p align="center">
  <b>Anchor</b> unites dynamic notch interaction, on-device AI voice dictation, a Spotlight-class app launcher, a multi-band per-application audio equalizer, and dozens of macOS power utilities into a single, cohesive, ultra-lightweight Swift application.
</p>

</div>

<img width="1470" height="956" alt="anchor_dynamicIsland" src="https://github.com/user-attachments/assets/7e02fb40-0030-4b6e-8605-4d960204a5c6" />



---

## 📑 Table of Contents

- [System Requirements](#-system-requirements)
- [Architecture & Performance Benchmarks](#-architecture--performance-benchmarks)
- [Feature Tour](#-feature-tour)
  - [1. Dynamic Notch & External Display Pill](#1-dynamic-notch--external-display-pill)
  - [2. Universal Media Player, Visualizers & Desktop Vinyl](#2-universal-media-player-visualizers--desktop-vinyl)
  - [3. Per-App Audio Engine & Pure Swift DSP](#3-per-app-audio-engine--pure-swift-dsp)
  - [4. On-Device Voice Dictation (WisprFlow Replacement)](#4-on-device-voice-dictation-wisprflow-replacement)
  - [5. Spotlight-Style App Launcher (LaunchMe) & Shortcuts](#5-spotlight-style-app-launcher-launchme--shortcuts)
  - [6. Custom HUD & System OSD Suppression](#6-custom-hud--system-osd-suppression)
  - [7. Window Management & Input Ergonomics](#7-window-management--input-ergonomics)
  - [8. Productivity Hub](#8-productivity-hub)
  - [9. Developer Automation & Claude Usage Watcher](#9-developer-automation--claude-usage-watcher)
  - [10. System Monitoring & Smart Housekeeping](#10-system-monitoring--smart-housekeeping)
  - [11. On-Screen AI Assistant](#11-on-screen-ai-assistant)
  - [12. Lock Screen Widgets & Live Activities](#12-lock-screen-widgets--live-activities)
- [Keyboard Shortcuts Reference](#-keyboard-shortcuts-reference)
- [System Permissions & TCC Grants](#-system-permissions--tcc-grants)
- [Building & Installation](#-building--installation)
- [Repository Structure](#-repository-structure)

---

## 💻 System Requirements

| Requirement | Specification | Rationale |
|---|---|---|
| **Operating System** | macOS 26.0 or newer | `MACOSX_DEPLOYMENT_TARGET = 26.0` (required for native `SpeechAnalyzer`) |
| **Architecture** | Apple Silicon (`arm64`) | Optimized for unified memory, Accelerate vDSP, and low-latency audio |
| **Hardware** | MacBook with notch or external display | Native physical notch fitting or multi-display top-edge pill overlay |

---

## ⚡️ Architecture & Performance Benchmarks

Anchor replaces an entire suite of third-party apps (WisprFlow, SoundSource/FineTune, Bartender/Ice, Spotlight launchers, window snappers, and battery monitors) while ensuring near-zero background resource consumption:

### Measured Resource Benchmarks

| Operating State | Mean CPU | Median CPU | p90 CPU | Resident Memory (RSS) |
|---|:---:|:---:|:---:|:---:|
| **Idle (Default Settings, Settled)** | `0.07%` | `0.00%` | `0.47%` | `~15 MB` |
| **Active Playback & Notch Expanded** | `0.85%` | `0.62%` | `1.15%` | `~28 MB` |
| **Stress Test: All 226 Flags Active** | `2.59%` | `2.40%` | `3.36%` | `~49 MB` |

### Core Engineering Principles

- **Zero-Polling Guarantee:** Never use polling loops where an event-driven operating system API exists. The entire app reacts dynamically via `FSEventStream`, `kqueue` DispatchSources, CoreAudio HAL property listeners, `IOPSNotificationCreateRunLoopSource`, `NSWorkspace` notifications, and SkyLight window events.
- **Reference-Counted Active Sampling:** Resource-intensive subsystems (e.g., `SystemStatsManager`, `AudioTap`) sample only when an interface view explicitly holds an active lease via `acquire()` and park immediately on `release()`.
- **Hardware-Accelerated Animation:** Persistent animations (e.g., the spinning desktop vinyl record and live spectrum visualizer) execute via render-server Core Animation (`CABasicAnimation` on `CALayer`) rather than per-frame main-thread SwiftUI passes.
- **Native Swift Architecture:** Pure native Swift and AppKit/SwiftUI. Zero Electron runtimes, zero Node.js processes, and zero external daemon processes.

---

## 🧭 Feature Tour

### 1. Dynamic Notch & External Display Pill

- **Adaptive Notch Housing:** Sits flush against the MacBook hardware notch, smoothly expanding and morphing in response to cursor hover, clicks, or hotkeys.
- **Spring Animation Profiles:** Choose between distinct spring curves: `Bouncy`, `Smooth`, `Snappy`, or `Instant`.
- **External Display Pill:** Monitors lacking a physical notch render a floating top-edge pill overlay. Geometry and hover dimensions are computed independently per display.
- **Multi-Monitor Coordination:** Multi-window orchestration (`showOnAllDisplays` or `alwaysShowOnExternalDisplays`) provisions dedicated view models and isolated control panels for each screen.
- **SkyLight Space Pinning:** Employs `CGSSpace` membership to pin the notch overlay above all spaces (including full-screen spaces and games) when set to *Never hide*.
- **Notch Pin Mode (<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>K</kbd>):** Lock the notch expanded to maintain persistent focus without auto-collapsing on hover-out.
- **Contextual Sneak Peeks:** Glanceable micro-HUDs (volume, mic mute, battery status, caps lock, timer progress) convey real-time state without expanding the entire notch bar.
- **Integrated Notch Tabs:** Quick tab bar navigation between Notch Home, Media/Lyrics, Notes, To-Do, Terminal, System Stats, Calendar, and File Shelf.

![anchor_dynamicIsland.pdf](https://github.com/user-attachments/files/32218435/anchor_dynamicIsland.pdf)[anchor_lockScreen.pdf](https://github.com/user-attachments/files/32218457/anchor_lockScreen.pdf)


---

### 2. Universal Media Player, Visualizers & Desktop Vinyl

- **Universal Media Controller:** Unified bridge supporting Apple Music, Spotify, YouTube Music (via WebSockets), Amazon Music, Tidal, Plexamp, Roon, Audirvana, Vox, and Safari media sessions.
- **Interactive Notch Player:** Marquee scrolling track titles and artists, album artwork rendering, scrubbable progress bar, and elapsed/remaining duration readouts.
- **Live Audio Spectrum & Waveform:** Real-time Accelerate vDSP spectrum analyzer and CoreAudio capture tap (`AudioTap`). The progress scrubber activates a live waveform on hover during playback.
- **Synchronized Lyrics & Translation:** Line-by-line synchronized lyrics display with tap-to-seek, smooth auto-scrolling, and multi-language lyrics translation (`LyricsTranslator`).
- **Desktop Spinning Vinyl Widget:** Photorealistic rotating vinyl record widget (`VinylWidgetWindowManager`, `VinylRecordView`) displaying current album art spinning on physical vinyl grooves. Rendered via zero-CPU `CABasicAnimation` with desktop window-level pinning.
- **Floating Music Control Panel:** Notch-anchored or detachable floating controller offering detailed track metadata, playback history, and audio source switching.

---

### 3. Per-App Audio Engine & Pure Swift DSP

- **CoreAudio Process Taps:** Per-process volume, mute, and parametric equalization without kernel extensions or virtual audio drivers (implemented using CoreAudio process taps and aggregate devices).
- **Multi-Process App Awareness:** Automatically maps and controls audio across sub-processes and audio helpers (e.g. Spotify and Chrome helper processes).
- **Dual Volume Control Modes:**
  - **Preset Mode:** 4 stepped levels (from 0% silence to 100%) where step 0 functions as an instant mute.
  - **Booster Mode:** 3 amplified levels delivering up to 200%+ volume boost for quiet audio sources.
- **Equal-Power Device Crossfading:** Eliminates clicks, pops, and volume holes during output device switches using an equal-power (`sin² + cos² = 1`) crossfade curve.
- **10-Band Parametric Equalizer:** Pure Swift biquad filter DSP engine featuring mathematically verified pole stability across all frequency/gain/Q combinations, guarded by a `SoftLimiter` to eliminate clipping distortion.
- **AutoEQ Integration:** Direct support for importing calibrated headphone compensation profiles from the AutoEQ / oratory1990 database.
- **Dynamic Loudness Equalization:** Real-time loudness leveling utilizing ISO 226 equal-loudness contours and K-weighting filters, dynamically boosting bass and treble response at low volumes.
- **Hardware Device Utilities:** Output cycling hotkey, microphone pinning (locks audio input to a specific device against OS auto-swapping), and a global mute-all-microphones hotkey.

---

### 4. On-Device Voice Dictation (WisprFlow Replacement)

- **Push-to-Talk Hotkey (<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd>):** Hold to record, speak naturally, and release to inject transcribed text into the focused application.
- **Apple Intelligence Speech Engine:** Built on macOS 26's on-device `SpeechAnalyzer` and `SpeechTranscriber` for private, high-accuracy, offline transcription with auto-punctuation and capitalization.
- **Universal Text Injection:** Synthesizes pasteboard keystrokes (<kbd>⌘</kbd> <kbd>V</kbd>) rather than unreliable Accessibility attributes, ensuring flawless insertion into Electron apps, terminals, text editors, and custom browser inputs. Prior clipboard contents are restored automatically.
- **Zero Idle Overhead:** Audio capture and speech pipeline spin up on key-down and tear down immediately on key-up.
- **Live Notch Feedback:** Real-time audio waveform level and progressive transcription preview appear in the notch during dictation.

---

### 5. Spotlight-Style App Launcher (LaunchMe) & Shortcuts

- **Instant Search (<kbd>⌥</kbd> <kbd>Space</kbd>):** Non-activating search panel overlay with instant response.
- **Dynamic Programming Fuzzy Matching:** Optimal alignment algorithm featuring word-boundary acronym bonuses (e.g., `gc` matches *Google Chrome* with high ranking).
- **Cryptex & Deep Filesystem Indexing:** Recursively indexes `/Applications`, `/System/Applications`, `~/Applications`, and macOS Cryptex paths (`/System/Cryptexes/App/System/Applications` for Safari and core system apps).
- **7×4 Launchpad Application Grid:**
  - Multiple sorting algorithms: Alphabetical, Category, Frecency (frequency + recency with a 10-day half-life decay), or Custom drag-and-drop order.
  - App grouping: <kbd>⌥</kbd>-drag one app onto another to instantly form custom app folders.
- **Inline Arithmetic Calculator:** Real-time math evaluation (`CalculatorAction`) with safe decimal conversion to prevent integer truncation errors.
- **Apple Shortcuts Launcher:** Discover, filter, and run Apple Shortcuts directly from the search bar via safe single-argv execution (zero shell-escaping vulnerabilities).
- **Embedded Dashboard Widgets:** Optional live widgets inside the launcher (analog/digital clock timeline, weather snapshot, and now-playing disc).

---

### 6. Custom HUD & System OSD Suppression

- **Intrusive macOS OSD Suppression:** Freezes Apple's native volume and brightness banners by sending `SIGSTOP` to `OSDUIHelper`. Graceful app termination sends `SIGCONT` to restore standard macOS behavior.
- **Multiple Modern HUD Styles:**
  - **Inline Notch HUD:** Volume, brightness, and keyboard backlight indicators integrated directly into the notch curve.
  - **Minimalistic Pill HUD:** Clean, modern floating bezel overlay.
  - **Circular HUD:** Compact radial dial indicator.
  - **Vertical Bar HUD:** Side-aligned vertical slider with drag-to-set capability.
- **Interactive Drag-to-Set:** Click and drag directly on HUD elements to scrub volume or brightness levels.
- **External Display DDC/CI Hardware Control:** Direct hardware brightness and contrast adjustment over I2C, guarded by packet verification that refuses blind writes if a display does not answer.
- **Third-Party Display Bridge:** Integrates with Lunar and BetterDisplay.

---

### 7. Window Management & Input Ergonomics

- **Ring App Switcher (<kbd>⌥</kbd> <kbd>Tab</kbd> / <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd>):** Sleek circular application switcher navigating windows in MRU order without stealing key focus or fighting active window state.
- **16-Zone Window Snapping (`SnapZoneManager`):** Drag-to-edge/corner snap management supporting halves, thirds, quarters, maximize, and centered layouts with configurable hotkeys.
- **Focus-Follows-Mouse:** Automatically raises or activates windows under the pointer without requiring mouse clicks.
- **Mechanical Key Debounce:** Filters duplicate key bounce and switch chattering on mechanical keyboards.
- **Text Snippets & Auto-Expansion:** Expand text abbreviations with undo safety and listen-only event taps.

---

### 8. Productivity Hub

- **Clipboard History (<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>C</kbd>):** Searchable multi-item clipboard history supporting rich text, links, and images.
- **Biometric Security:** Gate sensitive clipboard history, credentials, or notes behind Touch ID / password authentication (`BiometricAuthManager`) via LocalAuthentication.
- **Plain Text Paste (<kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>V</kbd>):** Pastes clipboard content stripped of formatting and styling.
- **URL Tracking Stripper:** One-click removal of tracking parameters (`utm_*`, `fbclid`, `gclid`) from copied URLs.
- **Quick Notes & Apple Notes Sync:** Notch notepad with bi-directional syncing to Apple Notes via an `Atoll` tagged folder.
- **To-Do Checklist:** Interactive task list in the notch with persistent priority ordering and completion tracking.
- **Dropdown Mini-Terminal (<kbd>⌃</kbd> <kbd>`</kbd>):** Command shell in the notch for quick terminal commands and scripts.
- **Notch File Shelf:** Drag-and-drop staging shelf at the top edge of the screen for holding files across full-screen spaces.
- **Eyedropper Color Picker (<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>P</kbd>):** Built on native `NSColorSampler` (requiring no screen-recording grants) with color history and 8 output format conversions (HEX, RGB, HSL, Swift Color, NSColor, etc.).
- **20-20-20 Eye Rest Timer:** Scheduled eye rest intervals with live countdown activities in the notch.
- **Countdown Timer:** Notch timer with tactile ruler selector and Lock Screen widget support.

---

### 9. Developer Automation & Claude Usage Watcher

- **Claude Code Usage Watcher:**
  - Monitors `~/.claude/projects` using `FSEventStream` for session limit banners (`resets 8:10pm`).
  - Notch live activity displays a live countdown to the usage reset window.
  - Pushes scheduled alerts to your phone via `ntfy` with server-side delivery holding (delivering even if your Mac is sleeping at reset time).
  - Automatically resumes the halted Claude session upon reset in the correct working directory, protected by a 3-repeat safety cap.
- **Scheduled Daily Git Commit:** Background git housekeeper ensuring daily commit activity across repositories, running entirely off the main actor to prevent UI freezes.
- **Safe System Cleaner (`CleanupManager`):** Allowlist-only disk maintenance tool (logs, crash reports, simulator caches, Xcode derived data) that **strictly moves files to macOS Trash** — never permanently deletes or empties Trash.
- **Disk Image (.DMG) Auto-Installer:** Detects mounted DMGs via DiskArbitration, validates the virtual bus protocol, inspects `.app` payloads, and offers one-click copy to `/Applications` with unmounting.
- **App Uninstaller:** Drag an app to trash to automatically locate and clean associated Application Support, caches, and preference plists.

---

### 10. System Monitoring & Smart Housekeeping

- **Menu Bar Shrinker (<kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>M</kbd>):** Replaces Bartender or Ice by using an invisible spacer status item to hide excess menu bar items to its left without process injection.
- **Fixed-Width Menu Bar Readout:** Monospaced live readout in the macOS menu bar displaying CPU %, RAM usage, and upload/download network speeds with zero horizontal text jitter.
- **Latched System Alerts:** Monitors battery thresholds, low disk storage, and sustained runaway CPU load with hysteresis latching to eliminate notification spam.
- **Hardware Battery Health:** Direct read of `AppleSmartBattery` IORegistry data: cycle counts, nominal vs design capacity (mAh), temperature in °C, and historical charge graphs without privileged helper daemons.
- **macOS Space Indicator:** Displays the current active Space / Desktop number using SkyLight APIs (excluding full-screen app spaces).
- **Hardware Privacy Indicators:** Live notch badges indicating when the microphone or camera is in active use.
- **Privacy-Safe Camera Mirror:** Instant mirror preview in the notch (`AVCaptureVideoPreviewLayer`). Built with guaranteed privacy: zero capture outputs exist in the session, and the hardware camera indicator is lit only while the preview layer is visible.
- **Local Notification Mirroring:** Mirrors system notifications into the notch by monitoring Apple's local notification database (`usernoted`), reading metadata without network transmission.

---

### 11. On-Screen AI Assistant

- **Notch Chat Assistant:** Fast conversational assistant in the notch supporting Google Gemini and OpenAI models.
- **Keychain Credential Storage:** API keys reside in the macOS Keychain (`com.arronlingham.Anchor.gemini`) and transmit via request headers (`x-goog-api-key`), preventing credentials from leaking into URLs or proxy logs.
- **Dynamic Model Enumeration & Failover:** Discovers available models dynamically and supports seamless failover across multiple API keys.
- **Safety-First Architecture:** Pure text-response interface without autonomous shell execution or unconfirmed tool access.

---

### 12. Lock Screen Widgets & Live Activities

- Replicates Dynamic Island widgets on the macOS Lock Screen:
  - **Weather Widget:** Live forecast and temperature.
  - **Calendar & Reminders:** Upcoming events and checklist items.
  - **Countdown Timer:** Live countdown with circular progress ring.
  - **Immersive Media Player:** Album artwork and playback controls on the lock screen.

---

## ⌨️ Keyboard Shortcuts Reference

| Shortcut | Action | Description |
|---|---|---|
| <kbd>⌥</kbd> <kbd>Space</kbd> | **Toggle Launcher** | Open Spotlight-style app and shortcut search |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd> | **Push-to-Talk Dictation** | Hold to speak, release to paste transcript |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>C</kbd> | **Clipboard History** | Open searchable clipboard history panel |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>⌘</kbd> <kbd>V</kbd> | **Paste Plain Text** | Paste clipboard contents stripped of formatting |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>P</kbd> | **Pick Color** | Open system eyedropper and copy color code |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>I</kbd> | **Toggle Notch** | Expand or collapse the Dynamic Notch |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>K</kbd> | **Pin Notch** | Pin notch open (prevents auto-closing on hover out) |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>H</kbd> | **Toggle Sneak Peek** | Cycle or toggle contextual sneak peek micro-HUD |
| <kbd>⌃</kbd> <kbd>`</kbd> | **Toggle Terminal** | Open embedded dropdown terminal in the notch |
| <kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>T</kbd> | **Demo Timer** | Quick-start a preset countdown timer |
| <kbd>⌥</kbd> <kbd>Tab</kbd> | **App Switcher** | Open ring-style application switcher |
| <kbd>⌥</kbd> <kbd>⇧</kbd> <kbd>Tab</kbd> | **App Switcher (Reverse)** | Step backward in ring application switcher |
| <kbd>⌥</kbd> <kbd>⌘</kbd> <kbd>M</kbd> | **Toggle Menu Bar** | Show or hide collapsed menu bar items |
| <kbd>⌘</kbd> <kbd>,</kbd> | **Settings** | Open comprehensive Anchor Settings window |
| *Configurable* | **Window Snapping** | 16 snap zones (halves, thirds, quarters, maximize) |
| *Configurable* | **Audio Tools** | Cycle output devices, mute all microphones |
| *Configurable* | **Clean URL** | Strip tracking parameters from clipboard URL |

---

## 🛡️ System Permissions & TCC Grants

Anchor utilizes native macOS APIs without kernel extensions. Specific features require explicit permissions in **System Settings › Privacy & Security**:

| Permission | Purpose | Features Dependent on Grant |
|---|---|---|
| **Accessibility** | Window management, key monitoring, synthetic paste | Dictation text injection, Ring App Switcher, Window Snapping, Focus-Follows-Mouse, Key Debounce |
| **Microphone** | Audio input capture | Voice Dictation (<kbd>⌘</kbd> <kbd>⇧</kbd> <kbd>D</kbd>), Microphone monitoring |
| **Audio Capture** | CoreAudio process taps | Per-App Volume & Mute control, Per-App EQ, Real-time Audio Visualizer |
| **Calendar & Reminders** | EventKit database access | Calendar tab, Lock Screen calendar & reminder widgets |
| **Bluetooth** | `IOBluetooth` device queries | Bluetooth headphone battery reporting and status |
| **Full Disk Access** | Reading local system databases | Notification Mirroring (`usernoted` SQLite database) |
| **Camera** | `AVCaptureSession` video preview | Camera Mirror preview (guaranteed zero recording output pipelines) |

---

## 🛠️ Building & Installation

### Release Build (Signed)

```bash
xcodebuild -project Anchor.xcodeproj -scheme Anchor \
  -configuration Release -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY="Apple Development: arronlingham@icloud.com (Q4FNFX8QSH)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=KLWHJX56T3 \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

Deploy to `/Applications`:

```bash
ditto <build-path>/Anchor.app /Applications/Anchor.app
open -a /Applications/Anchor.app
```

### Debug Build (Local Development)

```bash
xcodebuild -project Anchor.xcodeproj -scheme Anchor \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" build
```

> [!WARNING]
> **Sparkle Updater is deliberately disabled.** Anchor's update channels point upstream to Atoll's feed; running a live updater would overwrite Anchor with upstream builds. Do not re-enable it.

---

## 📂 Repository Structure

```
Anchor/
├── AnchorApp.swift                 # App entry point, lifecycle, and manager bootstrap
├── ContentView.swift               # Dynamic notch view coordinator and layout
├── AnchorViewCoordinator.swift     # Notch states, tab navigation, and peek management
├── Managers/                       # Feature controllers and background managers
│   ├── Assistant/                  # AI assistant, Keychain credentials, OpenAI/Gemini protocols
│   ├── Audio/                      # Audio route tools, mic pin, Bluetooth monitoring, lyrics translator
│   ├── Battery/                    # IORegistry battery health, history tracking, activity monitors
│   ├── ClaudeUsage/                # Claude Code transcript watcher, limit parser, ntfy push, auto-resumer
│   ├── Clipboard/                  # Clipboard manager, history popover, plaintext & URL tools
│   ├── Dictation/                  # SpeechAnalyzer engine, audio capture, synthetic keystroke injection
│   ├── Display/                    # Multi-display coordination, external pill geometry, DDC/CI, spaces
│   ├── HUD/                        # OSDUIHelper suppression, inline HUD, circular & vertical HUDs
│   ├── Input/                      # Ring app switcher, key debounce, snippets, focus-follows-mouse
│   ├── Launcher/                   # DP fuzzy matcher, cryptex scan, frecency history, shortcuts
│   ├── LockScreen/                 # Lock screen replica panels, weather, timer, and music widgets
│   ├── Media/                      # Media controllers, album art service, vinyl widget window
│   ├── Productivity/               # Apple Notes sync, to-do list, file shelf, terminal, eye break
│   ├── System/                     # Menu bar shrinker, fixed-width stats readout, alert latching, cleaner
│   └── Tools/                      # Window snap zones, eyedropper color picker, DMG installer, uninstaller
├── Components/                     # SwiftUI views and interface components
│   ├── Battery/                    # Battery health view, historical charge graphs
│   ├── Calendar/                   # Calendar tab and reminder overlays
│   ├── Clipboard/                  # Clipboard history panels and popovers
│   ├── Downloads/                  # Download progress live activity
│   ├── Launcher/                   # Search panel, 7x4 application grid, wallpaper blur
│   ├── Live activities/            # Notch live activities (dictation, alerts, DND, Claude usage)
│   ├── LockScreen/                 # Lock screen widget views and immersive player
│   ├── Music/                      # Notch home player, synced lyrics list, waveform scrubber
│   ├── Notch/                      # Notch shape contours, pill framing, tab views
│   ├── OSD/                        # Inline, circular, and vertical HUD views with drag-to-set
│   ├── Settings/                   # 24 modular settings panes and search index
│   ├── Timer/                      # Ruler timer picker and live activity
│   └── Vinyl/                      # Desktop vinyl record and playback controls
├── Audio/                          # Pure Swift audio DSP and CoreAudio process tapping
│   ├── AudioTap.swift              # CoreAudio tap for real-time waveform and spectrum analysis
│   ├── PerApp/Engine/              # Process taps, aggregate devices, soft limiting, crossfading
│   ├── PerApp/EQ/                  # 10-band biquad parametric equalizer
│   ├── PerApp/AutoEQ/              # AutoEQ and oratory1990 profile loader and parser
│   └── PerApp/Loudness/            # ISO 226 contour and K-weighting dynamic loudness compensator
├── MediaControllers/               # Bridges for Apple Music, Spotify, YouTube Music, MediaRemote
└── Models/                         # Data structures, user defaults registry, and shortcut constants
```

