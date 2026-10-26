/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * Originally from boring.notch project
 * Modified and adapted for Atoll (DynamicIsland)
 * See NOTICE for details.
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

import SwiftUI
import Sparkle
import AnchorUtilities

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    init(updater: SPUUpdater) {}
    
    var body: some View {
        Button("App Updates…") { UtilityWorkspace.shared.showFeature("appUpdates") }
    }
}

struct UpdaterSettingsView: View {
    init(updater: SPUUpdater) {}
    
    var body: some View {
        Section {
            Text("Find available updates for the apps on this Mac and choose which ones to install.")
                .foregroundStyle(.secondary)
            Button("Open App Updates") { UtilityWorkspace.shared.showFeature("appUpdates") }
        } header: {
            HStack {
                Text("Installed apps")
            }
        }
    }
}
