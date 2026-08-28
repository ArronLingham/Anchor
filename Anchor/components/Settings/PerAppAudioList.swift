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

/// Apps currently producing audio, each with a volume slider and a mute button.
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
        return VStack(alignment: .leading, spacing: 4) {
            header(for: app, muted: muted)
            slider(for: app, muted: muted)
        }
    }

    private func header(for app: AudioApp, muted: Bool) -> some View {
        HStack(spacing: 8) {
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

    /// The gain slider.
    ///
    /// 0–200%, with 100% as the resting point. Anything other than 100% builds
    /// a real audio path — a tap, a private aggregate device and an IOProc — so
    /// the slider snapping back to exactly 100% is what tears all of that down
    /// again rather than leaving a no-op multiply running.
    private func slider(for app: AudioApp, muted: Bool) -> some View {
        let binding = Binding<Double>(
            get: { manager.gain(for: app) },
            set: { manager.setGain(snapped($0), for: app) })

        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Slider(value: binding, in: 0...2)
                .controlSize(.small)
                .disabled(muted || app.bundleID == nil)

            Text("\(Int(manager.gain(for: app) * 100))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)

            if manager.isVolumeEngaged(app.pid) {
                Image(systemName: "waveform.badge.magnifyingglass")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .help("Anchor is re-rendering this app's audio")
            }
        }
        .padding(.leading, 24)
    }

    /// Snaps near 100% so the resting point is reachable by dragging.
    private func snapped(_ value: Double) -> Double {
        abs(value - 1) < 0.04 ? 1 : value
    }
}
