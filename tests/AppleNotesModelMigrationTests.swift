import Foundation

@main
struct AppleNotesModelMigrationTests {
    static func main() throws {
        let id = UUID()
        let payload: [String: Any] = [
            "id": id.uuidString,
            "title": "Existing note",
            "content": "Existing text",
            "creationDate": 1000.0,
            "modificationDate": 1001.0,
            "colorIndex": 1,
            "isPinned": true,
            "appleNotesId": "existing-remote-id"
        ]
        let existing = try JSONDecoder().decode(NoteItem.self, from: JSONSerialization.data(withJSONObject: payload))
        precondition(existing.id == id && existing.appleNotesId == "existing-remote-id")
        precondition(!existing.pendingAppleNotesEdit, "Older saved notes should not invent pending edits")
        var pending = existing
        pending.pendingAppleNotesEdit = true
        let restored = try JSONDecoder().decode(NoteItem.self, from: JSONEncoder().encode(pending))
        precondition(restored.pendingAppleNotesEdit && restored.content == existing.content && restored.appleNotesId == existing.appleNotesId)
        print("Apple Notes model migration: passed")
    }
}
