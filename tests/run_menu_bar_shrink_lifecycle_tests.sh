#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
manager = Path("Anchor/Managers/System/MenuBarShrinkManager.swift").read_text()
session = manager[manager.index("    var currentSession:"):manager.index("    private override init()")]
lifecycle = manager[manager.index("    func start()"):manager.index("    /// Pre-seeds")]
guard = manager[manager.index("    private func activate(generation:"):manager.index("        let chevronPos =", manager.index("    private func activate(generation:"))]
timer = manager[manager.index("    private func scheduleAutoHide()"):manager.index("    // MARK: - Glyph")]
methods = (session + lifecycle + guard + """
        isActive = true
        installations += 1
        observeWhileActive(generation)
    }
""" + timer).replace("private ", "").replace("NSApplication.", "FixtureApplication.").replace("NSEvent", "FixtureEvent").replace("NSScreen", "FixtureScreen").replace("DispatchSource.makeTimerSource", "FixtureTimer")
(output / "MenuBarShrinkMethods.swift").write_text("import Foundation\nimport CoreGraphics\nimport Combine\n\nextension MenuBarShrinkManager {\n" + methods + "}\n")

app = Path("Anchor/AnchorApp.swift").read_text()
shortcuts = app[app.index("        let menuBarShortcuts ="):app.index("    @MainActor\n    private func updateShortcut(")]
(output / "MenuBarShortcuts.swift").write_text("extension ShortcutFixture {\n    func reconcile() {\n" + shortcuts + "}\n")

arranger = Path("Anchor/Managers/System/MenuBarItemArranger.swift").read_text()
holds = arranger[arranger.index("    private func holdsArrangement"):arranger.index("    func begin()")]
move = arranger[arranger.index("    func move("):arranger.index("    private static func sameDisplay")]
(output / "MenuBarArrangementMethods.swift").write_text("import Foundation\nimport CoreGraphics\nextension ArrangementFixture {\n" + holds + move + "}\n")
PY
xcrun swiftc -swift-version 5 "$output"/{MenuBarShrinkMethods,MenuBarShortcuts,MenuBarArrangementMethods}.swift tests/MenuBarShrinkLifecycleTests.swift -o "$output/check"
"$output/check"
