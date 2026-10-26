import Foundation

/// Power commands need an explicit phrase. A short fuzzy match must never
/// send this Mac to the lock screen, a screen saver, or a dark display.
enum UtilityCommandIntent {
    static func allows(id: String, query: String, title: String, customName: String? = nil) -> Bool {
        let phrases: [String]
        switch id {
        case "action.lockScreen": phrases = ["lock", "lock screen", "lock mac"]
        case "action.displayOff": phrases = ["display off", "turn off display", "turn off screen"]
        case "action.screenSaver": phrases = ["screen saver", "screensaver", "start screen saver"]
        default: return true
        }
        let value = normalized(query)
        guard !value.isEmpty else { return false }
        return (phrases + [title] + (customName.map { [$0] } ?? [])).contains { normalized($0) == value }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}
