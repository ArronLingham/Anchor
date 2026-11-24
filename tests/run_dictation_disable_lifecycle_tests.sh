#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
output=$(mktemp -d)
trap 'rm -rf "$output"' EXIT
python3 - "$output/DictationManager.swift" "$output/PasteMethods.swift" <<'PY'
from pathlib import Path
import sys

source = Path("Anchor/Managers/Dictation/DictationManager.swift").read_text()
source = source.replace("import Defaults\n", "").replace("    private init(makeBackend:", "    init(makeBackend:")
source = source.replace("private let engine = AVAudioEngine()", "private(set) var fixtureEngineIsRecording = false")
start = source.index("    private func startEngine(")
end = source.index("    // MARK: - Delivery", start)
engine = """    private func startEngine(backend: SpeechTranscribing, token: Int) throws {
        fixtureEngineIsRecording = true
    }

    private func stopEngine() {
        fixtureEngineIsRecording = false
        live.inputLevel = 0
    }

"""
Path(sys.argv[1]).write_text(source[:start] + engine + source[end:])

injector = Path("Anchor/Managers/Dictation/TextInjector.swift").read_text()
start = injector.index("    @MainActor\n    static func insert(")
end = injector.index("    /// Marks a pasteboard write", start)
paste = injector[start:end].replace("NSPasteboard.general", "FixturePasteboard.shared")
Path(sys.argv[2]).write_text("import Foundation\nextension DeliveryFixture {\n" + paste + "}\n")
PY
xcrun swiftc -swift-version 5 "$output/DictationManager.swift" "$output/PasteMethods.swift" Anchor/Managers/Dictation/SpeechTranscribing.swift tests/DictationDisableLifecycleTests.swift -o "$output/check"
"$output/check"
