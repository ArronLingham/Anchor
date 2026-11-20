#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
inspection_test_output=$(mktemp -d)
trap 'rm -rf "$inspection_test_output"' EXIT
python3 - "$inspection_test_output/InspectionMethods.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Packages/AnchorUtilities/Sources/AnchorUtilities/Services/DiskImageInstaller/DiskImageInstallerService.swift').read_text()
methods = []
# Compile the actual lifecycle methods against a fake candidate backend and prompt.
for signature in ('    private func inspect(mountURL: URL)', '    private func stop()'):
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    methods.append(source[start:end].replace('private func', 'func', 1))
Path(sys.argv[1]).write_text('import AppKit\nimport Foundation\nextension DiskImageInspectionFixture {\n' + '\n'.join(methods) + '\n}\n')
PY
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/BoundedProcessRunner.swift "$inspection_test_output/InspectionMethods.swift" tests/DiskImageInspectionLifecycleTests.swift -o "$inspection_test_output/check"
"$inspection_test_output/check"
