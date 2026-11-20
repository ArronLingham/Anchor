#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
services=Packages/AnchorUtilities/Sources/AnchorUtilities/Services
python3 - "$services/KeepAwakeManager.swift" "$output/SetupMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path(sys.argv[1]).read_text()
start = source.index("    private func cancelClamshellSetup()")
end = source.index("    /// Turns the preference back off", start)
methods = source[start:end].replace("private func", "func")
Path(sys.argv[2]).write_text("import Foundation\nextension SetupFixture {\n" + methods + "}\n")
PY
swiftc -swift-version 5 "$services/BoundedProcessRunner.swift" "$output/SetupMethods.swift" tests/KeepAwakeSetupTests.swift -o "$output/check"
"$output/check"
