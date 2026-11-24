import AppKit

/// Persist layout against the display UUID, which survives rearranging displays.
struct LauncherWidgetProfile: Codable, Equatable {
    enum Widget: String, CaseIterable, Identifiable {
        case clock, weather, calendar, reminders, music

        var id: Self { self }
    }

    static let widgets = Widget.allCases.map(\.rawValue)
    static let categoriesPage = -1

    var order = widgets
    var sizes: [String: Int] = [:]
    var pages: [String: Int] = [:]

    private enum CodingKeys: String, CodingKey {
        case order, sizes, pages
    }

    init() {}

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        order = try values.decodeIfPresent([String].self, forKey: .order) ?? Self.widgets
        sizes = try values.decodeIfPresent([String: Int].self, forKey: .sizes) ?? [:]
        pages = try values.decodeIfPresent([String: Int].self, forKey: .pages) ?? [:]
    }

    func page(for widget: Widget, appPageCount: Int, showCategories: Bool) -> Int {
        let firstPage = showCategories ? Self.categoriesPage : 0
        let savedPage = pages[widget.rawValue] ?? firstPage
        if appPageCount == 0 || savedPage == Self.categoriesPage {
            return firstPage
        }
        return min(max(savedPage, 0), appPageCount - 1)
    }

    mutating func swapWidgets(_ widget: Widget, _ neighbor: Widget) {
        guard let from = order.firstIndex(of: widget.rawValue),
              let to = order.firstIndex(of: neighbor.rawValue) else { return }
        order.swapAt(from, to)
    }

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
