#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'for file in TerminalMethods.swift TerminalReaper.swift SettingsMethods.swift check pty-check child.pid; do if test -f "$output/$file"; then unlink "$output/$file"; fi; done; rmdir "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys
output = Path(sys.argv[1])

manager = Path("Anchor/Managers/Productivity/TerminalManager.swift").read_text()
state = manager[manager.index("    var runningSession:"):manager.index("    /// SwiftTerm's built-in scroller")]
observer = manager[manager.index("    private init()"):manager.index("    // MARK: - Lifecycle")]
observer = observer.replace("private init()", "func observePreferences()")
lifecycle = manager[manager.index("    /// Starts the shell process"):manager.index("    // MARK: - Font Resolution")]
focus = manager[manager.index("    /// Makes terminal view first responder"):manager.index("    /// Resigns terminal focus")]
focus = focus.replace("DispatchQueue.main.asyncAfter(deadline: .now() + 0.05)", "enqueueFocusRetry")
terminal = (state + observer + lifecycle + focus).replace("private ", "")
terminal = terminal.replace("NSApp", "FixtureApp.shared").replace("TerminalShellReaper", "FixtureReaper")
(output / "TerminalMethods.swift").write_text(
    "import Foundation\nimport AppKit\nimport Combine\nimport os\n\nextension TerminalFixture {\n" + terminal + "}\n"
)

settings = Path("Anchor/Components/Settings/SettingsTerminal.swift").read_text()
binding = settings[settings.index("    private var terminalEnabledBinding"):settings.index("    var body: some View")]
binding = binding.replace("get: { ", "get: { [self] in ").replace("set: { enabled", "set: { [self] enabled")
confirmation = settings[settings.index("                let running = terminalManager.runningSession"):settings.index("        } message: { _ in")]
confirmation = confirmation[:confirmation.rindex("            }")]
(output / "SettingsMethods.swift").write_text(
    "import SwiftUI\nextension TerminalSettingsFixture {\n"
    + binding.replace("private ", "") + "    func confirm(_ session: UUID) {\n" + confirmation + "    }\n}\n"
)
reaper = manager[manager.index("private enum TerminalShellReaper"):manager.index("/// Manages the Guake-style")]
(output / "TerminalReaper.swift").write_text("import Darwin\nimport Foundation\n" + reaper.replace("private enum", "enum"))
PY
xcrun swiftc -swift-version 5 "$output"/{TerminalMethods,SettingsMethods}.swift tests/TerminalDisableLifecycleTests.swift -o "$output/check"
"$output/check"

if [[ $# -gt 0 ]]; then
    products=$1
    xcrun swiftc -swift-version 5 -target arm64-apple-macos26.0 -I "$products" "$output/TerminalReaper.swift" \
        tests/TerminalPTYTests.swift "$products/SwiftTerm.o" -o "$output/pty-check"
    "$output/pty-check" "$output/child.pid"
fi
