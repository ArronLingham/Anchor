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

import AppKit
import AVFoundation
import Combine
import Defaults
import EventKit
import KeyboardShortcuts
import LaunchAtLogin
import LottieUI
import Sparkle
import SwiftUI
import SwiftUIIntrospect
import UniformTypeIdentifiers

// Extracted from SettingsView.swift, originally created by
// Richard Kunkli on 07/08/2024. Behaviour unchanged.

struct TimerSettings: View {
    @ObservedObject private var coordinator = AnchorViewCoordinator.shared
    @Default(.enableTimerFeature) var enableTimerFeature
    @Default(.timerPresets) private var timerPresets
    @Default(.timerIconColorMode) private var colorMode
    @Default(.timerSolidColor) private var solidColor
    @Default(.timerShowsCountdown) private var showsCountdown
    @Default(.timerShowsLabel) private var showsLabel
    @Default(.timerShowsProgress) private var showsProgress
    @Default(.timerProgressStyle) private var progressStyle
    @Default(.showTimerPresetsInNotchTab) private var showTimerPresetsInNotchTab
    @Default(.timerControlWindowEnabled) private var controlWindowEnabled
    @Default(.mirrorSystemTimer) private var mirrorSystemTimer
    @Default(.timerDisplayMode) private var timerDisplayMode
    @Default(.timerInputStyle) private var timerInputStyle
    @Default(.enableLockScreenTimerWidget) private var enableLockScreenTimerWidget
    @Default(.lockScreenTimerWidgetUsesBlur) private var timerGlassModeIsGlass
    @Default(.lockScreenTimerGlassStyle) private var lockScreenTimerGlassStyle
    @Default(.lockScreenTimerGlassCustomizationMode) private var lockScreenTimerGlassCustomizationMode
    @Default(.lockScreenTimerLiquidGlassVariant) private var lockScreenTimerLiquidGlassVariant
    @AppStorage("customTimerDuration") private var customTimerDuration: Double = 600
    @State private var customHours: Int = 0
    @State private var customMinutes: Int = 10
    @State private var customSeconds: Int = 0
    @State private var showingResetConfirmation = false

    private func highlightID(_ title: String) -> String {
        SettingsTab.timer.highlightID(for: title)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private var timerVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenTimerLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenTimerLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
    }

    private var timerSurfaceBinding: Binding<LockScreenTimerSurfaceMode> {
        Binding(
            get: { timerGlassModeIsGlass ? .glass : .classic },
            set: { mode in timerGlassModeIsGlass = (mode == .glass) }
        )
    }

    var body: some View {
        Form {
            timerFeatureSection

            if enableTimerFeature {
                timerConfigurationSections
            }
        }
        .navigationTitle("Timer")
        .onAppear { syncCustomDuration() }
        .onChange(of: customTimerDuration) { _, newValue in syncCustomDuration(newValue) }
    }

    @ViewBuilder
    private var timerFeatureSection: some View {
        Section {
            Defaults.Toggle(key: .enableTimerFeature) {
                Text("Enable timer feature")
            }
            .settingsHighlight(id: highlightID("Enable timer feature"))

            if enableTimerFeature {
                Toggle("Enable timer live activity", isOn: $coordinator.timerLiveActivityEnabled)
                    .animation(.easeInOut, value: coordinator.timerLiveActivityEnabled)
                Defaults.Toggle(key: .mirrorSystemTimer) {
                    HStack(spacing: 8) {
                        Text("Mirror macOS Clock timers")
                        alphaBadge()
                    }
                }
                .help("Shows the system Clock timer in the notch when available. Requires Accessibility permission to read the status item.")
                .settingsHighlight(id: highlightID("Mirror macOS Clock timers"))

                Picker("Timer controls appear as", selection: $timerDisplayMode) {
                    ForEach(TimerDisplayMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help(timerDisplayMode.description)
                .settingsHighlight(id: highlightID("Timer controls appear as"))
            }
        } header: {
            Text("Timer Feature")
        } footer: {
            Text("Control timer availability, live activity behaviour, and whether the app mirrors timers started from the macOS Clock app.")
        }
    }

    @ViewBuilder
    private var timerConfigurationSections: some View {
        Group {
            lockScreenIntegrationSection
            customTimerSection
            appearanceSection
            timerPresetsSection
            timerSoundSection
        }
        .onAppear {
            if showsLabel {
                controlWindowEnabled = false
            }
        }
        .onChange(of: showsLabel) { _, show in
            if show {
                controlWindowEnabled = false
            }
        }
    }

    @ViewBuilder
    private var lockScreenIntegrationSection: some View {
        Section {
            Defaults.Toggle(key: .enableLockScreenTimerWidget) {
                Text("Show lock screen timer widget")
            }
            .settingsHighlight(id: highlightID("Show lock screen timer widget"))
            Picker("Timer surface", selection: timerSurfaceBinding) {
                ForEach(LockScreenTimerSurfaceMode.allCases) { mode in
                    Text(mode.localizedName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!enableLockScreenTimerWidget)
            .opacity(enableLockScreenTimerWidget ? 1 : 0.5)
            .settingsHighlight(id: highlightID("Timer surface"))

            if timerGlassModeIsGlass {
                Picker("Timer glass material", selection: $lockScreenTimerGlassStyle) {
                    ForEach(LockScreenGlassStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .disabled(!enableLockScreenTimerWidget)
                .opacity(enableLockScreenTimerWidget ? 1 : 0.5)
                .settingsHighlight(id: highlightID("Timer glass material"))

                if lockScreenTimerGlassStyle == .liquid {
                    Picker("Timer liquid mode", selection: $lockScreenTimerGlassCustomizationMode) {
                        ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .disabled(!enableLockScreenTimerWidget)
                    .opacity(enableLockScreenTimerWidget ? 1 : 0.5)
                    .settingsHighlight(id: highlightID("Timer liquid mode"))

                    if lockScreenTimerGlassCustomizationMode == .customLiquid {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text("Timer widget variant")
                                Spacer()
                                Text("v\(lockScreenTimerLiquidGlassVariant.rawValue)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Slider(value: timerVariantBinding, in: liquidVariantRange, step: 1)
                        }
                        .settingsHighlight(id: highlightID("Timer widget variant"))
                        .disabled(!enableLockScreenTimerWidget)
                        .opacity(enableLockScreenTimerWidget ? 1 : 0.4)
                    }
                } else {
                    Text("Uses the frosted blur treatment while glass mode is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                Text("Classic mode keeps the original translucent black background.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(enableLockScreenTimerWidget ? 1 : 0.5)
            }
        } header: {
            Text("Lock Screen Integration")
        } footer: {
            Text("Mirrors the toggle found under Lock Screen settings so timer-specific workflows can enable or disable the widget without switching tabs.")
        }
    }

    @ViewBuilder
    private var customTimerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 12) {
                Text("Default Custom Timer")
                    .font(.headline)

                TimerDurationStepperRow(title: String(localized: "Hours"), value: $customHours, range: 0...23)
                TimerDurationStepperRow(title: String(localized: "Minutes"), value: $customMinutes, range: 0...59)
                TimerDurationStepperRow(title: String(localized: "Seconds"), value: $customSeconds, range: 0...59)

                HStack {
                    Text("Current default:")
                        .foregroundStyle(.secondary)
                    Text(customDurationDisplay)
                        .font(.system(.body, design: .monospaced))
                        .fontWeight(.medium)
                    Spacer()
                }
            }
            .padding(.vertical, 4)
            .onChange(of: customHours) { _, _ in updateCustomDuration() }
            .onChange(of: customMinutes) { _, _ in updateCustomDuration() }
            .onChange(of: customSeconds) { _, _ in updateCustomDuration() }
        } header: {
            Text("Custom Timer")
        } footer: {
            Text("This duration powers the \"Custom\" option inside the timer popover for quick access.")
        }
    }

    @ViewBuilder
    private var appearanceSection: some View {
        Section {
            Picker("Timer tint", selection: $colorMode) {
                ForEach(TimerIconColorMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .settingsHighlight(id: highlightID("Timer tint"))

            if colorMode == .solid {
                ColorPicker("Solid colour", selection: $solidColor, supportsOpacity: false)
                    .settingsHighlight(id: highlightID("Solid colour"))
            }

            Picker("Custom timer style", selection: $timerInputStyle) {
                ForEach(TimerInputStyle.allCases) { style in
                    Text(style.displayName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .settingsHighlight(id: highlightID("Custom timer style"))

            Toggle("Show timer name", isOn: $showsLabel)
            Toggle("Show countdown", isOn: $showsCountdown)
            Toggle("Show progress", isOn: $showsProgress)
            Toggle("Show preset list in timer tab", isOn: $showTimerPresetsInNotchTab)
                .settingsHighlight(id: highlightID("Show preset list in timer tab"))

            Toggle("Show floating pause/stop controls", isOn: $controlWindowEnabled)
                .disabled(showsLabel)
                .help("These controls sit beside the notch while a timer runs. They require the timer name to stay hidden for spacing.")

            Picker("Progress style", selection: $progressStyle) {
                ForEach(TimerProgressStyle.allCases) { style in
                    Text(style.localizedName).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .disabled(!showsProgress)
            .settingsHighlight(id: highlightID("Progress style"))
        } header: {
            Text("Appearance")
        } footer: {
            Text("Configure how the timer looks inside the closed notch. Progress can render as a ring around the icon or as horizontal bars.")
        }
    }

    @ViewBuilder
    private var timerPresetsSection: some View {
        Section {
            if timerPresets.isEmpty {
                Text("No presets configured. Add a preset to make it appear in the timer popover.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                TimerPresetListView(
                    presets: $timerPresets,
                    highlightProvider: highlightID,
                    moveUp: movePresetUp,
                    moveDown: movePresetDown,
                    remove: removePreset
                )
            }

            HStack {
                Button(action: addPreset) {
                    Label("Add Preset", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Spacer()

                Button(role: .destructive, action: { showingResetConfirmation = true }) {
                    Label("Restore Defaults", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .confirmationDialog("Restore default timer presets?", isPresented: $showingResetConfirmation, titleVisibility: .visible) {
                    Button("Restore", role: .destructive, action: resetPresets)
                }
            }
        } header: {
            Text("Timer Presets")
        } footer: {
            Text("Presets show up inside the timer popover with the configured name, duration, and accent colour. Reorder them to change the display order.")
        }
    }

    @ViewBuilder
    private var timerSoundSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Timer Sound")
                        .font(.system(size: 16, weight: .medium))
                    Spacer()
                    Button("Choose File", action: selectCustomTimerSound)
                        .buttonStyle(.bordered)
                }

                if let customTimerSoundPath = UserDefaults.standard.string(forKey: "customTimerSoundPath") {
                    Text("Custom: \(URL(fileURLWithPath: customTimerSoundPath).lastPathComponent)")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Default: dynamic.m4a")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Button("Reset to Default") {
                    UserDefaults.standard.removeObject(forKey: "customTimerSoundPath")
                }
                .buttonStyle(.bordered)
                .disabled(UserDefaults.standard.string(forKey: "customTimerSoundPath") == nil)
            }
        } header: {
            Text("Timer Sound")
        } footer: {
            Text("Select a custom sound to play when a timer ends. Supported formats include MP3, M4A, WAV, and AIFF.")
        }
    }

    private var customDurationDisplay: String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = customTimerDuration >= 3600 ? [.hour, .minute, .second] : [.minute, .second]
        formatter.zeroFormattingBehavior = [.pad]
        return formatter.string(from: customTimerDuration) ?? "0:00"
    }

    private func syncCustomDuration(_ value: Double? = nil) {
        let baseValue = value ?? customTimerDuration
        let components = TimerPreset.components(for: baseValue)
        customHours = components.hours
        customMinutes = components.minutes
        customSeconds = components.seconds
    }

    private func updateCustomDuration() {
        let duration = TimeInterval(customHours * 3600 + customMinutes * 60 + customSeconds)
        customTimerDuration = duration
    }

    private func addPreset() {
        let nextIndex = timerPresets.count + 1
        let defaultColor = Defaults[.accentColor]
        let newPreset = TimerPreset(name: "Preset \(nextIndex)", duration: 5 * 60, color: defaultColor)
        withAnimation(.smooth) {
            timerPresets.append(newPreset)
        }
    }

    private func movePresetUp(_ index: Int) {
        guard index > timerPresets.startIndex else { return }
        withAnimation(.smooth) {
            timerPresets.swapAt(index, index - 1)
        }
    }

    private func movePresetDown(_ index: Int) {
        guard index < timerPresets.index(before: timerPresets.endIndex) else { return }
        withAnimation(.smooth) {
            timerPresets.swapAt(index, index + 1)
        }
    }

    private func removePreset(_ index: Int) {
        guard timerPresets.indices.contains(index) else { return }
        withAnimation(.smooth) {
            timerPresets.remove(at: index)
        }
    }

    private func resetPresets() {
        withAnimation(.smooth) {
            timerPresets = TimerPreset.defaultPresets
        }
    }

    private func selectCustomTimerSound() {
        let panel = NSOpenPanel()
        panel.title = "Select Timer Sound"
        panel.allowedContentTypes = [.audio]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true

        if panel.runModal() == .OK {
            if let url = panel.url {
                UserDefaults.standard.set(url.path, forKey: "customTimerSoundPath")
            }
        }
    }
}

private struct TimerDurationStepperRow: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            HStack {
                Text(title)
                Spacer()
                Text("\(value)")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
            }
        }
    }
}

private struct TimerPresetListView: View {
    @Binding var presets: [TimerPreset]
    let highlightProvider: (String) -> String
    let moveUp: (Int) -> Void
    let moveDown: (Int) -> Void
    let remove: (Int) -> Void

    var body: some View {
        ForEach(presets.indices, id: \.self) { index in
            presetRow(at: index)
        }
    }

    @ViewBuilder
    private func presetRow(at index: Int) -> some View {
        TimerPresetEditorRow(
            preset: $presets[index],
            isFirst: index == presets.startIndex,
            isLast: index == presets.index(before: presets.endIndex),
            highlightID: highlightID(for: index),
            moveUp: { moveUp(index) },
            moveDown: { moveDown(index) },
            remove: { remove(index) }
        )
    }

    private func highlightID(for index: Int) -> String? {
        index == presets.startIndex ? highlightProvider("Accent colour") : nil
    }
}

private struct TimerPresetEditorRow: View {
    @Binding var preset: TimerPreset
    let isFirst: Bool
    let isLast: Bool
    let moveUp: () -> Void
    let moveDown: () -> Void
    let remove: () -> Void
    let highlightID: String?

    init(
        preset: Binding<TimerPreset>,
        isFirst: Bool,
        isLast: Bool,
        highlightID: String? = nil,
        moveUp: @escaping () -> Void,
        moveDown: @escaping () -> Void,
        remove: @escaping () -> Void
    ) {
        _preset = preset
        self.isFirst = isFirst
        self.isLast = isLast
        self.highlightID = highlightID
        self.moveUp = moveUp
        self.moveDown = moveDown
        self.remove = remove
    }

    private var components: TimerPreset.DurationComponents {
        TimerPreset.components(for: preset.duration)
    }

    private var hoursBinding: Binding<Int> {
        Binding(
            get: { components.hours },
            set: { updateDuration(hours: $0) }
        )
    }

    private var minutesBinding: Binding<Int> {
        Binding(
            get: { components.minutes },
            set: { updateDuration(minutes: $0) }
        )
    }

    private var secondsBinding: Binding<Int> {
        Binding(
            get: { components.seconds },
            set: { updateDuration(seconds: $0) }
        )
    }

    private var colorBinding: Binding<Color> {
        Binding(
            get: { preset.color },
            set: { preset.updateColor($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Circle()
                    .fill(preset.color.gradient)
                    .frame(width: 20, height: 20)
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(0.3), lineWidth: 1)
                    )

                TextField("Preset name", text: $preset.name)
                    .textFieldStyle(.roundedBorder)

                Spacer()

                Text(preset.formattedDuration)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 16) {
                TimerPresetComponentControl(title: String(localized: "Hours"), value: hoursBinding, range: 0...23)
                TimerPresetComponentControl(title: String(localized: "Minutes"), value: minutesBinding, range: 0...59)
                TimerPresetComponentControl(title: String(localized: "Seconds"), value: secondsBinding, range: 0...59)
            }

            ColorPicker("Accent colour", selection: colorBinding, supportsOpacity: false)
                .frame(maxWidth: 240, alignment: .leading)

            HStack(spacing: 12) {
                Button(action: moveUp) {
                    Label("Move Up", systemImage: "chevron.up")
                }
                .buttonStyle(.bordered)
                .disabled(isFirst)

                Button(action: moveDown) {
                    Label("Move Down", systemImage: "chevron.down")
                }
                .buttonStyle(.bordered)
                .disabled(isLast)

                Spacer()

                Button(role: .destructive, action: remove) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.bordered)
            }
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.vertical, 6)
        .settingsHighlightIfPresent(highlightID)
    }

    private func updateDuration(hours: Int? = nil, minutes: Int? = nil, seconds: Int? = nil) {
        var values = components
        if let hours { values.hours = hours }
        if let minutes { values.minutes = minutes }
        if let seconds { values.seconds = seconds }
        preset.duration = TimerPreset.duration(from: values)
    }
}

private struct TimerPresetComponentControl: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        Stepper(value: $value, in: range) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("\(value)")
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
        }
        .frame(width: 110, alignment: .leading)
    }
}
