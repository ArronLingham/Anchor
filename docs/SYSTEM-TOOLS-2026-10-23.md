# System tools and AI recovery — October 23, 2026

## What was already present

Anchor already includes the native Vorssaint v3.4.1 utility engines, attributed in `Packages/AnchorUtilities/NOTICE.md` and `UPSTREAM.json`. The reference checkout at `/Users/arronlingham/projects/vorssaint-utils` is the older fork identified in `VORSSAINT-PARITY-2026-10-19.md`; the released source used for the port remains the comparison baseline. Its source was inspected without modification.

The port already contains SMC CPU/GPU/battery temperature selection, CPU tick deltas, IOKit GPU activity, battery charge/flow/health, kernel memory pressure, network counters, window arrangements/snapping/restoration, cache/log/leftover cleanup, an app uninstaller and keyboard cleaning mode. These implementations were retained instead of adding competing engines. Window layout remains available in Features & Tools; Cleaning Mode already has an Unlock button and five deliberate Escape presses, ignores auto-repeat, and fails open on teardown.

## Changes

### Monitoring

The native Stats tab now leases the same sampler as utility panels instead of running its own CPU/memory/network timer. It displays CPU/GPU load, CPU/GPU/battery temperatures, battery charge and watts, memory pressure, and upload/download rates. Missing readings display a dash or Measuring, not an invented temperature. Stats starts enabled for profiles without an explicit saved choice and reads hardware only while visible.

Closed-panel sampling is off by default. A saved menu-bar pin, alert or accessory preference cannot widen the readings requested by a visible page or keep a timer alive after the last visible consumer leaves. The explicit “Keep monitoring when panels are closed” switch is shared by Monitor and native Menu Bar settings. With it off, native pinned readouts say Stats paused. Background alerts/pins require the opt-in. Independently visible consumers retain their own leases.

Network deltas reset immediately on loss of demand, including short close/reopen cycles. Bytes transferred while hidden do not inflate a reopened speed or monitored-session totals. Hardware and network counters are sampled locally; this does not initiate downloads or capture packet content.

### Cleaner and storage review

Features & Tools → Cleaner retains the existing cache, log, developer-junk and orphaned-app review. Anchor's own cache and bundle-ID families are now excluded explicitly. A manual cleaner scan cancels when its last visible surface disappears, with cancellation checked during folder sizing and category traversal. Deliberately configured scheduled cleanup remains a separate opt-in.

Cleaner → Storage review adds a manual metadata inventory of a chosen folder or disk. It retains at most 200 local files over 100 MB, sorted by allocated size. It skips symbolic links, package descendants, system locations, Library data, source-control internals, Anchor's AI session stores, and ubiquitous/cloud-managed files. Inaccessible paths are counted; there is no promise to bypass macOS permissions or inspect literally every file. No file is labelled unused based on age alone and no personal file starts selected.

Selected personal files require a confirmation before moving to Trash. Before moving, Anchor checks identity plus fresh filesystem size and modification date. URL resource values cached during enumeration are deliberately not reused for this decision. Changed files stay put. The move runs away from the UI thread. Closing/hiding storage review cancels its scan. This tool never empties Trash.

### App deletion and layouts

The existing Uninstaller already handles app bundles, caches, preferences, logs, support folders and supported leftovers, with ownership and file-identity rechecks before removal. The new deleted-app watcher uses filesystem events on the user's Trash while Uninstaller is enabled. New trashed app bundles appear under Recently deleted apps, and a local notification points to review. It does not scan leftovers until Review is pressed, or delete anything on its own. Review refuses suggestions for reinstalled apps and the existing removal-time exclusive-ownership checks remain in force. The trashed app bundle itself is excluded from the leftover removal list.

The watcher has no polling timer and stops when Uninstaller is disabled. Its discovery requires macOS access to Trash; the existing Uninstaller permission controls remain the route for granting needed file access.

### Claude Code and Codex recovery

Settings → AI Usage & Recovery contains the existing Claude Code watcher/resume controls and the new Codex controls. Claude's existing implementation watches transcripts with filesystem events, schedules a reset deadline, guards against sessions that kept working, and resumes only the most recently halted session with its saved prompt.

Codex detection also uses filesystem events and bounded grown-tail reads, with a byte filter before JSON decoding. Only a provider-written usage-limit error qualifies; assistant prose, user messages and tool output do not. Exhausted session/weekly windows determine the latest required reset. The service asks Codex's own account connection only after a detected failure and at recovery; it does not poll the account or buy/redeem reset credits.

At the reset, recovery rechecks the account, the unchanged rollout identity/size, and the latest turn's failed usage-limit status. Completed, interrupted, changed and otherwise failed tasks are skipped. Pending recovery metadata survives restart and is revalidated against the same file identity and size. A persisted, bounded attempt ledger prevents duplicate continuation across restart and limits automatic attempts for a session. A one-shot reset deadline is checked again on wake; a reset missed by more than an hour requires manual continuation.

Recovery resumes the existing thread, preserves its saved configuration, and starts a continuation turn. The process stays alive for that turn. Server approval/tool requests are detected even when interleaved ahead of an RPC reply; Anchor interrupts rather than approving requests or fabricating tool results. Known subagents and threads with desktop-only dynamic tools require continuation in their owning app. This is local Codex-thread support, not automatic control of arbitrary AI websites or desktop-only tool clients.

Phone alerts reuse the existing Keychain-protected ntfy topic. Only a generic provider reset message and delivery time go to ntfy, never prompts, transcripts, project names or account credentials. ntfy can schedule up to three days ahead. Codex uses a one-shot local deadline to enter that delivery window, rechecks on wake/relaunch, and retries failed scheduling up to three times. It cannot guarantee a notification if the Mac remains off/asleep for the entire final three-day window. Phone setup completed on October 23 using iPhone Mirroring: a random topic was saved through Anchor’s Keychain-backed settings and subscribed in the iPhone ntfy app. Two real Anchor test messages were received on the iPhone, including one sent while ntfy was in the background. iOS notification permission, Lock Screen, Notification Center, banners and sounds were verified enabled. The background banner itself was not visually observed. No real AI continuation was sent during tests.

Primary API reference: [Codex App Server](https://learn.chatgpt.com/docs/app-server), including `account/rateLimits/read`, `thread/turns/list`, `thread/resume`, `turn/start`, streamed requests and turn completion. The installed Codex CLI's generated schema was checked as well.

## Validation

- 31 selected package XCTest cases pass: ten system/recovery/cleaning checks, nine integration checks, eleven feature-resource lifecycle checks and the metrics behavior suite (373 assertions).
- Live hardware sampling returned CPU/GPU/battery temperatures, memory pressure, CPU load and network rates; releasing its lease removed the timer.
- A synthetic storage fixture verified link/package exclusion, no preselected files, cancellation, and retention of a changed file. Only generated fixture data was used; no personal cleanup was run.
- A fake Codex server verified that an approval request arriving before the turn-start reply is retained as a reason to stop automatic execution. A second fake-server test verified that cancellation ends a blocked RPC within two seconds.
- Existing native cleanup safety: 92/92; native uninstaller: 16/16; Claude transcript watcher: 7/7. Menu-bar formatting: 28/28; Settings search: 5/5; native snap geometry: 68/68.
- Read-only checks against the installed Codex server successfully read account-limit buckets and the latest stored turn. They sent no prompt and started no turn. Automatic recovery has not been exercised against a real exhausted allowance.
- The optimized, signed Release is installed at `/Applications/Anchor.app` and running as PID 67921. Deep strict signature verification passes (team `KLWHJX56T3`); installed and built executable hashes match: `42c1931e833f60862a5d53516e832261f9e9433a4bf9e35fe559b68a2814c3a8`.
- Installed UI checks passed for AI Usage & Recovery (Codex watch/continuation enabled, Watching status), the Stats enable switch, closed-panel monitoring off, Cleaner → Storage review, its idle/no-selection state and disabled removal action, and Uninstaller. No preferences were toggled during these checks. Window snapping and the keyboard lock were not activated. The compact Stats layout compiled; hardware and lease behavior were exercised through the shared production service tests rather than a physical notch interaction.
- Previous app and private preference backups: `/var/folders/96/05cq_fd555z193zn1cx___j80000gn/T/anchor-system-tools-install.brr2rzc1/`. Release compilation used `SWIFT_COMPILATION_MODE=incremental` with optimized `-O` code; project build settings were not changed.
- The machine-readable receipt is [SYSTEM-TOOLS-VALIDATION-2026-10-23.json](SYSTEM-TOOLS-VALIDATION-2026-10-23.json).

## Performance

Before installation: 20 seconds, 10 observations, mean CPU 0.05%, median/p90 0.00%, maximum 0.48%, mean RSS 37.1 MB. This was the long-running existing app, with Settings retained. Startup and long-running RSS are not comparable; no percentage improvement is claimed. The primary performance evidence is actual timer teardown, shared sampling, bounded scanning, and event-based recovery/deletion discovery.

After installation and UI checks, with panels closed: 20 seconds, 10 observations, mean CPU 0.24%, median 0.00%, p90 0.96%, maximum 1.44%, mean RSS 99.7 MB, maximum RSS 130.6 MB. This recently launched, exercised app and the earlier long-running instance are not a controlled comparison. These measurements do not show an overall CPU or RSS reduction.
