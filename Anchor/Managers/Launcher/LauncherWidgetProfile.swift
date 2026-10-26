import AppKit
import SwiftUI

/// Persist layout against the display UUID, which survives rearranging displays.
struct LauncherWidgetProfile: Codable, Equatable {
    static let widgets = ["clock", "weather", "calendar", "reminders", "music"]
    var order = widgets
    var sizes: [String: Int] = [:]

    static func screenID(_ screen: NSScreen?) -> String {
        guard let number = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
              let uuid = CGDisplayCreateUUIDFromDisplayID(number.uint32Value)?.takeRetainedValue()
        else { return "default" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func load(_ data: Data, screen: String) -> Self {
        let profiles = (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
        var profile = profiles[screen] ?? Self()
        var seen = Set<String>()
        profile.order = (profile.order + widgets).filter { widgets.contains($0) && seen.insert($0).inserted }
        return profile
    }

    func saving(in data: Data, screen: String) -> Data {
        var profiles = (try? JSONDecoder().decode([String: Self].self, from: data)) ?? [:]
        profiles[screen] = self
        return (try? JSONEncoder().encode(profiles)) ?? data
    }
}

private struct LauncherWidgetWidthKey: EnvironmentKey {
    static let defaultValue: CGFloat = 218
}
extension EnvironmentValues {
    var launcherWidgetWidth: CGFloat {
        get { self[LauncherWidgetWidthKey.self] }
        set { self[LauncherWidgetWidthKey.self] = newValue }
    }
}
