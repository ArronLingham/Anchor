#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/WorkspaceManager.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Workspace/DesktopWorkspaceManager.swift").read_text()
lifecycle = source[:source.index("    func recentApps(")]
toggle = source[source.index("    func toggleShowAllDocks()"):source.index("    func scheduleEnvironmentCheck()")]
isolated = (lifecycle + toggle).replace("    private var ", "    var ")
Path(sys.argv[1]).write_text(isolated + "    func scheduleEnvironmentCheck() {}\n}\n")
PY
xcrun swiftc -swift-version 5 "$output/WorkspaceManager.swift" tests/DesktopDocksDisableLifecycleTests.swift -o "$output/check"
"$output/check"
