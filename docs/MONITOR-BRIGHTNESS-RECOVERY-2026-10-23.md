# Monitor brightness recovery — October 23, 2026

## Diagnosis

The installed Anchor had Lunar integration enabled, but Lunar was not running when diagnosis began. Anchor's integration only listens for Lunar adjustment events; Lunar owns the media-key and monitor control path. The existing manager did not start the selected provider when a monitor was attached. Its repair button only rebuilt Anchor's listener socket, without asking Lunar to refresh its monitor routes or media-key tap.

The connected external monitor was EK271 GD, display ID 2, using VGA. Lunar reported DDC disabled and gamma/software dimming enabled. This connection was not tested as a hardware-backlight DDC connection.

## Change

Anchor starts the installed Lunar provider when its integration is enabled and an external monitor is present. Monitor identity changes and Mac/display wake notifications schedule one recovery after three seconds of settling. Unchanged display-parameter notifications do not repeatedly refresh Lunar. Disabling or switching the integration cancels pending work. Quitting Lunar does not cause an immediate endless relaunch loop; a later monitor connection/wake or explicit repair can start it again.

Recovery uses Lunar's authenticated `refresh-displays` command on a separate localhost IPv4 socket, with an eight-second timeout and stale callback guards. The command refreshes Lunar's display list, restarts DDC discovery and recreates its media-key tap. Anchor then installs a fresh adjustment listener. Errors and unauthorized replies do not count as successful repair. The Reconnect Lunar button follows the same full repair path.

No polling timer or forced Lunar restart was added. No monitor brightness preference, DDC option, or adaptive mode was changed.

## Verification

- Focused regression suite passed: fragmented/batched Lunar events, bounded invalid input, repeated screen-notification suppression, wake, disconnect/reconnect, reused display number with a different identity, failed/unauthorized refresh responses, and existing per-display profiles.
- Signed Release build succeeded; deep strict signature verification passed.
- Built and installed Anchor executable SHA-256: `f67057b158c8339498d87aac093f6871a990b552ef81f8e253d4a49aa50dd3a0`.
- Quit Lunar before launching the updated installed Anchor. Anchor started Lunar automatically; both processes were verified running from `/Applications`, with an established IPv4 listener connection.
- Installed Settings > Connections reported Connected. The Reconnect Lunar action completed and returned to Connected.
- Real monitor control check: requested external brightness 87 → 81 → 87. The actual CoreGraphics gamma maximum changed 0.87696093 → 0.8219766 → 0.87696093. Built-in display gamma stayed at 1.0. The original external brightness was restored.
- A physical cable unplug/replug and actual sleep/wake were not performed. Their recovery decisions were covered by the focused tests; a live physical reconnect remains a user check.

## References

- Lunar FAQ, “Brightness controls are locked after standby/wake”: https://lunar.fyi/faq
- Lunar's CLI implementation (`RefreshDisplays` and `Listen`): https://github.com/alin23/Lunar/blob/master/Lunar/Data/CLI.swift
- Installed Lunar CLI help confirmed `refresh-displays` support. A direct authenticated request returned its success response.
