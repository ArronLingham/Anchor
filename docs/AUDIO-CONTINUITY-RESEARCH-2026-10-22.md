# Audio continuity investigation — October 22, 2026

## Initial investigation outcome

Implementation and subsequent verification are recorded in
[AUDIO-CONTINUITY-FIXES-2026-10-22.md](AUDIO-CONTINUITY-FIXES-2026-10-22.md).

The reported symptom is **continuous choppiness on the MacBook speakers when
Anchor audio control is enabled**. There are reproducible defects in the classic
processing path, but the exact cause of that reported symptom is **not yet proven**.
The output-only hardware probe did not reproduce sustained dropouts. Both audio
controls were disabled when inspected, and the specific control involved is not
known. Production code, audio preferences, and the installed app were left intact.

## Verified environment

- Installed app and this checkout's Release executable match SHA-256
  `d99bdd3a4cabd13fd47f9eaac87580467e9c42f39d606d6c53ed748e6e712888`.
- Default output: MacBook Air Speakers, built-in transport, two channels, 48 kHz.
- Hardware buffer: 512 frames, giving a 10.667 ms nominal cycle.
- Default input: MacBook Air Microphone, 48 kHz. No Bluetooth output was listed.
- A user Multi-Output Device exists with reported rate zero, but is not the
  current default. Its existence alone is not evidence of the cause.
- `enablePerAppAudio = false`; advanced `featureAvailable.mixer = false`.
- Saved classic state includes Safari at approximately 40% gain; Brave at unity,
  EQ disabled, explicitly routed to BuiltInSpeakerDevice; Spotify at unity with
  EQ enabled and bass bands boosted by +6/+6/+5 dB, also pinned to the speakers.
  These are saved choices, not proof of which app was playing during the fault.
- A targeted ten-minute log query found no retained matching overload/underrun
  messages. An empty query does not establish that no dropouts occurred.

## Two engines, requiring separate diagnosis

The Media setting **Per-app volume, mute and EQ** uses
`Anchor/Audio/PerAppAudioManager.swift` and `ProcessTapController.swift`, derived
from [FineTune](https://github.com/ronitsingh10/FineTune).

The Features & Tools **Audio Mixer** uses the separate `AppVolumeMixer` and
`MixerRender` inside `Packages/AnchorUtilities`, derived from Vorssaint. It already
uses direct callbacks, format-aware channel mapping, and a lookahead limiter.
Ownership handling pauses classic audio control when the advanced mixer takes
over. No evidence was found that both engines were engaged in this inspection.
A defect in the classic engine must not automatically be attributed to the mixer.

## Findings and evidence

### 1. Callback dispatch contract needs clarification; no dropout cause verified

Classic engine registrations at ProcessTapController lines 684, 1061, and 1236
supply a serial user-initiated dispatch queue. Its comment says callbacks run on
the HAL thread rather than that queue. That wording should distinguish physical
thread identity from dispatch-queue context. The installed Apple SDK's
`CoreAudio.framework/Headers/AudioHardware.h` explicitly documents synchronous
dispatch onto a supplied queue and direct invocation for a nil queue.
[Public API reference](https://developer.apple.com/documentation/coreaudio/audiodevicecreateioprocidwithblock(_:_:_:_:)).

The output-only native probe verified every queued callback ran in the queue's
specific context, while direct callbacks did not. However, a thread-policy query
showed the **same real-time timing policy in both modes** on this Mac. A
synchronous queue dispatch can run inline on the calling thread; queue context
alone does not prove a physical thread hop or lost real-time scheduling. Four warmed
trials had zero callback gaps over 1.5 cycles. p99 gaps were approximately
10.71–10.83 ms, and maximum gaps 10.74–10.85 ms.

An earlier un-warmed trial had a 37.35 ms queued gap. This was not repeated after
warm-up and must not be presented as proof of sustained failure or a reliable A/B
performance improvement. Passing nil simplifies the callback path, but is not a
proven cure. The standalone probe renders silence in its own output client; it
does not exercise Anchor's aggregate, capture an app, or run its DSP.

Apple explains that missing an audio cycle deadline produces glitches, and that
framework-owned real-time threads receive workgroup treatment in
[Meet Audio Workgroups](https://developer.apple.com/videos/play/wwdc2020/10224/).
Low total app CPU alone does not establish deadline safety.

### 2. Right-only interleaved stereo is incorrectly classified as silence

The classic callback's peak loop steps by the channel count. For an interleaved
stereo buffer, it reads only the left channel. That peak controls the output gate
for **both** channels.

Compiling the actual current peak loop and gate methods with a right-only
0.25-amplitude stereo fixture produced:

```
Actual peak: 0.25
Detected peak: 0.0
Gate gain after 100 buffers: 0.0
```

This is a confirmed defect for that layout: audible right-channel content can be
silenced. It is not proof that the live built-in speaker tap uses that exact
layout or that the user's music had this channel pattern.

The gate also deliberately discards the first non-silent buffer and uses a single
fade gain for each subsequent buffer. At 512 frames/48 kHz, that first discarded
buffer represents 10.67 ms. Observed startup gains were:
`0, 0.1654, 0.5523, 0.9045, 1, 1`.
A continuous left-channel fixture remained at gain 1 after startup, which argues
against blaming gate re-arming for truly uninterrupted centered audio. Short
pauses, asymmetric stereo, or upstream starvation could still expose it.

### 3. Unequal buffer lengths lose continuity

The classic production mapper renders `min(inputFrames, outputFrames)` and has
no carry-over FIFO. Extracting and compiling that exact method with processors
nil and the real SoftLimiter gave:

| Input frames | Output capacity | Observed result |
| --- | --- | --- |
| 512 | 512 | All 512 frames preserved |
| 256 | 512 | 256 frames replaced by silence |
| 1024 | 512 | 512 input frames not retained |

This confirms conditional sample loss, **not** that a size mismatch happened in
the user's session. The advanced mixer's basic render path also bounds output by
available source frames; its existence is not a complete answer to rate/packet
mismatch. Actual tap/output frame sizes and timestamps must be measured before
introducing buffering or sample-rate conversion.

Both current callback wrappers ignore the supplied input/output timestamps, so
there is no existing accounting that can establish continuity from these callbacks.

### 4. Saved unity settings can still engage interception

Classic `needsProcessing` returns true for any explicit output UID, even when
that UID is the current default and volume/EQ/mute require no processing. Brave's
saved settings meet that condition. Consequently, enabling the feature can put
an otherwise unchanged app through tap/aggregate playback.

A safe bypass for equivalent routing should preserve the user's pin and
re-evaluate all relevant apps when the default changes. Merely skipping creation
would be insufficient: the current default-change handler only re-syncs existing
controllers.

Spotify's positive EQ can additionally exhaust headroom. A soft saturation stage
prevents unbounded peaks but cannot guarantee transparent sound. Compare flat EQ
at unity before treating a boosted preset as evidence of transport dropouts.

### 5. Device rate recovery is incomplete in the classic integration

AudioDeviceMonitor's rate listeners are limited to Bluetooth outputs. Its
`onBTDeviceSampleRateChanged` callback is not wired by PerAppAudioManager. Built-in
or wired format/rate changes therefore need additional consideration. This is a
recovery gap; the inspected speakers remained at 48 kHz, so it is not a verified
cause here.

Apple's [aggregate-device guidance](https://support.apple.com/en-ge/guide/audio-midi-setup/ams094c7edb4/mac)
recommends compatible sample rates and appropriate synchronization. Do not simply
disable drift correction everywhere: independent clocks can drift even at equal
nominal rates. The clock source and actual tap format should determine policy.

## Recommended improvement sequence

1. **Instrument a live reproduction first.** For each active engine, collect only
   counters/metadata: input/output frames and layout, missing buffers, discarded
   frames, gate transitions, callback duration/gaps, sample rate, and route/rebuild
   events. Preallocate storage; summarize outside the callback. No user audio needs
   to be recorded. Compare the same app, same speakers, same volume with control
   off, gain-only control on, and then EQ on.
2. **Fix confirmed gate/channel defects.** Calculate peaks across all mapped
   channels; use sample-continuous ramps rather than whole-buffer gain steps;
   avoid throwing away a complete first buffer; constrain soft-start to intended
   transitions rather than repeatedly suppressing valid music.
3. **Enforce a render contract.** Validate Float32 format/layout and rates during
   setup; handle variable delivery with a bounded preallocated FIFO only where
   measurements require it; preserve fractional conversion state and timestamps
   for true rate conversion. Count and surface underruns instead of concealing
   every short buffer with unexplained silence.
4. **Reduce unnecessary processing.** Bypass unity/flat/unmuted apps on equivalent
   routes; preserve route intent across device changes. Avoid redundant EQ setup
   rebuilding for unchanged settings and provide preamp headroom for positive EQ.
5. **Simplify and test lifecycle/timing.** Consider direct callbacks, retain all
   non-render work outside the callback, wire rate changes, and consolidate common
   correctness tests across the two engines. Validate sustained playback, not
   only successful tap creation or a passing arithmetic test.

Increasing the hardware buffer blindly is not the first recommendation. It may
mask scheduling problems while adding latency, and cannot repair channel selection
or dropped-frame logic.

## Reproduction tools and checks

- The original `run_audio_continuity_probe.sh` extracted production methods to
  reproduce the pre-fix defects. It has since been converted into the 44-check
  regression suite described in the implementation report.
- `swiftc -O tests/audio_diagnostics/audio_callback_timing.swift -o /tmp/anchor-audio-callback-probe`
  then `/tmp/anchor-audio-callback-probe` runs four short output-only timing trials.
  It writes silence only to its own output buffers and does not change preferences.
- Existing DSP checks: **55/55 passed**.
- Existing crossfade checks: **45/45 passed**.
- These checks do not prove dropout-free end-to-end playback. No speculative
  production change or replacement app was installed during this investigation.
