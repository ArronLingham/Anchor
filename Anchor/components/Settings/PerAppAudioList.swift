/*
 * Anchor
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

/// Apps currently producing audio, each with mute, volume and a 10-band EQ.
///
/// Built in Anchor's own settings idiom rather than porting FineTune's glass
/// components, which carry their own design system and would read as a
/// different app bolted into this pane. The behaviour is FineTune's; the look
/// is Anchor's.
struct PerAppAudioList: View {
    @ObservedObject private var manager = PerAppAudioManager.shared
    @State private var expanded: Set<pid_t> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if manager.permission == .denied {
                permissionNotice
            }

            if let failure = manager.lastFailure {
                failureNotice(failure)
            }

            if manager.apps.isEmpty {
                Text("No apps are using audio.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(manager.apps) { app in
                    row(for: app)
                    if app.id != manager.apps.last?.id {
                        Divider()
                    }
                }
            }
        }
        .onAppear { manager.refresh() }
    }

    // MARK: - Notices

    private var permissionNotice: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("Anchor needs permission to capture audio.")
                    .font(.callout)
                Text("Without it a tap is created but produces nothing, so volume and EQ do nothing at all.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Grant Permission") { manager.requestPermission() }
                    .controlSize(.small)
            }
        }
        .padding(9)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
    }

    private func failureNotice(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "waveform.badge.exclamationmark")
                .foregroundStyle(.red)
            VStack(alignment: .leading, spacing: 2) {
                Text("The audio engine could not start.")
                    .font(.callout)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The app is playing at normal volume — nothing is left muted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(Color.red.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Rows

    private func row(for app: AudioApp) -> some View {
        let state = manager.state(for: app)
        let isOpen = expanded.contains(app.id)

        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 17, height: 17)

                Text(app.name).lineLimit(1)

                if app.isHelperBacked {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .help("Plays through helper processes — all of them are tapped")
                }

                if manager.isEngaged(app.id) {
                    Image(systemName: "waveform")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .help("Anchor is re-rendering this app's audio")
                }

                Spacer()

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        if isOpen { expanded.remove(app.id) } else { expanded.insert(app.id) }
                    }
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(state.eqEnabled ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help("Equaliser")

                Button {
                    manager.toggleMute(app)
                } label: {
                    Image(systemName: state.isMuted ? "speaker.slash.fill" : "speaker.fill")
                        .foregroundStyle(state.isMuted ? Color.orange : Color.secondary)
                }
                .buttonStyle(.borderless)
                .help(state.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
            }

            volumeRow(for: app, state: state)

            if isOpen {
                equaliser(for: app, state: state)
            }
        }
        .padding(.vertical, 2)
    }

    /// 0–200%, resting at 100%.
    ///
    /// Anything off 100% builds a real audio path — a tap, a private aggregate
    /// device and an IOProc — so the slider snapping back to exactly 100% is
    /// what tears that down again.
    private func volumeRow(for app: AudioApp, state: PerAppAudioState) -> some View {
        let binding = Binding<Double>(
            get: { Double(manager.volume(for: app)) },
            set: { manager.setVolume(Float(snapped($0)), for: app) })

        return HStack(spacing: 8) {
            Image(systemName: "speaker.fill")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Slider(value: binding, in: 0...2)
                .controlSize(.small)
                .disabled(state.isMuted)

            Text("\(Int(state.volume * 100))%")
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 38, alignment: .trailing)
        }
        .padding(.leading, 25)
    }

    private func snapped(_ value: Double) -> Double {
        abs(value - 1) < 0.04 ? 1 : value
    }

    // MARK: - Equaliser

    private func equaliser(for app: AudioApp, state: PerAppAudioState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Equaliser", isOn: Binding(
                    get: { state.eqEnabled },
                    set: { on in
                        var next = state.eqSettings
                        next.isEnabled = on
                        manager.setEQ(next, for: app)
                    }))
                .toggleStyle(.switch)
                .controlSize(.mini)

                Spacer()

                Menu {
                    ForEach(EQPreset.Category.allCases) { category in
                        Section(category.rawValue) {
                            ForEach(EQPreset.presets(for: category)) { preset in
                                Button(preset.name) { manager.applyPreset(preset, to: app) }
                            }
                        }
                    }
                } label: {
                    Text("Presets")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(!state.eqEnabled)
            }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach(Array(EQSettings.frequencies.enumerated()), id: \.offset) { index, frequency in
                    band(index: index, frequency: frequency, app: app, state: state)
                }
            }
            .disabled(!state.eqEnabled)
            .opacity(state.eqEnabled ? 1 : 0.4)

            Text("Ten bands, −12 to +12 dB. Stereo only — a multichannel stream bypasses it.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.leading, 25)
        .padding(.top, 2)
        .transition(.opacity)
    }

    private func band(index: Int, frequency: Double, app: AudioApp, state: PerAppAudioState) -> some View {
        let binding = Binding<Double>(
            get: { Double(state.eqBandGains.indices.contains(index) ? state.eqBandGains[index] : 0) },
            set: { value in
                var next = state.eqSettings
                var gains = next.bandGains
                if gains.indices.contains(index) { gains[index] = Float(value) }
                next.bandGains = gains
                manager.setEQ(next, for: app)
            })

        return VStack(spacing: 3) {
            Text(String(format: "%+.0f", binding.wrappedValue))
                .font(.system(size: 8))
                .monospacedDigit()
                .foregroundStyle(.tertiary)

            Slider(value: binding, in: -12...12)
                .controlSize(.mini)
                .frame(height: 74)
                .rotationEffect(.degrees(-90))
                .frame(width: 22, height: 74)

            Text(label(for: frequency))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    private func label(for frequency: Double) -> String {
        frequency >= 1000
            ? "\(Int(frequency / 1000))k"
            : "\(Int(frequency))"
    }
}
