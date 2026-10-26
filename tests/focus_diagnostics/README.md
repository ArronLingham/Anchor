# Focus investigation tools

`bash tests/focus_diagnostics/run_focus_race_probe.sh` extracts the current
production methods and executes them against a small AppKit model with a
controlled user destination and delayed completions. It does not activate real
apps, type, read clipboard data, or send synthetic keyboard events.

The current probe confirms six existing failure cases and one valid cancellation
control. **These are bug reproductions, not passing fix regressions.** A fix should
change these expectations to assert that the newer destination is preserved.
The command-bar case models Apple's documented `makeFirstResponder` fallback;
it does not establish how often the installed SwiftUI field refuses focus.

For real AppKit observations, compile `FocusTrace.swift` and run it with the
installed Anchor PID and an optional duration in seconds:

```sh
swiftc tests/focus_diagnostics/FocusTrace.swift -o /tmp/anchor-focus-trace
/tmp/anchor-focus-trace ANCHOR_PID 45
```

The trace watches focus and application activation notifications. It reports
application IDs, roles, Anchor window titles and field placeholders; it never
reads field contents or records keystrokes. The foreground app and keyboard
focus owner can differ for a nonactivating panel. The program exits at the end
of the requested duration; nothing is installed in Anchor or left running.
