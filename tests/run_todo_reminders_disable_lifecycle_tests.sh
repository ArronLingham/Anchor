#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/FetchMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Productivity/TodoRemindersSyncManager.swift").read_text()
methods = source[source.index("    private func acceptsSync("):source.index("    private enum SyncError:")]
request = source[source.index("    private struct FetchRequest"):source.index("    private var repeatRequested")]
body = (request + methods).replace("private ", "")
# Extensions cannot add stored properties. The fixture declares the slot.
body = body.replace("    var fetchRequest: FetchRequest?\n", "")
Path(sys.argv[1]).write_text("import Foundation\nextension ReminderFixture {\n" + body + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/FetchMethods.swift" tests/TodoRemindersDisableLifecycleTests.swift -o "$output/check"
"$output/check"
