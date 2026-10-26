import Foundation

/// Maintenance tools stay indexed and launchable, but are search-only in the
/// launcher. Identify Apple apps by bundle ID/path rather than localized names.
enum LauncherAppVisibility {
    private static let extraUtilityIDs: Set<String> = [
        "com.apple.fontbook", "com.apple.automator", "com.apple.image_capture",
        "com.apple.dictionary", "com.apple.diskutility", "com.apple.activitymonitor",
        "com.apple.console", "com.apple.keychainaccess", "com.apple.systemprofiler"
    ]

    static func isSearchOnly(url: URL, bundleIdentifier: String?) -> Bool {
        let identifier = bundleIdentifier?.lowercased() ?? ""
        // Terminal is a regular development tool, including on the opening page.
        if identifier == "com.apple.terminal" { return false }
        if extraUtilityIDs.contains(identifier) { return true }
        let path = url.standardizedFileURL.path
        return path.hasPrefix("/System/Applications/Utilities/")
            || path.hasPrefix("/System/Library/CoreServices/Applications/")
            || (path.hasPrefix("/Applications/Utilities/") && identifier.hasPrefix("com.apple."))
    }
}
