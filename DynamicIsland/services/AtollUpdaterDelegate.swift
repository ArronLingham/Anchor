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

import Defaults
import Sparkle

/// Sparkle updater delegate.
///
/// Returns no feed. Anchor is a personal fork that is never distributed, so
/// there is nothing to update *from* — and every channel in `UpdateChannel`
/// still points at upstream Atoll's appcast. Leaving that wired up means
/// Sparkle cheerfully replaces Anchor with upstream Atoll on its own schedule,
/// which is exactly what happened to the copy in /Applications (it self-updated
/// from v2.2.0 to upstream v2.3.3 mid-development).
class AtollUpdaterDelegate: NSObject, SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        nil
    }

    func updaterShouldPromptForPermissionToCheck(forUpdates updater: SPUUpdater) -> Bool {
        false
    }
}
