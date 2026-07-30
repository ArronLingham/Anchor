/*
 * Anchor
 * Copyright (C) 2026 Arron Baskaralingham
 *
 * Derived from Atoll (DynamicIsland), Copyright (C) 2024-2026 Atoll
 * Contributors, itself derived from the boring.notch project. See NOTICE.
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

/// Carries settings across the rename from Atoll to Anchor.
///
/// `UserDefaults` is keyed by bundle identifier, so changing
/// `com.Ebullioscopic.Atoll` to `com.arronlingham.Anchor` would otherwise
/// silently reset every preference — around 300 keys, including the ones the
/// user has deliberately changed. macOS re-prompts for TCC permissions either
/// way (those are tied to the identifier and signature and cannot be carried
/// over), but there is no reason to lose the settings too.
///
/// Runs once. Never overwrites a value that already exists under the new
/// identifier, so it cannot clobber anything set since the rename.
enum PreferencesMigration {
    private static let legacyDomains = [
        "com.Ebullioscopic.Atoll",
        "com.Ebullioscopic.Atoll.dev",
    ]
    private static let completionKey = "didMigrateFromAtollBundleIdentifier"

    static func runIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: completionKey) else { return }

        var migrated = 0
        for domain in legacyDomains {
            guard let legacy = UserDefaults(suiteName: domain) else { continue }
            for (key, value) in legacy.dictionaryRepresentation() {
                // Skip Apple's own global keys, which leak into every domain's
                // dictionaryRepresentation() and must not be copied around.
                guard !key.hasPrefix("Apple"), !key.hasPrefix("NS"), !key.hasPrefix("com.apple.")
                else { continue }
                guard defaults.object(forKey: key) == nil else { continue }
                defaults.set(value, forKey: key)
                migrated += 1
            }
        }

        defaults.set(true, forKey: completionKey)
        if migrated > 0 {
            NSLog("PreferencesMigration: carried \(migrated) settings over from Atoll")
        }
    }
}
