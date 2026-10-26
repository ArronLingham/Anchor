# Launchpad search validation — October 21, 2026

## Regressions

- 61/61 new search checks, including Unicode offsets, aliases, word ordering,
  conservative typo recovery, bounded usage, app/command merging, utility priority,
  explicit quicklinks and stable ties.
- 27/27 existing fuzzy matcher/calculator checks.
- 416/416 existing switcher/Dashboard/launcher visibility/lock-event checks.
- Existing launcher experience checks also passed.
- Total counted checks: 504. This is focused regression coverage, not exhaustive
  proof of relevance for every possible query.

## Curated ranking comparison

A hand-labeled fixture of nine app names and fifteen queries improved from 8/15
correct first results with the previous name matcher to 15/15 with the new ranker.
No usage scores were supplied. This isolates retrieval/ranking behavior; it is not
an A/B test against Spotlight or a representative production relevance benchmark.
The standalone benchmark measured approximately 3.8–4.6 ms per 250-app query under
moderate load, with higher timings during heavy concurrent compilation. It tests
name matching rather than the entire UI or every metadata field.

## Real installed catalog

The Debug diagnostic ran the production AppIndex against 124 apps on this Mac:

```
PASS saf: Safari
PASS safrai: Safari
PASS ss: System Settings, Screen Sharing, Chess, Messages, Passwords
PASS system preferences: System Settings
PASS monitor activity: Activity Monitor
PASS task manager: Activity Monitor
PASS disk utility: Disk Utility
Home excludes search-only utilities: true
Failures: 0
```

Mean AppIndex query time was 30.2 ms in the unoptimized Debug diagnostic during a
concurrent build. This is not a Release latency measurement. The check caught and
helped fix ambiguous utility ordering; a prior run placed Screen Sharing first.

Installed-app accessibility checks on the first Release confirmed Launchpad
opened and returned Safari for `safrai`, Activity Monitor for `monitor activity`,
and System Settings for `system preferences`. They also exposed the previous
commands-before-apps UI policy, prompting the shared-ordering integration.

## Build and deployment

- Final Debug and Release builds succeeded.
- Deep, strict signature verification and Info.plist validation passed.
- Built and installed executable SHA-256 both matched:
  `d99bdd3a4cabd13fd47f9eaac87580467e9c42f39d606d6c53ed748e6e712888`.
- `/Applications/Anchor.app` relaunched successfully (PID 24029 at verification).
- The pre-task installed app is preserved at `/tmp/anchor-search-backup/Anchor.app`.
- Final installed UI: `ss` showed System Settings selected first, followed by
  Screen Sharing and then Show Screenshots. `safrai` selected Safari;
  `monitor activity` selected Activity Monitor before its command equivalent;
  `system preferences` selected System Settings. Return dismissed Launchpad and
  opened the selected System Settings app. No macOS settings were changed.
- Anchor's verification settings window was cleared and closed afterward.

## Performance observations

Two short 20-second samples used the existing process sampler:

| Sample | Mean CPU | Median CPU | p90 CPU | Mean RSS |
| --- | --- | --- | --- | --- |
| Pre-task installed app, long-running | 0.24% | 0.23% | 0.48% | 22.4 MB |
| Final installed app, shortly after UI testing | 0.05% | 0.00% | 0.00% | 157.7 MB |

The final sample began at only 74 seconds of uptime, after rendering Settings and
Launchpad. Its RSS is a startup/UI observation, **not settled memory**. The two
samples have different uptime and workload histories, so they do not establish a
CPU improvement or a memory regression. No new polling loop, background indexing
service, or model process was introduced. A matched-uptime long idle measurement
was not performed.

