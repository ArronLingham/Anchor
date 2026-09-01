/*
 * Anchor
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
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

/// Anchor's directory under Application Support.
///
/// The app stored everything under `DynamicIsland/` while it was still named
/// after upstream. Renaming the constant alone would have silently abandoned
/// whatever was in there — idle animations and the file shelf's contents — so
/// the old directory is moved across once, the first time this is asked for.
enum AppSupportDirectory {
    private static let currentName = "Anchor"
    private static let legacyName = "DynamicIsland"

    /// Created on first use, with anything from the pre-rename location moved in.
    static let root: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let current = base.appendingPathComponent(currentName, isDirectory: true)
        let legacy = base.appendingPathComponent(legacyName, isDirectory: true)

        let fm = FileManager.default
        // Move rather than merge: this runs before anything has written to the
        // new location, so a plain move is the whole migration. If the new
        // directory somehow already exists, the old one is left untouched rather
        // than risking a half-merge over live data.
        if fm.fileExists(atPath: legacy.path), !fm.fileExists(atPath: current.path) {
            do {
                try fm.moveItem(at: legacy, to: current)
                NSLog("AppSupportDirectory: migrated \(legacyName) -> \(currentName)")
            } catch {
                NSLog("AppSupportDirectory: migration failed (\(error)); using \(legacyName)")
                return legacy
            }
        }

        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }()

    static func subdirectory(_ name: String) -> URL {
        let dir = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
