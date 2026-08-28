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

/// A user-created EQ preset — a named EQ curve that can be applied to any app.
/// Stored in SettingsManager alongside built-in presets (EQPreset enum) which are not modified.
struct UserEQPreset: Codable, Equatable, Identifiable {
    /// Stable unique identifier for this preset.
    let id: UUID

    /// User-provided display name (e.g., "My Bass Boost", "Studio Monitor Correction").
    var name: String

    /// The EQ band gains for this preset. Reuses the existing EQSettings model.
    /// The `isEnabled` field on EQSettings is ignored for presets — it's per-app state.
    /// When applying a preset to an app, the caller should copy `bandGains` only.
    var settings: EQSettings

    /// When the preset was created (for display ordering).
    let createdAt: Date

    init(id: UUID = UUID(), name: String, settings: EQSettings, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
    }
}
