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

import SwiftUI

/// Apps currently producing audio, each with a mute toggle.
///
/// A leaf view observing `PerAppAudioManager` directly. It refreshes on appear
/// and then only when CoreAudio reports the process list changed — there is no
/// timer behind this list.
struct PerAppAudioList: View {
    @ObservedObject private var manager = PerAppAudioManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if manager.apps.isEmpty {
                Text("No apps are using audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.apps) { app in
                    row(for: app)
                    if app.id != manager.apps.last?.id { Divider() }
                }
            }
        }
        .onAppear { manager.refresh() }
    }

    private func row(for app: AudioApp) -> some View {
        let muted = manager.isMuted(app.pid)
        return HStack(spacing: 8) {
            if let bundleID = app.bundleID, let icon = AppIconAsNSImage(for: bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
                    .frame(width: 16, height: 16)
                    .foregroundStyle(.secondary)
            }

            Text(app.name)
                .lineLimit(1)

            if app.isPlaying {
                Image(systemName: "speaker.wave.2.fill")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Currently playing")
            }

            Spacer()

            Button {
                manager.toggleMute(app)
            } label: {
                Image(systemName: muted ? "speaker.slash.fill" : "speaker.fill")
                    .foregroundStyle(muted ? Color.orange : Color.secondary)
            }
            .buttonStyle(.borderless)
            .help(muted ? "Unmute \(app.name)" : "Mute \(app.name)")
        }
    }
}
