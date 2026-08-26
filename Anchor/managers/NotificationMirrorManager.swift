/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

import AppKit
import Combine
import Defaults
import Foundation
import SQLite3

/// One notification, as macOS recorded it.
struct MirroredNotification: Identifiable, Equatable {
    let id: Int64
    let bundleID: String
    let title: String
    let subtitle: String?
    let body: String?
    let date: Date

    /// The app's display name, resolved from its bundle id. Falls back to the
    /// identifier so an uninstalled or sandboxed sender still reads sensibly.
    var appName: String {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }
}

/// Mirrors macOS notifications into the notch. Category 19.
///
/// **Requires Full Disk Access**, because the only record of another app's
/// notification is Apple's private database at
/// `~/Library/Group Containers/group.com.apple.usernoted/db2/db`. There is no
/// public API — `UNUserNotificationCenter` only ever reports your own app's.
/// That grant covers Mail, Messages and Safari history too, so this is off by
/// default and the Settings pane says what it costs.
///
/// Read-only and event-driven: the database is opened `SQLITE_OPEN_READONLY`,
/// nothing is ever written to it, and new rows are noticed by watching the
/// write-ahead log rather than polling.
///
/// **It watches `db-wal` with kqueue, not FSEvents, and that is not a style
/// choice.** FSEvents delivers *nothing* for this Group Container — measured:
/// a notification arrived, the record landed, `db-wal`'s mtime moved, and the
/// stream fired zero times. A `DispatchSource` file-system object source on
/// `db-wal` sees the same commit as five `write`/`extend` events. `db-wal` is
/// the target because SQLite is in WAL mode: commits append there and only
/// fold into `db` at a checkpoint.
@MainActor
final class NotificationMirrorManager: ObservableObject {
    static let shared = NotificationMirrorManager()

    enum State: Equatable {
        case off
        /// Full Disk Access has not been granted.
        case needsPermission
        case running
    }

    @Published private(set) var state: State = .off

    /// Most recent first, capped — this is a peek at what just arrived, not an
    /// archive. Notification Center already is the archive.
    @Published private(set) var recent: [MirroredNotification] = []

    private let maxRecent = 20

    private var watch: DispatchSourceFileSystemObject?
    private var watchedDescriptor: CInt = -1
    private var cancellables = Set<AnyCancellable>()
    private let queue = DispatchQueue(label: "com.arronlingham.Anchor.notificationMirror")

    /// The write-ahead log, which is what actually moves when a notification
    /// arrives. Checkpointing can replace it, hence the re-arm in `armWatch`.
    ///
    /// `-wal`, not `.wal`: SQLite names it by appending a hyphenated suffix to
    /// the database filename, so `appendingPathExtension` produces `db.wal`,
    /// which does not exist and opens as fd -1.
    private var walURL: URL {
        URL(fileURLWithPath: databaseURL.path + "-wal")
    }

    /// Highest `rec_id` already surfaced, so a rescan only reports new rows.
    private var lastSeenID: Int64 = 0

    private var databaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Group Containers/group.com.apple.usernoted/db2/db")
    }

    private init() {
        // Never block in a manager's init — see CLAUDE.md.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            Defaults.publisher(.enableNotificationMirroring)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.syncToSettings() }
                .store(in: &self.cancellables)
            self.syncToSettings()
        }
    }

    private func syncToSettings() {
        if Defaults[.enableNotificationMirroring] { start() } else { stop() }
    }

    // MARK: - Lifecycle

    private func start() {
        guard watch == nil else { return }

        guard FileManager.default.isReadableFile(atPath: databaseURL.path) else {
            // Not retried on a timer. The Settings pane offers the button that
            // opens System Settings, and toggling the feature re-checks.
            state = .needsPermission
            return
        }

        // Seed the high-water mark so enabling the feature does not dump
        // everything already in the database into the notch.
        lastSeenID = highestRecordID() ?? 0

        guard armWatch() else {
            state = .off
            return
        }
        state = .running
    }

    /// Opens `db-wal` and arms a kqueue watch on it.
    ///
    /// Re-arms itself if the file is replaced — SQLite recreates the WAL on
    /// checkpoint, which invalidates the descriptor. The re-arm is deferred a
    /// beat so a delete/create pair does not spin.
    @discardableResult
    private func armWatch() -> Bool {
        disarmWatch()

        let descriptor = open(walURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            Logger.log(
                "Notification mirror: cannot open \(walURL.lastPathComponent)", category: .error)
            return false
        }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .delete, .rename, .revoke],
            queue: queue)

        source.setEventHandler { [weak self] in
            guard let self, let current = self.watch else { return }
            let mask = current.data
            Task { @MainActor in
                if mask.contains(.delete) || mask.contains(.rename)
                    || mask.contains(.revoke)
                {
                    // Checkpoint replaced the log. Re-open, then read, so a
                    // commit landing during the swap is not missed.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        guard Defaults[.enableNotificationMirroring] else { return }
                        self.armWatch()
                        self.drainNewRecords()
                    }
                } else {
                    self.drainNewRecords()
                }
            }
        }
        source.setCancelHandler { close(descriptor) }

        watchedDescriptor = descriptor
        watch = source
        source.resume()
        return true
    }

    private func disarmWatch() {
        // The cancel handler closes the descriptor; doing it here as well
        // would close a number the system may already have reused.
        watch?.cancel()
        watch = nil
        watchedDescriptor = -1
    }

    private func stop() {
        disarmWatch()
        recent = []
        lastSeenID = 0
        state = .off
    }

    /// Re-checks the grant. Called from Settings after the user returns from
    /// System Settings.
    func recheckPermission() {
        guard Defaults[.enableNotificationMirroring] else { return }
        stop()
        start()
    }

    // MARK: - Reading

    private func drainNewRecords() {
        let fresh = records(after: lastSeenID)
        guard !fresh.isEmpty else { return }
        lastSeenID = max(lastSeenID, fresh.map(\.id).max() ?? lastSeenID)
        recent = (fresh.reversed() + recent).prefix(maxRecent).map { $0 }

        // Counts and sender only. Titles and bodies are the user's messages
        // and must never reach the log — the whole point of mirroring someone's
        // notifications is that they stay theirs.
        Logger.log(
            "Notification mirror: \(fresh.count) new from "
                + "\(Set(fresh.map(\.bundleID)).sorted().joined(separator: ", "))",
            category: .lifecycle)

        // Counts and sender only. Titles and bodies are the user's messages
        // and must never reach the log — os_log is readable by anything with
        // the right entitlement, which is the opposite of what mirroring
        // someone's notifications should mean.
    }

    private func highestRecordID() -> Int64? {
        var result: Int64?
        withDatabase { db in
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(
                db, "SELECT MAX(rec_id) FROM record", -1, &statement, nil) == SQLITE_OK
            else { return }
            defer { sqlite3_finalize(statement) }
            if sqlite3_step(statement) == SQLITE_ROW {
                result = sqlite3_column_int64(statement, 0)
            }
        }
        return result
    }

    /// Rows newer than `id`, oldest first.
    private func records(after id: Int64) -> [MirroredNotification] {
        var found: [MirroredNotification] = []
        withDatabase { db in
            let sql = """
                SELECT r.rec_id, a.identifier, r.data, r.delivered_date
                FROM record r JOIN app a ON a.app_id = r.app_id
                WHERE r.rec_id > ?
                ORDER BY r.rec_id ASC
                LIMIT 50
                """
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_int64(statement, 1, id)

            while sqlite3_step(statement) == SQLITE_ROW {
                let recID = sqlite3_column_int64(statement, 0)
                guard let identifierRaw = sqlite3_column_text(statement, 1) else { continue }
                let bundleID = String(cString: identifierRaw)

                guard let blob = sqlite3_column_blob(statement, 2) else { continue }
                let length = Int(sqlite3_column_bytes(statement, 2))
                guard length > 0 else { continue }
                let data = Data(bytes: blob, count: length)

                guard let parsed = Self.parse(data) else { continue }

                // Core Data-style seconds since 2001.
                let raw = sqlite3_column_double(statement, 3)
                let date = raw > 0
                    ? Date(timeIntervalSinceReferenceDate: raw)
                    : Date()

                found.append(MirroredNotification(
                    id: recID, bundleID: bundleID,
                    title: parsed.title, subtitle: parsed.subtitle,
                    body: parsed.body, date: date))
            }
        }
        return found
    }

    /// Opens read-only, runs `work`, always closes.
    ///
    /// `SQLITE_OPEN_READONLY` is not decoration — this is the system's own
    /// notification store and Anchor has no business writing to it.
    private func withDatabase(_ work: (OpaquePointer) -> Void) {
        var db: OpaquePointer?
        let opened = sqlite3_open_v2(
            databaseURL.path, &db, SQLITE_OPEN_READONLY, nil)
        guard opened == SQLITE_OK, let db else {
            if let db { sqlite3_close(db) }
            return
        }
        defer { sqlite3_close(db) }
        work(db)
    }

    /// The `data` column is a binary plist; the content sits under `req`.
    ///
    /// Keys are four-character abbreviations: `titl`, `subt`, `body`. Anything
    /// without a title is skipped — those are the silent bookkeeping records
    /// the system keeps alongside real notifications.
    private static func parse(_ data: Data) -> (title: String, subtitle: String?, body: String?)? {
        guard let root = try? PropertyListSerialization.propertyList(
            from: data, options: [], format: nil) as? [String: Any],
            let request = root["req"] as? [String: Any]
        else { return nil }

        guard let title = request["titl"] as? String, !title.isEmpty else { return nil }
        let subtitle = (request["subt"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let body = (request["body"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return (title, subtitle, body)
    }
}
