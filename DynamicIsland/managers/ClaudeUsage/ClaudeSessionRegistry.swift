/*
 * Atoll (DynamicIsland)
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

import Foundation

struct ClaudeLiveSession: Equatable {
    let pid: pid_t
    let sessionId: String
    let cwd: String
    let name: String?
    let startedAt: Date
}

/// The set of Claude Code processes running right now.
///
/// Claude Code drops one `<pid>.json` into `~/.claude/sessions/` per running
/// process and removes it on exit — but only on a *clean* exit, so a crash or a
/// force-quit leaves the file behind. Every entry is therefore re-checked against
/// the process table before it is reported.
///
/// Queried on demand only. There is deliberately no timer, no `FSEvents` watcher
/// and no cached state here: the directory holds a handful of files under 300
/// bytes, so a caller that needs a fresh answer can just ask for one.
enum ClaudeSessionRegistry {
    static func liveSessions() -> [ClaudeLiveSession] {
        let directory = sessionsDirectory
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        let sessions = entries
            .filter { $0.pathExtension == "json" }
            .compactMap(session(at:))
            .filter { isRunning($0.pid) }

        // contentsOfDirectory has no defined order; newest-first is the order a
        // caller looking for "the session that just stopped" wants to scan in.
        return sessions.sorted { $0.startedAt > $1.startedAt }
    }

    static func isAlive(sessionId: String) -> Bool {
        liveSessions().contains { $0.sessionId == sessionId }
    }

    private static var sessionsDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".claude", directoryHint: .isDirectory)
            .appending(path: "sessions", directoryHint: .isDirectory)
    }

    /// Mirrors the on-disk file. Every field beyond `sessionId` is optional —
    /// Claude Code adds and drops keys between versions, and one file written by
    /// a different version must not take the whole enumeration down with it.
    private struct SessionRecord: Decodable {
        let pid: pid_t?
        let sessionId: String
        let cwd: String?
        let name: String?
        let startedAt: Double?
    }

    private static func session(at url: URL) -> ClaudeLiveSession? {
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(SessionRecord.self, from: data)
        else { return nil }

        // The filename is the pid, so a file missing the field is still usable.
        guard let pid = record.pid ?? pid_t(url.deletingPathExtension().lastPathComponent)
        else { return nil }

        return ClaudeLiveSession(
            pid: pid,
            sessionId: record.sessionId,
            cwd: record.cwd ?? "",
            name: record.name,
            startedAt: startDate(from: record.startedAt, fileAt: url)
        )
    }

    /// `startedAt` is milliseconds since the epoch, not seconds.
    private static func startDate(from milliseconds: Double?, fileAt url: URL) -> Date {
        if let milliseconds {
            return Date(timeIntervalSince1970: milliseconds / 1000)
        }
        let created = try? url.resourceValues(forKeys: [.creationDateKey]).creationDate
        return created ?? .distantPast
    }

    private static func isRunning(_ pid: pid_t) -> Bool {
        // pid 0 addresses the caller's whole process group, and negative pids a
        // group by id — neither answers the question being asked here.
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        // EPERM means the process exists but belongs to another user; only ESRCH
        // means it is gone.
        return errno == EPERM
    }
}
