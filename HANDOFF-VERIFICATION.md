# Anchor handoff verification — 14 September 2026

The handoff overstated completion. The initial code built, but storage had data-loss/recovery defects, settings could not assign individual menu icons, and phone access existed only in the roadmap. The working tree now contains the fixes below. The changes were subsequently installed in `/Applications/Anchor.app` as part of the external-pill fix, with the same signing identity and a backup of the previous app and data. No personal Reminders list was connected during verification.

| Request | Findings and changes |
|---|---|
| Always-hidden menu icons | The second divider existed, but settings only showed/revealed it. Added an Accessibility-based icon chooser with Visible, Hidden and Always hidden choices. It performs macOS Command-dragging and verifies the resulting section. Icons are temporarily revealed while arranging; auto-hide is suspended until arrangement ends. Enumeration runs off the main thread. |
| Automatic launcher sizing | Manual row/column controls were removed. Fixed small-container fallback, row spacing, keyboard-column updates when the grid shape changes, page clamping after content changes, and synchronization of swipe paging with the selection. Inspected 1440×900 and 860×560 renders; tested additional wide and portrait sizes. |
| Custom due dates | Calendar controls exist for drafts and existing tasks, including right-click → Due Date → Custom Date. Corrected the popover's attachment for completed tasks and committed today's highlighted selection when Done is pressed. Presets use end-of-day rather than making a task overdue at midnight. |
| Durable task storage | Fixed the mismatch between ISO-8601 disk encoding and numeric date decoding. Removed startup merging with stale preferences and the behavior that resurrected deleted tasks from nonempty backups. Added versioned snapshots, an atomic synchronized journal, primary-file replacement, previous-edit backups, and 30 daily snapshots that retain their first pre-edit state. Errors are visible, an unreadable store is protected from edits, damaged originals survive automatic fallback and explicit recovery, and export/import/restore controls are available. File locks and revision checks reject stale concurrent writers. |
| Completed-task recovery | Completion previously removed a task from disk and kept only one in-memory undo record. Completed tasks now remain persisted. Undo changes completion fields without replacing newer title/date edits. Manual reordering accounts for completed items. |
| Two-level sorting | Primary and secondary criteria and independent directions are implemented. Existing tests cover priority, date added, due dates, both directions, secondary tie breaking, and undated items remaining last. Settings are reactive and the redundant secondary choice is excluded. |
| Add/complete tasks on iPhone | Added optional two-way Apple Reminders synchronization for a selected list. Tasks, completion, titles, priorities and due dates are merged against a saved baseline. Independent offline edits are retained; Anchor wins a same-field conflict. Local storage is saved before outbound changes. Failed/empty fetches do not clear the list. |

## Phone setup

1. Create a dedicated list in the **iCloud** section of Apple Reminders, such as “Anchor Tasks”. Enable iCloud Reminders on the Mac and iPhone with the same Apple Account. [Apple's setup instructions](https://support.apple.com/guide/icloud/set-up-reminders-mmbf52194b5a/icloud).
2. In Anchor → Settings → To-Do → iPhone Access, choose **Load Reminders Lists** and allow access.
3. Choose that list and enable **Sync with Reminders**. Existing tasks in the selected list are imported, and local tasks are added to it.
4. Add and complete tasks in that list in Reminders on the iPhone. Anchor syncs on task changes, EventKit notifications and app activation; **Sync Now** provides a manual retry. Anchor must be running to bridge changes to its local store, and iCloud controls cross-device delivery timing.

Deleting a task in Reminders retains its local Anchor copy, because a missing EventKit result can also be transient. Use completion to update status on both devices. Deleting locally removes the remote task only if the phone has not concurrently edited it; otherwise its edited version is kept.

Apple Notes task sync was not implemented in the handoff. The installed Notes scripting dictionary exposes note text but no native checklist completion property, so its promised native-checkbox two-way bridge could not be verified. The implemented route uses Apple's supported [Reminders read/write access](https://developer.apple.com/documentation/eventkit/ekeventstore/requestfullaccesstoreminders(completion:)). The other mobile pathways in `features.md` remain proposals.

## Verification

- Debug application build: passed.
- Release application build: passed. Both builds used code signing disabled; the installed application was not replaced.
- 64/64 storage, sync-planning and adaptive-layout checks passed (`tests/run_todo_storage_tests.sh`). Includes a real SIGKILL during writes, recovery from an interrupted journal/primary replacement, corrupt-file fallback, explicit restore, legacy date formats, empty-list persistence, duplicate IDs, stale concurrent writers, offline edits, additions, completion and deletion conflicts.
- 49/49 existing to-do checks passed.
- 402/402 launcher paging checks passed.
- 27/27 launcher search/calculator checks passed.
- 10/10 privacy-configuration checks passed.
- `git diff --check`: passed.
- Fixture screenshots were inspected for the calendar, task list, narrow settings panes, sorting controls, and two launcher sizes. They are in `build/feature-review/`. The fixture uses an isolated task directory and temporary in-process preference overrides; it does not sync to an account.

## Remaining device checks

- On the signed app, enable the always-hidden section, choose a movable icon, finish arranging, expand the normal hidden section, and restart Anchor. Confirm the selected icon stays hidden. Test moving it back. macOS-fixed controls and inaccessible/off-screen icons cannot be guaranteed movable; the settings report a failure rather than claiming success.
- Open the calendar from the actual notch context menu, move the pointer into it, select a date, and reopen the app to confirm it persists. This checks the live hover/popover interaction beyond the rendered component.
- Connect a dedicated iCloud Reminders list and perform one add/complete round-trip from the iPhone. Also verify an offline edit after reconnection. The merge logic is tested, but no real iPhone/account round-trip was performed here.

The local journal and backups address crashes and file corruption. They cannot guarantee recovery from destruction of the disk itself.
