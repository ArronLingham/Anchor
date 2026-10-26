#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
python3 - "$work" <<'PY'
from pathlib import Path
import sys
work=Path(sys.argv[1])
source=Path('Anchor/Managers/Clipboard/ClipboardManager.swift').read_text().split('class ClipboardManager:')[0].replace('import Defaults\n','')
source+='\nclass ClipboardManager { static let clipboardDataDirectory = FileManager.default.temporaryDirectory }\n'
(work/'ClipboardItem.swift').write_text(source)
PY
swiftc -O -module-cache-path "$work/modules" \
  Anchor/Models/ProductivityWorkflows.swift Anchor/Models/CircularHUDLayout.swift \
  Anchor/Models/LockScreenPresentationState.swift "$work/ClipboardItem.swift" \
  tests/ProductivityWorkflowTests.swift -o "$work/check"
"$work/check"
