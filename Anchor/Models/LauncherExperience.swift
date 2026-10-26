import AppKit
import Defaults

extension Defaults.Keys {
    static let launcherReduceAnimations = Key<Bool>("launcherReduceAnimations", default: false)
}

enum LauncherMotion {
    static var reduced: Bool {
        Defaults[.launcherReduceAnimations] || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}
