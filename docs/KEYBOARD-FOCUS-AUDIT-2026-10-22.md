# Keyboard focus investigation — October 22, 2026

The strongest confirmed candidate is **Launchpad restoring an older app after the
user has already chosen a newer typing destination**. Terminal and clipboard
callbacks have similar stale requests. The command bar also has an insufficient
check that a field really acquired editing focus.

This was expanded to cover app/window activation, nonactivating panels,
responder changes, asynchronous focus requests, global shortcut interception,
clipboard paste, hover focus and Dashboard field identity.

## Evidence and scope

- Active checkout: `/Users/arronlingham/projects/Anchor`.
- At inspection, one installed Anchor process was running, PID 50123, executable
  SHA-256 `b55e323475bdc81c6651ee31e3d5077a5472cc90e56df55cd95672854e61b5dc`.
- No product focus code, preferences or installed binary was changed by this
  investigation. The new files are an audit and diagnostic tools; `.gitignore`
  includes their directory. Existing unrelated checkout changes were preserved.
- A basic UI automation pass entered and retained a temporary draft in the
  Dashboard's **Add a task** field, then cleared it without submitting a task.
  The user's intermittent failure was not conclusively reproduced with physical
  keyboard input. Automation that targets an app can mask real focus routing.
- The source-derived probe reproduced **six existing failure cases**, using the
  actual production methods against an AppKit model. These demonstrate stale
  focus decisions; they are not six end-to-end macOS reproductions or passing
  fix regressions.

## Findings

### 1. Launchpad can undo a newer focus choice — highest priority

`Anchor/Managers/Launcher/LauncherPanelManager.swift:65` calls `hide()` whenever
Launchpad resigns key status. `hide` defaults to restoring the previous app, and
its animation completion activates that app without checking the new key window,
current foreground app, or whether another presentation has since opened.

Three cases were reproduced from the current method:

1. A click chooses the Dashboard field; the resignation callback schedules a
   dismissal; the completed dismissal activates the old app over that field.
2. `LauncherView.swift:503` dismisses before running a selected command. A command
   can open Dashboard or Command Bar, then the older dismissal completion
   reactivates the app that preceded Launchpad. App launches already use
   `restoringFocus: false`; command launches do not.
3. Launchpad is reopened before an older dismissal animation finishes. The older
   completion still reactivates its saved app over the newer presentation.

An explicit Escape/cancel restoring the previous app is valid; the probe includes
that control. The defect is using the same unconditional restoration after a new
focus choice or command destination.

**Fix:** distinguish cancellation, resignation and command execution. Restore only
for explicit cancellation while the original focus intent is still current.
Invalidate older completion tokens when another panel/window/app is selected.

### 2. Terminal retries can take typing away from a later click

`Anchor/Managers/Productivity/TerminalManager.swift:580` retries after 50 ms if its
view is not mounted, and retries a failed responder request. A later retry can
activate Anchor, raise the terminal window and set its first responder without
checking that Terminal is still the requested destination or visibly selected.
`NotchTerminalView.swift:199` requests this on appearance; disappearance does not
cancel the request.

The probe starts a pending mount, supplies the window, changes the user's typing
destination to Dashboard, and observes the production retry override it.
Terminal is currently enabled, making this a relevant conditional path.

**Fix:** tie retries to an explicit presentation/request token; cancel on tab
changes/disappearance, and require the same visible window and current intent.
A view mounting or being preloaded is not permission to activate the app.

### 3. Clipboard panel has an unguarded delayed key-window claim

`Anchor/Managers/Clipboard/ClipboardPanelManager.swift:63` schedules another
`panel.makeKey()` 100 ms after opening. It does not verify that the panel is still
current and visible or that the user has not clicked another field. The probe
reproduced this later claim overriding a Dashboard selection.

The asynchronous authentication path also presents the panel after authentication
without checking whether that presentation request was superseded. That second
path was inspected but was not exercised with authentication.

The background clipboard feature is currently disabled; this is not evidence that
it caused the reported incident. Explicitly opening its panel can still reach it.

**Fix:** cancel stale authentication/presentation requests, and remove or constrain
the delayed key claim to the original window and user intent.

### 4. Command Bar can report a successful field focus without an editor

`Packages/AnchorUtilities/Sources/AnchorUtilities/Services/CommandBar/CommandBarService.swift:518`
returns `window.makeFirstResponder(field)` as its success check. Apple documents
that this can return true even when the requested responder refuses and the
window itself becomes first responder. It also treats any current field editor
as sufficient, without confirming that it belongs to this search field.
[Apple: makeFirstResponder](https://developer.apple.com/documentation/appkit/nswindow/makefirstresponder(_:)).

The probe models the documented fallback and the production helper reports
success although its first responder is the window. Early queued keys can then
be delivered under an incorrect readiness assumption. This proves a gap in the
helper's contract, not that the installed search field refused on a particular
user click.

**Fix:** identify the intended editable field and verify its actual current
editor/responder and key-window state. Keep early keys associated with the same
visible presentation until that exact editor is ready. Guard deferred SwiftUI
focus work by visibility and presentation identity as well.

### 5. Delayed paste can target a different app or field

Two source-confirmed paths post a global synthetic Command-V after a delay without
rechecking the destination:

- Command Bar clipboard paste: `CommandBarService.swift:2833`, 150 ms plus a
  modifier-release wait and a 60 ms settle delay. It checks secure input but
  never carries the original destination through those waits.
- History window paste: `Services/Clipboard/ClipboardHistoryService.swift:1351`,
  120 ms after activating its saved app, followed by an untargeted global paste.

If the user selects another window/field during the wait, the eventual paste can
reach that newer destination. No real clipboard content or synthetic paste was
used to test this; it is a control-flow finding independent of the six probes.

**Fix:** retain the intended keyboard destination and copy operation identity;
abort if either changes before dispatch. Checking only the foreground app is not
enough: nonactivating panels can own typing while another app remains active.

### 6. Other stale requests to include in the same repair

These were found by inspection and not reproduced end to end:

- `Anchor/Components/Settings/SettingsWindowController.swift:194` queues an
  unconditional later `makeKeyAndOrderFront`. It needs a current presentation and
  visibility check so an older show cannot override a newer destination.
- `Services/Notch/NotchWindowHost.swift:437` restores key status after a Mission
  Control frame change using the earlier key state. It should not restore it if
  another window deliberately acquired focus in the meantime.

## Checks that narrow the cause

- Both focus-follows-mouse paths are currently disabled. The feature can redirect
  focus by design when enabled, but it is not the leading explanation here.
- Native key debounce and text snippets are disabled; the corresponding utility
  features are unavailable/off. They do not explain plain letters being swallowed
  in the inspected configuration.
- The native system-shortcut handler limits interception to its configured
  Command-Space/Command-Tab combinations; it does not swallow arbitrary typing.
- Native app-switcher activation retries already check that the expected app is
  still foreground. These are better guarded than Launchpad's restoration.
- Dashboard card/row identities use stable enum values, not freshly generated
  UUIDs. No random identity reset was found in the inspected task field path.
- Dashboard field views use ordinary SwiftUI fields. There was no source evidence
  that the task field itself intentionally redirects letters elsewhere.
- Ordinary HUD presentation has no matching explicit keyboard-focus claim in the
  inspected managers. A visible overlay alone does not establish a focus thief.

## Repair order and verification

Repair Launchpad restoration first, then terminal/clipboard retries and the
command-bar editor check. Apply the same request-generation rule to Settings and
Mission Control restoration. Guard delayed paste destinations independently.
Use cancellation and existing window/focus notifications; do not add a focus
poller or repeatedly force focus back to a field.

Convert the six source-derived cases into desired-behavior regressions. Then
verify actual mouse clicks and physical typing across Dashboard, Launchpad,
Command Bar, Terminal, clipboard, another app, and rapid open/close/reopen. Include
cold startup, animated presentations, alternate input methods and accessibility
keyboard use. The intermittent symptom is resolved only after that live behavior
is verified, not merely because a focus helper returned true.

Diagnostic sources are under `tests/focus_diagnostics/`. `FocusTrace.swift` records
only focus metadata and exits automatically; it does not record typed content.
