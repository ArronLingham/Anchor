# Launchpad shortcuts and presentation

Installed target: `/Applications/Anchor.app`.
Release executable SHA-256: `44dd82b9c1777cd04104a9a0d02142ccb339ca1294d8608ca2c99507c3c5dd08`.

## Behavior

- Opt-in Command-Space replaces Spotlight with Anchor's Launchpad while Anchor runs.
- Opt-in Command-Tab and Command-Shift-Tab invoke Anchor's switcher; releasing Command commits.
- Existing configurable Option-Space/Option-Tab shortcuts remain available.
- Disabling the replacement, its feature, or global shortcuts releases the native binding. No macOS shortcut preferences are changed.
- The native event tap uses the main run loop and adds no idle polling. Switcher modifier release uses event notifications when the tap is available; the existing permission fallback timer runs only while the switcher is open.
- Launchpad uses an apps-first grid with separate Categories and Widgets tabs, a compact search field, restrained selection styling, wrapped saved widget widths, and consistent category tile heights.
- A 90 ms ease-out compositor fade starts after the window is ordered front. Reduce Motion skips it. App indexing and icon warming start before the first opening; widgets are constructed only on their tab.

## Verification

- Signed Release build passed; deep strict codesign verification passed for built and installed bundles, and executable hashes matched.
- 42/42 native shortcut routing checks passed, including reverse cycling, disabled features, unrelated keys, Caps Lock, and extra modifier chords that must pass through.
- Launcher fuzzy matching/calculator tests: 27/27 passed.
- Launcher experience tests passed (stream handling and saved per-display widget profiles).
- Settings search tests: 5/5 passed (363 highlighted rows, 382 entries).
- User physically tested Command-Space and held Command-Tab and confirmed both Anchor interfaces opened correctly. Desktop automation bypasses global event taps, so its synthetic shortcut presses were not treated as physical-key evidence.
- Both replacement settings remained enabled after final restart, and the native HID tap was enabled (event mask 3072).
- Visually checked all three launcher tabs, unclipped widget rows, uniform category tiles, hidden system scroll bars, search, arrow-key result navigation, Return to open Dashboard, and keyboard grid paging.
- Existing unrelated working changes were preserved; nothing was committed or pushed.

## CPU / RSS

Thirty-second baseline on the preceding installed app: CPU mean 0.58%, median 0.48%, p90 1.42%, maximum 1.92%; RSS mean 25.7 MB, maximum 37.1 MB (14 samples).

The post-update sample starts 68 seconds after launch and is a diagnostic check, not a stabilized comparison with the baseline. Do not infer a CPU reduction from these short samples.

Post-update, All Apps tab open with both replacements enabled: CPU mean 0.13%, median 0.00%, p90/maximum 0.48%; RSS mean 169.3 MB, maximum 184.5 MB (15 samples). Startup timing and macOS memory compression make the RSS figures unsuitable for a before/after claim.
