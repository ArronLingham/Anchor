# Duplicate feature audit — October 28, 2026

## Confirmed remaining work

The original Anchor app and the imported AnchorUtilities library each contain
substantial overlapping functionality. The existing ownership mechanism prevents
some engines from acting at the same time; it does not merge their settings or
data. These are not yet a single implementation:

- Clipboard history uses `ClipboardManager` and `ClipboardHistoryService` with
  separate saved entries, pins, privacy settings and interfaces. The Dashboard
  and notch use the first; Features & Tools uses the second. Ownership switches
  capture, not the contents of the two histories. Consolidation needs a
  reversible migration covering text, images, files, rich text, pins and privacy.
- The Dashboard/notch shelf uses `ShelfManager` and a bookmark-based file store.
  The utility shelf uses `ShelfService`, which additionally holds text, links and
  batches. Their contents and pins are independent. A shared shelf must retain
  these capabilities and migrate both stores without discarding inaccessible files.
- Per-app audio has two separate processing engines and configuration stores.
  Ownership makes them exclusive, but levels, device routing and EQ are not
  synchronized. They have different capabilities and real-time constraints;
  consolidation needs continuity and device testing as well as migration.
- The notch camera mirror and floating utility camera preview have separate
  capture sessions and device choices. They need a shared session and explicit
  presentation lifecycle before their device settings can be unified.
- Switcher, mouse/input tools, snippets, auto-quit, window snapping, URL cleanup,
  disk-image installation and music launch blocking have original and imported
  engines. The integration hands off ownership and restores saved original
  choices, but these are alternatives with independent configuration, not a
  completed removal of duplicate implementations.

Lock-screen calendar, reminder, timer and media controls appear in related
settings pages. Their corresponding controls use the same Defaults keys, so
changing one writes the same stored value. The two calendar sections are still
separate view implementations and should eventually share a component to prevent
presentation and behavior drifting.

The imported island renderer is deliberately retired at startup; native Anchor
owns island presentation. Microphone mute is bridged to a shared backend.

## Clipboard corrections in this change

The native watcher now remains active for any of its consumers and saves history
only when native history is enabled. Utility clipboard history no longer turns
off unrelated native clipboard auto-clear options. The delayed clear has its own
handover; pending native timers are invalidated when it is handed away. Sleep,
display sleep and screen-lock clear observers hand over individually, so a
utility setting for one trigger does not remove the native coverage of the other
two. No existing history is deleted or migrated by this change.

This is a targeted source audit, not a claim that every runtime path or hardware
combination has been exercised. The remaining consolidations above still require
implementation, data migration and live testing.
