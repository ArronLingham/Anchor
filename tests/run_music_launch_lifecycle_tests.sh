#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT

cat > "$task_tmp/main.swift" <<'SWIFT'
import Foundation

@main struct MusicLaunchLifecycleTests {
    static func main() {
        let admission = MusicReplacementPlaybackAdmission()
        let waitingForLaunch = admission.begin()
        precondition(admission.accepts(waitingForLaunch), "current launch wait is admitted")

        admission.invalidate() // feature disabled
        precondition(!admission.accepts(waitingForLaunch), "disable rejects a delayed launch wait")

        let afterReenable = admission.begin()
        precondition(admission.accepts(afterReenable), "new lifecycle is admitted")
        precondition(!admission.accepts(waitingForLaunch), "off/on does not revive old playback")

        admission.invalidate() // disable while an Apple-event retry is pending
        precondition(!admission.accepts(afterReenable), "disable rejects a delayed retry")
        print("Music replacement playback admission checks passed")
    }
}
SWIFT

swiftc -swift-version 5 -parse-as-library \
  Packages/AnchorUtilities/Sources/AnchorUtilities/Services/Audio/MusicLaunchSupport.swift \
  "$task_tmp/main.swift" -o "$task_tmp/tests"
"$task_tmp/tests"
