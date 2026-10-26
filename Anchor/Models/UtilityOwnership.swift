import Foundation

/// A handover records the user's original choice exactly once, even when two
/// advanced features share one classic control. Removing the last owner restores it.
struct UtilityOwnership {
    var paused: [String: Bool]

    mutating func reconcile(owners: Set<String>, controls: [String: [String]],
                            current: [String: Bool]) -> [String: Bool] {
        let claimed = Set(owners.flatMap { controls[$0] ?? [] })
        var writes: [String: Bool] = [:]
        for key in claimed {
            if paused[key] == nil { paused[key] = current[key] ?? false }
            if current[key] != false { writes[key] = false }
        }
        for key in Array(paused.keys) where !claimed.contains(key) {
            writes[key] = paused.removeValue(forKey: key)
        }
        return writes
    }
}
