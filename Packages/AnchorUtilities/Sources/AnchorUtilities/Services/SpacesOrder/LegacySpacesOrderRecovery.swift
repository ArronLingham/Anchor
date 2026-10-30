import CoreFoundation
import Foundation
import os

/// Older Anchor versions temporarily owned the Dock preference and stored a
/// value to restore on removal. Adopt the current preference into the Dock
/// before clearing that journal, so removal cannot undo a native choice.
enum LegacySpacesOrderRecovery {
    private static let defaults = UtilityPreferences.standard
    private static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Anchor", category: "spaces-order")

    static var hasPendingRestore: Bool {
        defaults.object(forKey: DefaultsKey.spacesOrderRestore) != nil
            || defaults.object(forKey: DefaultsKey.spacesOrderRestartPending) != nil
    }

    static func recoverIfNeeded() {
        if hasPendingRestore && !adopt() {
            log.error("Could not adopt the previous Spaces setting; recovery records were retained")
        }
    }

    @discardableResult
    static func adopt() -> Bool {
        adopt(defaults: defaults, read: readStoredSetting, write: NativeDockSpaces.write)
    }

    static func adopt(defaults: UserDefaults, read: () -> Bool?, write: (Bool) -> Bool) -> Bool {
        let restore = defaults.object(forKey: DefaultsKey.spacesOrderRestore)
        let restart = defaults.object(forKey: DefaultsKey.spacesOrderRestartPending)
        guard restore != nil || restart != nil else { return true }
        // The persisted native setting is the latest user choice, including a
        // write the old version made before a pending Dock restart.
        guard let rearrange = read(), write(rearrange) else { return false }
        defaults.removeObject(forKey: DefaultsKey.spacesOrderRestore)
        defaults.removeObject(forKey: DefaultsKey.spacesOrderRestartPending)
        guard defaults.synchronize() else {
            if let restore { defaults.set(restore, forKey: DefaultsKey.spacesOrderRestore) }
            if let restart { defaults.set(restart, forKey: DefaultsKey.spacesOrderRestartPending) }
            return false
        }
        return true
    }

    private static func readStoredSetting() -> Bool? {
        let domain = "com.apple.dock" as CFString
        let key = "mru-spaces" as CFString
        guard !CFPreferencesAppValueIsForced(key, domain),
              CFPreferencesSynchronize(domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return nil }
        guard let raw = CFPreferencesCopyValue(key, domain, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) else { return true }
        guard let value = raw as? NSNumber,
              CFGetTypeID(raw) == CFBooleanGetTypeID() || CFGetTypeID(raw) == CFNumberGetTypeID(),
              value.doubleValue == 0 || value.doubleValue == 1 else { return nil }
        return value.boolValue
    }
}
