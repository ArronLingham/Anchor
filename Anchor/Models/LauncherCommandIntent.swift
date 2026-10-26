import Foundation

enum LauncherCommandIntent {
    /// Locking must never be offered for a loose fuzzy match like "screen".
    /// It still runs directly when the user asks for the lock action by name.
    static func allows(_ commandID: String, query: String) -> Bool {
        guard commandID == "toggle.lockScreen" else { return true }
        let normalized = query.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return ["lock", "lock screen", "lock mac", "secure mac"].contains(normalized)
    }
}
