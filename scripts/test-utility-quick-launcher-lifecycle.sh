#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

output=$(mktemp -d)
trap 'for file in main.swift check; do if test -f "$output/$file"; then unlink "$output/$file"; fi; done; rmdir "$output"' EXIT
python3 - "$output/main.swift" <<'PY'
from pathlib import Path
import sys

root = Path("Packages/AnchorUtilities/Sources/AnchorUtilities")
gate_source = (root / "Services/Clipboard/ClipboardHistorySupport.swift").read_text()
gate = gate_source[gate_source.index("final class ClipboardPresentationGate"):gate_source.index("/// How the history window")]
source = (root / "Services/QuickTools/QuickLauncherService.swift").read_text()
methods = source[source.index("    private static let presentationGate"):source.index("    @discardableResult")]
lifecycle = source[source.index("    private init()"):source.index("    var isVisible:")]
Path(sys.argv[1]).write_text("import Foundation\n" + gate + """
enum AppFeature { static let quickLauncher = FixtureFeature() }
final class FixtureFeature { var isAvailable = false }
enum DefaultsKey { static let quickLauncherShortcut = "shortcut"; static let quickLauncherShortcutEnabled = "enabled" }
final class UtilityPreferences {
    static let standard = UtilityPreferences()
    var enabled = true
    func bool(forKey: String) -> Bool { enabled }
}
final class UtilityWorkspace {
    static let shared = UtilityWorkspace()
    func prepareOwnership() {}
}
enum GlobalShortcut {
    case quickLauncherDefault
    static func saved(for: String, fallback: Self) -> Self { fallback }
}
final class QuickToolHotkey {
    var capturePress: (() -> (() -> Void)?)?
    func sync(enabled: Bool, shortcut: GlobalShortcut, storageKey: String) -> Bool { true }
    func unregister() {}
}

final class QuickLauncherService {
    static var constructions = 0
    static var shows = 0
    static var existing: QuickLauncherService?
    static var shared: QuickLauncherService {
        if let existing { return existing }
        constructions += 1
        let service = QuickLauncherService()
        existing = service
        return service
    }
    let hotkey = QuickToolHotkey()
    let shortcutGate = ClipboardPresentationGate()
    var shortcutRegistrationFailed = false
    func show() { Self.shows += 1 }
    func toggle() { show() }
    func hide() {}
    func releaseResources() -> Bool { suspend(); return true }
""" + methods + lifecycle + """
}

let feature = AppFeature.quickLauncher
QuickLauncherService.syncAvailability()
precondition(QuickLauncherService.presentationRequest() == nil)
precondition(QuickLauncherService.constructions == 0)

feature.isAvailable = true
QuickLauncherService.syncAvailability()
let retired = QuickLauncherService.presentationRequest()!
feature.isAvailable = false
retired()
precondition(QuickLauncherService.shows == 0, "A retired request must see the current setting before reconciliation")
QuickLauncherService.syncAvailability()
retired()
precondition(QuickLauncherService.shows == 0)

feature.isAvailable = true
QuickLauncherService.syncAvailability()
retired()
precondition(QuickLauncherService.shows == 0, "Re-enabling must not restore a retired request")
QuickLauncherService.presentationRequest()?()
precondition(QuickLauncherService.shows == 1)
let launcher = QuickLauncherService.shared
let press = launcher.hotkey.capturePress?()
UtilityPreferences.standard.enabled = false
launcher.syncWithPreferences()
UtilityPreferences.standard.enabled = true
launcher.syncWithPreferences()
press?()
precondition(QuickLauncherService.shows == 1, "Re-enabling the shortcut must not replay an old press")
let freshPress = launcher.hotkey.capturePress?()
freshPress?()
precondition(QuickLauncherService.shows == 2)
print("Quick Launcher disabled startup, retired requests and fresh requests passed")
""")
PY
xcrun swiftc "$output/main.swift" -o "$output/check"
"$output/check"
