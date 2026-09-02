import Defaults
import SwiftUI
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



/// Apps currently producing audio, each with mute, volume and a 10-band EQ.
///
/// Built in Anchor's own settings idiom rather than porting FineTune's glass
/// components, which carry their own design system and would read as a
/// different app bolted into this pane. The behaviour is FineTune's; the look
/// is Anchor's.
struct PerAppAudioList: View {
    @Default(.perAppVolumeMode) private var perAppVolumeMode
    @Default(.showPerAppVolumeControl) private var showPerAppVolumeControl
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
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 17, height: 17)

                Text(app.name).lineLimit(1)

                if app.isHelperBacked {
                    Image(systemName: "square.stack.3d.up")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .settingsInfo("Plays through helper processes — all of them are tapped")
                }

                Spacer()

                if showPerAppVolumeControl {
                    volumeStepButton(for: app, state: state)
                    // Mute is its own control only in booster mode. In presets
                    // mode silence IS a step, so a second control for it would
                    // be two ways to say the same thing.
                    if perAppVolumeMode == .booster {
                        muteButton(for: app, state: state)
                    }
                }

                equaliserButton(for: app, state: state, isOpen: isOpen)
                outputButton(for: app, state: state)
            }

            if isOpen {
                equaliser(for: app, state: state)
                    .padding(.top, 4)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 2)
    }

    // MARK: - Row controls

    /// Which step the app is currently on, derived from its gain rather than
    /// stored — so the button always agrees with the engine even if the volume
    /// was set from somewhere else.
    private func currentStep(_ state: PerAppAudioState) -> Int {
        let mode = perAppVolumeMode
        if mode == .presets && state.isMuted { return 0 }
        let levels = mode.levels
        let v = state.volume
        // Nearest level, so a value that came from anywhere else still lands on
        // a sensible icon instead of falling off the end.
        var best = 0
        var bestDistance = Float.greatestFiniteMagnitude
        for (i, level) in levels.enumerated() where !(mode == .presets && i == 0) {
            let d = abs(level - v)
            if d < bestDistance { bestDistance = d; best = i }
        }
        return best
    }

    private func applyStep(_ step: Int, to app: AudioApp) {
        let mode = perAppVolumeMode
        let levels = mode.levels
        guard levels.indices.contains(step) else { return }
        if mode == .presets {
            if step == 0 {
                manager.setMuted(true, for: app)
            } else {
                manager.setMuted(false, for: app)
                manager.setVolume(levels[step], for: app)
            }
        } else {
            manager.setVolume(levels[step], for: app)
        }
    }

    /// The volume control: one button whose soundwave count is the level.
    ///
    /// A click advances a step and wraps. There is no slider — the point of the
    /// step design is that the whole control is one glanceable icon.
    private func volumeStepButton(for app: AudioApp, state: PerAppAudioState) -> some View {
        let mode = perAppVolumeMode
        let step = currentStep(state)
        let symbols = mode.symbols
        let symbol = symbols.indices.contains(step) ? symbols[step] : symbols[0]
        let silent = (mode == .presets && step == 0) || state.isMuted

        return Button {
            let next = (step + 1) % mode.levels.count
            applyStep(next, to: app)
        } label: {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(silent ? Color.orange : (step > (mode == .presets ? 1 : 0) ? Color.accentColor : Color.secondary))
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(stepDescription(step, mode: mode, app: app))
    }

    private func stepDescription(_ step: Int, mode: PerAppVolumeMode, app: AudioApp) -> String {
        let names: [String]
        switch mode {
        case .presets: names = ["Muted", "Regular", "Loud", "Louder"]
        case .booster: names = ["Normal", "Louder", "Loudest"]
        }
        let name = names.indices.contains(step) ? names[step] : "—"
        return "\(app.name): \(name). Click to cycle."
    }

    /// Booster-mode mute: headphones with a line through them.
    ///
    /// SF Symbols has no headphones.slash, so the line is drawn — which also
    /// lets it animate with the tint rather than swapping glyphs.
    private func muteButton(for app: AudioApp, state: PerAppAudioState) -> some View {
        Button {
            manager.toggleMute(app)
        } label: {
            Image(systemName: "headphones")
                .font(.system(size: 12))
                .foregroundStyle(state.isMuted ? Color.orange : Color.secondary)
                .overlay {
                    if state.isMuted {
                        Rectangle()
                            .fill(Color.orange)
                            .frame(width: 15, height: 1.5)
                            .rotationEffect(.degrees(-45))
                    }
                }
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(state.isMuted ? "Unmute \(app.name)" : "Mute \(app.name)")
    }

    private func equaliserButton(for app: AudioApp, state: PerAppAudioState, isOpen: Bool) -> some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) {
                if isOpen { expanded.remove(app.id) } else { expanded.insert(app.id) }
            }
        } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.system(size: 12))
                .foregroundStyle(state.eqEnabled ? Color.accentColor : Color.secondary)
                .frame(width: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help("Equaliser")
    }

    /// Where this app's audio goes, and the only place Anchor advertises that it
    /// is touching the app at all.
    ///
    /// The engaged indicator used to be a separate blue waveform beside the
    /// name. It is a tint on this icon instead: quieter, and it points at the
    /// thing doing the work rather than sitting next to the app like a warning.
    private func outputButton(for app: AudioApp, state: PerAppAudioState) -> some View {
        let engaged = manager.isEngaged(app.id)
        let routed = state.outputDeviceUID != nil

        return Menu {
            Button {
                manager.setOutputDevice(nil, for: app)
            } label: {
                if !routed { Image(systemName: "checkmark") }
                Text("Follow system output")
            }
            Divider()
            ForEach(manager.availableOutputDevices, id: \.uid) { device in
                Button {
                    manager.setOutputDevice(device.uid, for: app)
                } label: {
                    if state.outputDeviceUID == device.uid { Image(systemName: "checkmark") }
                    Text(device.name)
                }
            }
        } label: {
            Image(systemName: routed ? "airpodspro" : "hifispeaker")
                .font(.system(size: 12))
                .foregroundStyle(engaged ? Color.teal : Color.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(outputHelp(engaged: engaged, state: state))
    }

    private func outputHelp(engaged: Bool, state: PerAppAudioState) -> String {
        let where_ = state.outputDeviceUID
            .flatMap { uid in manager.availableOutputDevices.first { $0.uid == uid }?.name }
            ?? String(localized: "the system output")
        return engaged
            ? String(localized: "Anchor is re-rendering this app's audio to \(where_)")
            : String(localized: "Playing on \(where_)")
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

                // A Picker rather than a Menu button, so the pane shows which
                // preset is in force instead of only offering the list. There
                // is no stored "current preset" — the engine holds gains — so
                // it is derived by matching them, and reads Custom once you
                // move a band.
                Picker("Preset", selection: presetBinding(for: app, state: state)) {
                    Text("Custom").tag(nil as EQPreset?)
                    ForEach(EQPreset.Category.allCases) { category in
                        Section(category.rawValue) {
                            ForEach(EQPreset.presets(for: category)) { preset in
                                Text(preset.name).tag(preset as EQPreset?)
                            }
                        }
                    }
                }
                .labelsHidden()
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

    /// Which preset the current gains correspond to, or nil for Custom.
    ///
    /// Matching with a tolerance rather than exact equality: gains round-trip
    /// through Float and a preset applied a moment ago should still read as
    /// that preset.
    private func presetBinding(for app: AudioApp, state: PerAppAudioState) -> Binding<EQPreset?> {
        Binding<EQPreset?>(
            get: {
                let gains = state.eqBandGains
                return EQPreset.allCases.first { preset in
                    let want = preset.settings.bandGains
                    guard want.count == gains.count else { return false }
                    return zip(want, gains).allSatisfy { abs($0 - $1) < 0.05 }
                }
            },
            set: { preset in
                guard let preset else { return }   // choosing Custom changes nothing
                manager.applyPreset(preset, to: app)
            })
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

            EQSlider(value: binding)
                .frame(width: 22, height: 74)

            Text(label(for: frequency))
                .font(.system(size: 8))
                .foregroundStyle(.tertiary)
        }
    }

    private func label(for frequency: Double) -> String {
        frequency >= 1000
            ? "\(Int((frequency / 1000).rounded()))k"
            // 31.25 and 62.5 are the real ISO centres; truncating shows 31/62
            // where every EQ in the world prints 32/64.
            : "\(Int(frequency.rounded()))"
    }
}


struct EQSlider: View {
    @Binding var value: Double // -12 to 12
    let range: ClosedRange<Double> = -12...12
    
    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height
            let percentage = (value - range.lowerBound) / (range.upperBound - range.lowerBound)
            
            ZStack(alignment: .bottom) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.15))
                    .frame(width: 12)
                
                RoundedRectangle(cornerRadius: 4)
                    .fill(value == 0 ? Color.secondary : Color.accentColor)
                    .frame(width: 12, height: max(0, height * CGFloat(percentage)))
                    
                // Thumb
                Circle()
                    .fill(Color.white)
                    .shadow(radius: 1)
                    .frame(width: 16, height: 16)
                    .offset(y: -height * CGFloat(percentage) + 8)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { drag in
                        let y = height - drag.location.y
                        let p = max(0, min(1, y / height))
                        let v = range.lowerBound + Double(p) * (range.upperBound - range.lowerBound)
                        // Snap to 0 if close
                        if abs(v) < 0.5 {
                            value = 0
                        } else {
                            value = v
                        }
                    }
            )
        }
    }
}
