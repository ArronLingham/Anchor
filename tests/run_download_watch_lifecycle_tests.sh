#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/DownloadManager.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Productivity/DownloadManager.swift").read_text().replace("import Defaults\n", "")
source = source.replace("FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first", "DownloadWatchLifecycleTests.directory")
source += """
extension DownloadManager {
    var sessionForTest: UUID? { watchTicket }
    var didScanForTest: Bool { hasPerformedInitialScan }
    var timerForTest: Timer? { completionTimer }
    func deliverForTest(_ downloads: Set<String>, allFiles: Set<String>, ticket: UUID) {
        processDownloadFiles(downloads, allFiles: allFiles, ticket: ticket)
    }
}
"""
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -swift-version 5 "$output/DownloadManager.swift" tests/DownloadWatchLifecycleTests.swift -o "$output/check"
"$output/check"
