/*
 * Anchor
 * Per-app audio engine, derived from FineTune (github.com/ronitsingh10/FineTune).
 * Copyright (C) 2026 Ronit Singh
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
import os

/// Handles file I/O for AutoEQ profiles: managing imported profile files on disk.
nonisolated final class AutoEQProfileLoader {
    private let logger = os.Logger(subsystem: "com.arronlingham.Anchor", category: "AutoEQProfileLoader")

    private var importDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Anchor")
            .appendingPathComponent("AutoEQ")
    }

    // MARK: - Imported Profiles

    /// Loads imported profiles synchronously from the import directory.
    func loadImportedProfiles() -> [AutoEQProfile] {
        let dir = importDirectory
        guard FileManager.default.fileExists(atPath: dir.path) else { return [] }

        var profiles: [AutoEQProfile] = []
        do {
            let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .filter { $0.pathExtension == "txt" }
            for file in files {
                let text = try String(contentsOf: file, encoding: .utf8)
                let stableID = file.deletingPathExtension().lastPathComponent

                let nameFile = dir.appendingPathComponent("\(stableID).name")
                let displayName = (try? String(contentsOf: nameFile, encoding: .utf8))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? stableID

                if let profile = AutoEQParser.parse(text: text, name: displayName, source: .imported, id: stableID) {
                    profiles.append(profile)
                }
            }
            logger.info("Loaded \(files.count) imported AutoEQ profiles")
        } catch {
            logger.error("Failed to load imported profiles: \(error.localizedDescription)")
        }
        return profiles
    }

    // MARK: - Import / Delete on Disk

    /// Import a ParametricEQ.txt file. Copies to import directory and returns parsed profile.
    func importProfile(from url: URL, name: String) -> AutoEQProfile? {
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            guard let profile = AutoEQParser.parse(text: text, name: name, source: .imported) else {
                logger.warning("Failed to parse imported file: \(name)")
                return nil
            }

            let dir = importDirectory
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let dest = dir.appendingPathComponent("\(profile.id).txt")
            try text.write(to: dest, atomically: true, encoding: .utf8)
            let nameFile = dir.appendingPathComponent("\(profile.id).name")
            try name.write(to: nameFile, atomically: true, encoding: .utf8)

            logger.info("Imported AutoEQ profile: \(name)")
            return profile
        } catch {
            logger.error("Failed to import profile: \(error.localizedDescription)")
            return nil
        }
    }

    /// Delete an imported profile's files from disk.
    func deleteProfileFiles(id: String) {
        let dir = importDirectory
        let file = dir.appendingPathComponent("\(id).txt")
        let nameFile = dir.appendingPathComponent("\(id).name")
        try? FileManager.default.removeItem(at: file)
        try? FileManager.default.removeItem(at: nameFile)
    }
}
