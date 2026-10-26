# Performance pass — 16 October 2026

## Observations

The user reported lag across the Mac, not only within Anchor. Live measurements
showed an 8 GiB machine using roughly 5.9–7.8 GiB of swap, with about 16 GiB of
free space on the Data volume. CPU snapshots remained 62–88% idle. No thermal
or CPU performance warning was reported by `pmset -g therm`.

The two largest Codex renderer processes reported approximately 1.7 GiB and
1.2 GiB in `top`'s MEM column; WindowServer, Outlook, Safari, Brave and Wispr Flow
were also running. These are diagnostic snapshots, not exclusive RAM totals.
Memory pressure fluctuated during app launches and compilation. No other apps
were quit and no system appearance or security preferences were changed.

## Changes

- Shared dark cards use shaded fills and edge lighting instead of one live
  backdrop filter per card. Card shadows are smaller and apply to the simple
  shape; small raised/inset controls no longer use dual blurred shadows.
- Battery, task/display status and notices are separate Dashboard views. Hardware
  changes no longer invalidate the root Dashboard and all its cards. Tab changes
  no longer animate replacement of the entire card hierarchy.
- Dashboard audio notifications consume the values already read by CoreAudio.
  Audio capabilities update only on route changes, display enumeration only on
  display changes. Slider writes no longer call the full hardware refresh.
  Unchanged values are not published and repeated starts are idempotent.
- Settings caches its static search index and builds the visible-tab set once
  per query. A query survives automatic pane selection; explicit selection of a
  sidebar pane or search result clears it.
- Liquid-glass views apply style changes only when their values change, retain
  observers when the backdrop layers are unchanged, and stop retrying setup when
  detached instead of rescheduling every 50 ms.

No polling loops or dependencies were added.

## Measurements

`scripts/measure.sh` sampled process CPU time deltas and RSS for 40 seconds
(20 samples each), with no compilation running during the measurements.

| Condition | Mean CPU | Median CPU | p90 CPU | Maximum CPU | Mean RSS |
|---|---:|---:|---:|---:|---:|
| Before, windows closed, no playback | 0.26% | 0.00% | 0.48% | 2.39% | 24.9 MiB |
| Before, General Settings visible, no playback | 0.26% | 0.00% | 0.48% | 1.45% | 26.6 MiB |
| Before, Settings visible during playback | 11.38% | 11.52% | 11.98% | 12.03% | 62.1 MiB |
| After, windows closed, playback paused | 0.31% | 0.00% | 0.48% | 2.88% | 37.2 MiB |

The final sample began 62 seconds after launch, so it is an early regression
check rather than a settled-memory benchmark. The earlier process had been up
for over 15 hours; RSS readings are not directly comparable because of startup,
compression and paging. Idle CPU stayed low, but these samples do not demonstrate
a CPU or memory reduction, nor measure frame latency. Playback and scrolling
profiles were diagnostic, not a controlled frame-rate benchmark.

## Verification

- Signed Release build succeeded; strict deep signature validation passed.
- Built and installed executables matched SHA-256:
  `d6cfaaba3dc98f7b5d64456eb547abcd9df5f3d8f982e0d1c578fc0ecf103ed9`.
- Installed `/Applications/Anchor.app` launched and answered Accessibility queries.
- Settings scrolling, query persistence, result suggestions and pane navigation
  were checked in the live app.
- Volume changed from 22% to 32% and back, and brightness from 56% to 66% and back.
  Each accessibility update changed only the relevant slider/value/label; the
  original hardware values were restored exactly.
- The dark Dashboard appearance was visually checked after reducing effects.
- Previous installed app preserved at `/private/tmp/anchor-performance-before.app`.

Mac-wide relief from closing or restarting the other apps remains dependent on
the user's choice of which active apps may be interrupted. The Anchor changes
do not establish that the Mac-wide slowdown is resolved.
