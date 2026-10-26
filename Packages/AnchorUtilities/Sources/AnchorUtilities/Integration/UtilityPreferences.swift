import Foundation

/// Utility settings never share keys with Anchor's original controls or the
/// reference application. Explicit AppStorage stores cover every editor root.
enum UtilityPreferences {
    static let domainName = (Bundle.main.bundleIdentifier ?? "com.arronlingham.Anchor.tests") + ".utilities"
    static let standard = UserDefaults(suiteName: domainName)!

    static func register() {
        Defaults.register()
        let defaults = standard
        guard !defaults.bool(forKey: "Anchor.integrationPrepared.v1") else { return }
        // New profiles opt in feature by feature. Existing profiles return
        // above and keep their chosen enabled set and all saved configuration.
        for feature in AppFeature.allCases {
            defaults.set(false, forKey: feature.availabilityKey)
        }
        // Optional schedules, captures and input hooks require a deliberate
        // choice. Existing Anchor bindings and persisted data are left intact.
        for key in [DefaultsKey.windowLayoutShortcutsEnabled,
                    DefaultsKey.windowDirectionalEnabled, DefaultsKey.windowGestureEnabled,
                    DefaultsKey.windowEdgeSnapEnabled, DefaultsKey.keepAwakeAutoStart,
                    DefaultsKey.keepAwakeExternalDisplay, DefaultsKey.keepAwakeConnectedToPower,
                    DefaultsKey.keepAwakeMouseJiggleEnabled] {
            defaults.set(false, forKey: key)
        }
        defaults.set("off", forKey: DefaultsKey.cleanerScheduleFrequency)
        defaults.set("off", forKey: DefaultsKey.appUpdatesCheckFrequency)
        defaults.set(false, forKey: DefaultsKey.whatsAppDownloadsAutomaticEnabled)
        defaults.set(false, forKey: DefaultsKey.whatsAppOrganizerEnabled)
        defaults.set(false, forKey: DefaultsKey.autoCheckUpdates)
        defaults.set(KeepAwakeActiveIcon.coffee.rawValue, forKey: DefaultsKey.keepAwakeActiveIcon)
        defaults.set(false, forKey: DefaultsKey.hotkeyEnabled)
        for key in Defaults.registeredDefaults.keys where key.hasSuffix("ShortcutEnabled") {
            defaults.set(false, forKey: key)
        }
        defaults.set(true, forKey: DefaultsKey.commandBarShortcutEnabled)
        defaults.set(true, forKey: "Anchor.integrationPrepared.v1")
    }
}
