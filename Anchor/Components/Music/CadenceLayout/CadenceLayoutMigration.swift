/*
 * Anchor / Cadence
 * Copyright (C) 2026 Cadence Contributors
 * GPL-3.0-or-later. See the repository LICENSE and NOTICE.
 */

import Defaults
import Foundation

enum CadenceLayoutMigration {
    /// Bring a user's saved Cadence arrangements into Anchor once. The Cadence
    /// preference domain is read only; each app remains independently usable.
    static func importIfNeeded() {
        guard !Defaults[.anchorCadenceLayoutsImported] else { return }
        defer { Defaults[.anchorCadenceLayoutsImported] = true }

        // An Anchor layout already created in this install always wins.
        guard UserDefaults.standard.object(forKey: "anchorCadencePlayerLayouts") == nil,
              let source = UserDefaults(suiteName: "com.arronlingham.Cadence")
        else { return }

        let data: Data?
        if let value = source.string(forKey: "playerLayouts") {
            data = value.data(using: .utf8)
        } else {
            data = source.data(forKey: "playerLayouts")
        }
        guard let data,
              let layouts = try? JSONDecoder().decode(PlayerLayouts.self, from: data)
        else { return }

        Defaults[.playerLayouts] = PlayerLayouts.migrated(
            layouts, from: source.integer(forKey: "layoutMigration"))

        if let raw = source.string(forKey: "launcherWidgetSize"),
           let size = LauncherPlayerWidget.Size(rawValue: raw) {
            Defaults[.launcherWidgetSize] = size
        }
        if source.object(forKey: "launcherAlwaysShowsControls") != nil {
            Defaults[.launcherAlwaysShowsControls] =
                source.bool(forKey: "launcherAlwaysShowsControls")
        }
        if source.object(forKey: "playerWidth") != nil {
            Defaults[.playerWidth] = min(max(source.double(forKey: "playerWidth"), 140), 1200)
        }
        if source.object(forKey: "playerHeightBudget") != nil {
            Defaults[.playerHeightBudget] =
                max(0, source.double(forKey: "playerHeightBudget"))
        }
        if let raw = source.string(forKey: "playerWindowLevel"),
           let level = PlayerWindowLevel(rawValue: raw) {
            Defaults[.playerWindowLevel] = level
        }
        if let raw = source.string(forKey: "lockFullBackground"),
           let background = LockFullBackground(rawValue: raw) {
            Defaults[.lockFullBackground] = background
        }
        importBoolean("playerTintsWithAlbum", from: source, to: .playerTintsWithAlbum)
        importBoolean("hoverGrowsWidget", from: source, to: .hoverGrowsWidget)
        importBoolean("playerFollowsSpaces", from: source, to: .playerFollowsSpaces)
        importBoolean("playerUsesGlass", from: source, to: .playerUsesGlass)
        importBoolean("volumeControlsApp", from: source, to: .volumeControlsApp)
        if source.object(forKey: "playerBackgroundOpacity") != nil {
            Defaults[.playerBackgroundOpacity] =
                min(max(source.double(forKey: "playerBackgroundOpacity"), 0.15), 1)
        }
    }

    private static func importBoolean(
        _ sourceKey: String, from source: UserDefaults, to destination: Defaults.Key<Bool>
    ) {
        guard source.object(forKey: sourceKey) != nil else { return }
        Defaults[destination] = source.bool(forKey: sourceKey)
    }
}
