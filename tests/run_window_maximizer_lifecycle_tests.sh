#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
maximizer_test_output=$(mktemp -d)
trap 'rm -rf "$maximizer_test_output"' EXIT
python3 - "$maximizer_test_output/WindowMaximizer.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Packages/AnchorUtilities/Sources/AnchorUtilities/Services/WindowMaximizer.swift').read_text()
# Substitute only the window backend. Keep the actual stop, animation and settle logic.
for signature, body in [
    ('    private func frame(of element: AXUIElement) -> AXFrame?', 'return Self.fixtureFrame'),
    ('    private func applyFrame(_ frame: AXFrame, on window: AXUIElement) -> Bool', 'Self.fixtureFrame = frame; return true'),
    ('    private func canSetFrame(on window: AXUIElement) -> Bool', 'return true')
]:
    start = source.index(signature)
    opening = source.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        if source[end] == '{': depth += 1
        elif source[end] == '}': depth -= 1
        end += 1
    source = source[:opening + 1] + '\n' + body + '\n' + source[end - 1:]
source = source.replace('let startedAt = Date()', '', 1)
source = source.replace('Date().timeIntervalSince(startedAt)', 'Self.fixtureElapsed', 1)
source += '''
extension WindowMaximizer {
 private static var fixtureElapsed: TimeInterval = 0
 func fixtureAdvance(_ elapsed: TimeInterval) { Self.fixtureElapsed = elapsed }
 private static var fixtureFrame = AXFrame(origin: .zero, size: CGSize(width: 200, height: 100))
 var fixtureRect: CGRect { CGRect(origin: Self.fixtureFrame.origin, size: Self.fixtureFrame.size) }
 var fixtureTimers: Int { frameAnimations.count }
 var fixtureOriginals: Int { originalFrames.count }
 func fixtureBegin() {
  Self.fixtureElapsed = 0
  Self.fixtureFrame = AXFrame(origin: .zero, size: CGSize(width: 200, height: 100))
  isRunning = true
  let window = AXUIElementCreateApplication(getpid())
  let target = ClickTarget(window: window, button: window, windowID: 1, frame: Self.fixtureFrame, buttonFrame: Self.fixtureFrame, allowsNativeFallback: false)
  originalFrames[1] = Self.fixtureFrame
  _ = changeFrame(to: AXFrame(origin: .zero, size: CGSize(width: 800, height: 600)), of: target) { _ in }
 }
}
'''
Path(sys.argv[1]).write_text(source)
PY
swiftc -swift-version 5 Packages/AnchorUtilities/Sources/AnchorUtilities/Services/WindowMaximizerSupport.swift "$maximizer_test_output/WindowMaximizer.swift" tests/WindowMaximizerLifecycleTests.swift -o "$maximizer_test_output/check"
"$maximizer_test_output/check"
