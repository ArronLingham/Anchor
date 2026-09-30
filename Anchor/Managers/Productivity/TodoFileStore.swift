import Foundation
import Darwin

/// A synchronous, single-writer store. Each accepted mutation has an atomic,
/// synchronized journal before replacing the primary file. Recovery selects a
/// whole generation, including an intentionally empty list; it never merges deletions away.
final class TodoFileStore {
    struct Snapshot: Codable {
        let version: Int
        let revision: UInt64
        let items: [TodoItem]
    }

    enum StorageError: LocalizedError {
        case unreadable, unsupportedVersion, concurrentWriter
        var errorDescription: String? {
            switch self {
            case .concurrentWriter: return "Another Anchor process changed the to-do files. Export your unsaved list, quit the other process, then reopen Anchor before editing."
            case .unreadable: return "The to-do files could not be read. They have been preserved. Restore a backup or export your list before trying again."
            case .unsupportedVersion: return "These to-dos were saved by a newer version of Anchor. Update Anchor before editing them."
            }
        }
    }

    let root: URL
    var primaryURL: URL { root.appendingPathComponent("todos.json") }
    var journalURL: URL { root.appendingPathComponent("todos.journal.json") }
    var backupURL: URL { root.appendingPathComponent("todos.backup.json") }
    var snapshotsDirectory: URL { root.appendingPathComponent("TodoBackups", isDirectory: true) }
    private var revision: UInt64 = 0
    private let fm = FileManager.default

    init(root: URL) { self.root = root }

    static func decode(_ data: Data) throws -> Snapshot {
        let decoder = JSONDecoder()
        if let header = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
            guard let version = header["version"] as? Int else { throw StorageError.unreadable }
            guard version == 1 else { throw StorageError.unsupportedVersion }
            let snapshot = try decoder.decode(Snapshot.self, from: data)
            guard Set(snapshot.items.map(\.id)).count == snapshot.items.count else { throw StorageError.unreadable }
            return snapshot
        }
        let items = try decoder.decode([TodoItem].self, from: data)
        guard Set(items.map(\.id)).count == items.count else { throw StorageError.unreadable }
        return Snapshot(version: 1, revision: 0, items: items)
    }

    /// nil means a new installation, not an empty or corrupt list.
    func load() throws -> [TodoItem]? {
        try withLock { try loadUnlocked() }
    }

    private func loadUnlocked() throws -> [TodoItem]? {
        let current = [primaryURL, journalURL, backupURL]
        let candidates = current + availableSnapshots()
        var best: Snapshot?
        var foundFile = false
        for url in candidates where fm.fileExists(atPath: url.path) {
            foundFile = true
            do {
                let snapshot = try Self.decode(Data(contentsOf: url))
                if best == nil || snapshot.revision > best!.revision { best = snapshot }
            } catch StorageError.unsupportedVersion where current.contains(url) {
                throw StorageError.unsupportedVersion
            } catch { continue }
        }
        if let best {
            revision = best.revision
            return best.items
        }
        if foundFile { throw StorageError.unreadable }
        return nil
    }

    func save(_ items: [TodoItem]) throws {
        try withLock {
            // Detect stale in-memory state before overwriting another process's edit.
            let expectedRevision = revision
            _ = try loadUnlocked()
            guard revision == expectedRevision else {
                revision = expectedRevision
                throw StorageError.concurrentWriter
            }
            try saveUnlocked(items)
        }
    }

    /// Explicit recovery preserves damaged originals before replacing the list.
    func restore(_ items: [TodoItem]) throws {
        try withLock {
            do { _ = try loadUnlocked() }
            catch StorageError.unreadable { /* Explicit recovery may replace an unreadable store. */ }
            try saveUnlocked(items)
        }
    }

    private func saveUnlocked(_ items: [TodoItem]) throws {
        try preserveDamagedFiles()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let next = Snapshot(version: 1, revision: revision + 1, items: items)
        let data = try encoder.encode(next)
        // Keep the last valid generation before committing the new one.
        if let oldData = try? Data(contentsOf: primaryURL),
           (try? Self.decode(oldData)) != nil {
            try durableWrite(oldData, to: backupURL)
            try recordSnapshot(oldData)
        }
        try durableWrite(data, to: journalURL)
        revision = next.revision
        try durableWrite(data, to: primaryURL)
    }

    private func preserveDamagedFiles() throws {
        var recovery: URL?
        for url in [primaryURL, journalURL, backupURL] where fm.fileExists(atPath: url.path) {
            if let data = try? Data(contentsOf: url), (try? Self.decode(data)) != nil { continue }
            if recovery == nil {
                let directory = root.appendingPathComponent("TodoRecovery-\(UUID().uuidString)", isDirectory: true)
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                recovery = directory
            }
            // Do not destroy a damaged source just because another copy decoded.
            try fm.copyItem(at: url, to: recovery!.appendingPathComponent(url.lastPathComponent))
        }
    }

    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent("todos.lock").path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw StorageError.concurrentWriter }
        defer { flock(descriptor, LOCK_UN) }
        return try operation()
    }

    private func durableWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: .atomic)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func recordSnapshot(_ data: Data) throws {
        try fm.createDirectory(at: snapshotsDirectory, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        let url = snapshotsDirectory.appendingPathComponent("todos-\(formatter.string(from: Date())).json")
        // Keep the first pre-edit generation of each day, not the latest typo.
        if !fm.fileExists(atPath: url.path) { try durableWrite(data, to: url) }
        for old in availableSnapshots().dropFirst(30) { try? fm.removeItem(at: old) }
    }

    func availableSnapshots() -> [URL] {
        ((try? fm.contentsOfDirectory(at: snapshotsDirectory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("todos-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
