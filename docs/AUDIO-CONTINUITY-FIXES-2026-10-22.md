# Audio continuity fixes — October 22, 2026

This implements the confirmed defects and recovery improvements from
[AUDIO-CONTINUITY-RESEARCH-2026-10-22.md](AUDIO-CONTINUITY-RESEARCH-2026-10-22.md).
It does not establish that every reported audible interruption had the same cause.

## Changes

- Classic playback meters every channel of the actual tap, including right-only
  stereo, and excludes hardware microphone buffers from tap selection.
- Startup and unmute use a continuous 40 ms sample ramp. The first audible buffer
  is no longer discarded, and musical silence does not repeatedly re-arm a gate.
  Output streams replay the same gain trajectory and advance it once per cycle.
- Both local playback engines use the same bounded, preallocated frame queue.
  Equal-size delivery is zero-copy with no added queue delay. Surplus frames carry
  into later packets instead of disappearing. Real starvation still produces
  silence; the counters record it. Queue overflow is bounded and counted.
- Each classic IOProc owns its queue/fade state for its entire life, including
  crossfade promotion. Muting discards queued old samples before unmute.
- Classic setup checks Float32 tap/output formats and matching rates before I/O
  starts. Unsupported contracts fail back to normal app playback; this is not a
  sample-rate converter. The native empty-tap metadata probe on this Mac reported
  48,000 Hz, two channels, 32 bits, eight bytes/frame, format flags 9.
- Unity, flat, unmuted apps pinned to the current default output bypass the classic
  engine. The saved pin survives, and all relevant apps are re-evaluated when the
  system default changes. Gain/mute are set before activation begins.
- The classic device monitor observes nominal-rate changes on all output devices,
  with the existing event debounce, and rebuilds affected controllers with fresh
  rate-specific processors. No polling loop was added.
- EQ settings with unchanged normalized gains reuse their filter setup. Boosted
  EQ reserves headroom based on the combined cascade response plus a 0.5 dB margin;
  initial headroom is seeded before playback and live changes are smoothed.
  Boosted EQ may therefore sound quieter than the former saturating output.
- Classic callbacks now use direct HAL invocation. Earlier hardware measurements
  found both queued and direct callbacks had real-time scheduling; this change is
  a simplification, not a separately proven dropout cure.
- Both engines collect only continuity/timing metadata. Joined teardown logs cycle
  counts, mismatches, missing frames, overflows, maximum packet sizes, callback
  gaps and render duration. Classic logs also confirm non-silent tap cycles.
  No audio recording or background diagnostic timer is added.

## Automated validation

- `bash tests/audio_diagnostics/run_audio_continuity_probe.sh`: 44 checks, compiling
  current production queue, mapper, fade, format predicates, routing predicates,
  EQ and advanced mixer renderer. Includes 1,000 variable packets with exact
  stereo sample-order comparisons, overflow bounds, starvation, right-only stereo,
  startup/unmute, quiet passages, split-channel outputs, multiple output streams,
  preferred channel pairs, mono mapping and sustained boosted-bass processing.
- Existing DSP: 55/55.
- Existing crossfade math: 45/45.
- Existing device checks: 27/27.
- Existing AutoEQ math: 30/30.
- Existing loudness math: 23/23.

Total: **224 checks**. These arithmetic/layout checks do not certify a listening
result or every device/clock configuration. Independent-clock drift policy is
unchanged. AirPlay's separate network rendering path is unchanged.

## Installation and live verification

- Signed Release build succeeded. Deep strict signature validation and Info.plist
  validation passed. The built and installed executable SHA-256 is
  `40537d859406fdb637cf0430682f4bf8ab9f91f765c61bc7539d902aeb119337`.
- `/Applications/Anchor.app` launched and its live controls were exercised.
- Classic playback: a 170-second segment with gain changes and Bass Boost
  completed 15,920 callbacks (15,844 carrying non-silent input). All 512-frame
  packets matched, with zero missing/discarded/invalid frames and zero callback
  gaps over 1.5 cycles. Maximum gap was 11.213 ms; maximum callback work was
  0.241 ms against a 10.667 ms cycle. An earlier 254-cycle segment was also clean.
- Classic preferences were restored, including removal of the temporary test
  app settings. Both user audio controls began disabled.
- Volume mixer: its UI was exercised at 80% and restored to 100%, including with
  a distinct native `AudioPlaybackFixture.swift` app. That mixer identifies regular
  app owners, so a terminal-launched `afplay` process alone is insufficient evidence
  that its gain engine engaged. Its teardown counters were not recovered from the
  system log, so the classic callback timing result must not be attributed to it.
  A 20-second mixer/fixture session averaged 1.88% CPU and 32.5 MB RSS.
- Exact classic settings were compared against the pre-test backup and matched
  (`enablePerAppAudio`, `showPerAppVolumeControl`, `perAppAudioStates`). Mixer was
  restored disabled and saved app volumes matched their original values. The
  playback fixture was stopped and the installed app remains running.
- A 20-second classic active sample averaged 2.11% CPU. Startup transients were
  present (94-second uptime), so this is not a steady-state idle comparison.
  Before the change, the long-running app averaged 0.05% idle CPU and 19.1 MB RSS.
- Final 20-second idle sample, with test features off and windows hidden: mean
  CPU 0.14%, median 0.00%, p90 0.48%; mean RSS 49.7 MB, maximum 64.2 MB. This follows
  recent launches and both settings interfaces being loaded, unlike the long-running
  before sample; it is not a controlled memory/performance improvement claim.

Synthetic playback and callback metadata do not certify subjective listening
quality. Continuous music through the user's original app remains the final
confirmation of the reported symptom.
