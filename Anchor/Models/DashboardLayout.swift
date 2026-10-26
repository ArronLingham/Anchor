import Foundation

enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, productivity, media, system
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .productivity: "checklist"
        case .media: "music.note"
        case .system: "slider.horizontal.3"
        }
    }
    var defaultCards: [DashboardCard] {
        switch self {
        case .overview: [.tasks, .nowPlaying, .focus, .quickControls]
        case .productivity: [.tasks, .focus, .upcoming, .shelf, .clipboard, .quicklinks]
        case .media: [.nowPlaying, .appAudio]
        case .system: [.soundDisplay, .quickControls, .featureFavorites]
        }
    }
}

enum DashboardCard: String, CaseIterable, Identifiable {
    case tasks, nowPlaying, focus, upcoming, shelf, clipboard, quicklinks, appAudio, soundDisplay, quickControls, featureFavorites
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: "Tasks"
        case .nowPlaying: "Now playing"
        case .focus: "Focus & timers"
        case .upcoming: "Upcoming"
        case .shelf: "File shelf"
        case .clipboard: "Clipboard"
        case .quicklinks: "Quicklinks"
        case .appAudio: "App audio"
        case .soundDisplay: "Sound & display"
        case .quickControls: "Quick controls"
        case .featureFavorites: "Favorite tools"
        }
    }
    var symbol: String {
        switch self {
        case .tasks: "checklist"
        case .nowPlaying: "music.note"
        case .focus: "timer"
        case .upcoming: "calendar"
        case .shelf: "tray"
        case .clipboard: "doc.on.clipboard"
        case .quicklinks: "link"
        case .appAudio: "speaker.wave.2"
        case .soundDisplay: "slider.horizontal.3"
        case .quickControls: "bolt"
        case .featureFavorites: "star"
        }
    }
}

/// Persist stable IDs, preserving an intentionally empty section. Missing
/// sections use defaults, while stale/duplicate card IDs are ignored.
struct DashboardLayout: Codable, Equatable {
    private var sections: [String: [String]] = [:]

    static func load(_ data: Data) -> Self {
        (try? JSONDecoder().decode(Self.self, from: data)) ?? Self()
    }
    var data: Data { (try? JSONEncoder().encode(self)) ?? Data() }

    func cards(in section: DashboardSection) -> [DashboardCard] {
        guard let stored = sections[section.rawValue] else { return section.defaultCards }
        var seen = Set<DashboardCard>()
        return stored.compactMap(DashboardCard.init(rawValue:)).filter { seen.insert($0).inserted }
    }

    mutating func setVisible(_ visible: Bool, card: DashboardCard, in section: DashboardSection) {
        var cards = cards(in: section)
        guard cards.contains(card) != visible else { return }
        cards.removeAll { $0 == card }
        if visible { cards.append(card) }
        sections[section.rawValue] = cards.map(\.rawValue)
    }

    mutating func restore(_ section: DashboardSection) {
        sections.removeValue(forKey: section.rawValue)
    }

    struct Row: Identifiable {
        let cards: [DashboardCard]
        var id: DashboardCard { cards[0] }
    }

    /// The file shelf keeps the full row. Other cards pair up on wide windows.
    func rows(in section: DashboardSection) -> [Row] {
        var result: [Row] = []
        var pair: [DashboardCard] = []
        for card in cards(in: section) {
            if card == .shelf {
                if !pair.isEmpty { result.append(Row(cards: pair)); pair = [] }
                result.append(Row(cards: [card]))
            } else {
                pair.append(card)
                if pair.count == 2 { result.append(Row(cards: pair)); pair = [] }
            }
        }
        if !pair.isEmpty { result.append(Row(cards: pair)) }
        return result
    }
}
