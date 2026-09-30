import Foundation

/// Three-way field merge: remote edits replace unchanged local fields. If both
/// devices edit the same field offline, the local edit wins; unrelated edits survive.
enum TodoSyncMerge {
    static func merge(local: TodoItem, remote: TodoItem, baseline: TodoItem?) -> TodoItem {
        guard let baseline else { return local }
        var result = local
        if local.title == baseline.title { result.title = remote.title }
        if local.priority == baseline.priority { result.priority = remote.priority }
        if local.dueDate == baseline.dueDate { result.dueDate = remote.dueDate }
        if local.isDone == baseline.isDone {
            result.isDone = remote.isDone
            result.completedAt = remote.completedAt
        }
        return result
    }
}

extension TodoSyncMerge {
    struct Checkpoint: Codable {
        let calendarID: String
        var baseline: [String: TodoItem] = [:]
        var remoteIDs: [String: String] = [:]
    }
    struct Remote {
        let id: String
        let item: TodoItem
    }
    struct Plan {
        var items: [TodoItem]
        var writes: [TodoItem] = []
        var deletes: [String] = []
        var checkpoint: Checkpoint
    }
    enum MergeError: LocalizedError {
        case duplicate
        var errorDescription: String? { "Two reminders share a task link. Remove the duplicate link in Reminders, then sync again." }
    }

    static func sameContent(_ a: TodoItem, _ b: TodoItem) -> Bool {
        a.title == b.title && a.isDone == b.isDone && a.dueDate == b.dueDate && a.priority == b.priority
    }

    static func plan(local: [TodoItem], remote: [Remote], checkpoint: Checkpoint) throws -> Plan {
        var result = Plan(items: local, checkpoint: Checkpoint(calendarID: checkpoint.calendarID))
        var seen = Set<String>()
        for record in remote {
            let item = record.item
            let key = item.id.uuidString
            guard seen.insert(key).inserted else { throw MergeError.duplicate }
            let baseline = checkpoint.baseline[key]
            if let index = result.items.firstIndex(where: { $0.id == item.id }) {
                let merged = merge(local: result.items[index], remote: item, baseline: baseline)
                result.items[index] = merged
                if !sameContent(merged, item) { result.writes.append(merged) }
                result.checkpoint.baseline[key] = merged
                result.checkpoint.remoteIDs[key] = record.id
            } else if let baseline, sameContent(baseline, item) {
                // A local deletion can be sent only when the phone did not edit it.
                result.deletes.append(record.id)
            } else {
                result.items.append(item)
                result.checkpoint.baseline[key] = item
                result.checkpoint.remoteIDs[key] = record.id
            }
        }
        for item in result.items where !seen.contains(item.id.uuidString) {
            let key = item.id.uuidString
            if let remoteID = checkpoint.remoteIDs[key] {
                // Missing results can be a transient iCloud state. Preserve both
                // the local task and its old baseline until the record returns.
                result.checkpoint.remoteIDs[key] = remoteID
                result.checkpoint.baseline[key] = checkpoint.baseline[key]
            } else {
                result.writes.append(item)
                result.checkpoint.baseline[key] = item
            }
        }
        for (key, baseline) in checkpoint.baseline where !seen.contains(key) && !result.items.contains(where: { $0.id.uuidString == key }) {
            result.checkpoint.baseline[key] = baseline
            result.checkpoint.remoteIDs[key] = checkpoint.remoteIDs[key]
        }
        return result
    }
}
