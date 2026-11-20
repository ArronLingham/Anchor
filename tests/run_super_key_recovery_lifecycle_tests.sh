#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/RecoveryMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Packages/AnchorUtilities/Sources/AnchorUtilities/Services/SuperKey/SuperKeyService.swift").read_text()
start = source.index("    private func updateMappingRecovery(")
end = source.index("    /// Sleep can bring", start)
methods = source[start:end].replace("private func", "func").replace("NSWorkspace.shared.notificationCenter", "notificationCenter")
Path(sys.argv[1]).write_text("import AppKit\nextension RecoveryFixture {\n" + methods + "}\n")
PY
swiftc -swift-version 5 "$output/RecoveryMethods.swift" tests/SuperKeyRecoveryLifecycleTests.swift -o "$output/check"
"$output/check"
