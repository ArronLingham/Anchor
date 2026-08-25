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

struct LockScreenSettings: View {
    @ObservedObject private var calendarManager = CalendarManager.shared
    @ObservedObject private var previewManager = LockScreenWidgetPreviewManager.shared
    @Default(.lockScreenGlassStyle) private var lockScreenGlassStyle
    @Default(.lockScreenGlassCustomizationMode) private var lockScreenGlassCustomizationMode
    @Default(.lockScreenMusicLiquidGlassVariant) private var lockScreenMusicLiquidGlassVariant
    @Default(.lockScreenTimerLiquidGlassVariant) private var lockScreenTimerLiquidGlassVariant
    @Default(.lockScreenTimerGlassStyle) private var lockScreenTimerGlassStyle
    @Default(.lockScreenTimerGlassCustomizationMode) private var lockScreenTimerGlassCustomizationMode
    @Default(.lockScreenTimerWidgetUsesBlur) private var timerGlassModeIsGlass
    @Default(.enableLockScreenMediaWidget) private var enableLockScreenMediaWidget
    @Default(.lockScreenMusicFullscreenArtworkEnabled) private var lockScreenMusicFullscreenArtworkEnabled
    @Default(.enableLockScreenTimerWidget) private var enableLockScreenTimerWidget
    @Default(.enableLockScreenWeatherWidget) private var enableLockScreenWeatherWidget
    @Default(.enableLockScreenFocusWidget) private var enableLockScreenFocusWidget
    @Default(.lockScreenWeatherWidgetStyle) private var lockScreenWeatherWidgetStyle
    @Default(.lockScreenWeatherProviderSource) private var lockScreenWeatherProviderSource
    @Default(.lockScreenWeatherTemperatureUnit) private var lockScreenWeatherTemperatureUnit
    @Default(.lockScreenBatteryShowsCharging) private var lockScreenWeatherShowsCharging
    @Default(.lockScreenBatteryShowsBatteryGauge) private var lockScreenWeatherShowsBatteryGauge
    @Default(.lockScreenWeatherShowsAQI) private var lockScreenWeatherShowsAQI
    @Default(.lockScreenWeatherShowsSunrise) private var lockScreenWeatherShowsSunrise
    @Default(.lockScreenWeatherAQIScale) private var lockScreenWeatherAQIScale
    @Default(.enableLockScreenReminderWidget) private var enableLockScreenReminderWidget
    @Default(.lockScreenReminderChipStyle) private var lockScreenReminderChipStyle
    @Default(.lockScreenReminderWidgetHorizontalAlignment) private var lockScreenReminderWidgetHorizontalAlignment
    @Default(.lockScreenReminderWidgetVerticalOffset) private var lockScreenReminderWidgetVerticalOffset
    @Default(.showStandardMediaControls) private var showStandardMediaControls
    @Default(.lockScreenShowCalendarCountdown) private var lockScreenShowCalendarCountdown
    @Default(.lockScreenShowCalendarEvent) private var lockScreenShowCalendarEvent
    @Default(.lockScreenShowCalendarEventEntireDuration) private var lockScreenShowCalendarEventEntireDuration
    @Default(.lockScreenShowCalendarEventAfterStartWindow) private var lockScreenShowCalendarEventAfterStartWindow
    @Default(.lockScreenShowCalendarTimeRemaining) private var lockScreenShowCalendarTimeRemaining
    @Default(.lockScreenShowCalendarStartTimeAfterBegins) private var lockScreenShowCalendarStartTimeAfterBegins
    @Default(.lockScreenCalendarEventLookaheadWindow) private var lockScreenCalendarEventLookaheadWindow
    @Default(.lockScreenCalendarSelectionMode) private var lockScreenCalendarSelectionMode
    @Default(.lockScreenSelectedCalendarIDs) private var lockScreenSelectedCalendarIDs
    @Default(.lockScreenShowCalendarEventAfterStartEnabled) private var lockScreenShowCalendarEventAfterStartEnabled
    @Default(.lockScreenMusicMergedAirPlayOutput) private var lockScreenMusicMergedAirPlayOutput
    @ObservedObject private var musicManager = MusicManager.shared

    private var isAppleMusicActive: Bool {
        musicManager.bundleIdentifier == "com.apple.Music"
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.lockScreen.highlightID(for: title)
    }

    private var liquidVariantRange: ClosedRange<Double> {
        Double(LiquidGlassVariant.supportedRange.lowerBound)...Double(LiquidGlassVariant.supportedRange.upperBound)
    }

    private enum CalendarLookaheadOption: String, CaseIterable, Identifiable {
        case mins15 = "15m"
        case mins30 = "30m"
        case hour1 = "1h"
        case hours3 = "3h"
        case hours6 = "6h"
        case hours12 = "12h"
        case restOfDay = "rest_of_day"
        case allTime = "all_time"

        var id: String { rawValue }

        var title: String {
            switch self {
            case .mins15: return "15 mins"
            case .mins30: return "30 mins"
            case .hour1: return "1 hour"
            case .hours3: return "3 hours"
            case .hours6: return "6 hours"
            case .hours12: return "12 hours"
            case .restOfDay: return "Rest of the day"
            case .allTime: return "All time"
            }
        }
    }

    private enum ReminderAlignmentOption: String, CaseIterable, Identifiable {
        case leading
        case center
        case trailing

        var id: String { rawValue }

        var title: String {
            switch self {
            case .leading: return "Left"
            case .center: return "Center"
            case .trailing: return "Right"
            }
        }
    }

    private var musicVariantBinding: Binding<Double> {
        Binding(
            get: { Double(lockScreenMusicLiquidGlassVariant.rawValue) },
            set: { newValue in
                let raw = Int(newValue.rounded())
                lockScreenMusicLiquidGlassVariant = LiquidGlassVariant.clamped(raw)
            }
        )
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
            Section {
                Defaults.Toggle(key: .enableLockScreenLiveActivity) {
                    Text("Enable lock screen live activity")
                }
                .settingsHighlight(id: highlightID("Enable lock screen live activity"))
                Defaults.Toggle(key: .enableLockSounds) {
                    Text("Play lock/unlock sounds")
                }
                .settingsHighlight(id: highlightID("Play lock/unlock sounds"))
            } header: {
                Text("Live Activity & Feedback")
            } footer: {
                Text("Controls whether Dynamic Island mirrors lock/unlock events with its own live activity and audible chimes.")
            }

            Section {
                Button(previewManager.isPreviewVisible ? "Hide lock screen preview" : "Preview lock screen widgets") {
                    previewManager.togglePreview()
                }
                .buttonStyle(.borderedProminent)
                .settingsHighlight(id: highlightID("Preview lock screen widgets"))
            } header: {
                Text("Preview")
            } footer: {
                Text("Opens a transparent preview window with mock data that mirrors the current lock screen widget configuration.")
            }

            Section {
                if #available(macOS 26.0, *) {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .settingsHighlight(id: highlightID("Material"))
                } else {
                    Picker("Material", selection: $lockScreenGlassStyle) {
                        ForEach(LockScreenGlassStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .disabled(true)
                    .settingsHighlight(id: highlightID("Material"))
                    Text("Liquid Glass requires macOS 26 or later.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if lockScreenGlassStyle == .liquid {
                    Picker("Glass mode", selection: $lockScreenGlassCustomizationMode) {
                        ForEach(LockScreenGlassCustomizationMode.allCases) { mode in
                            Text(mode.localizedName).tag(mode)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Glass mode"))

                    if lockScreenGlassCustomizationMode == .customLiquid {
                        Text("Use the sliders below to pick unique Apple liquid-glass variants for each widget.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Custom Liquid settings require the Liquid Glass material.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Lock Screen Glass")
            } footer: {
                Text("Choose the global material mode for lock screen widgets. Custom Liquid unlocks per-widget variant sliders while Standard sticks to the classic frosted/liquid options.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenMediaWidget) {
                    Text("Show lock screen media panel")
                }
                .settingsHighlight(id: highlightID("Show lock screen media panel"))
                Defaults.Toggle(key: .lockScreenShowAppIcon) {
                    Text("Show media app icon")
                }
                .disabled(!enableLockScreenMediaWidget)
                .settingsHighlight(id: highlightID("Show media app icon"))
                if isAppleMusicActive {
                    Defaults.Toggle(key: .lockScreenMusicMergedAirPlayOutput) {
                        Text("Show merged AirPlay and output devices")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Show merged AirPlay and output devices"))
                }
                Defaults.Toggle(key: .lockScreenPanelShowsBorder) {
                    Text("Show panel border")
                }
                .disabled(!enableLockScreenMediaWidget)
                .settingsHighlight(id: highlightID("Show panel border"))
                if lockScreenGlassCustomizationMode == .customLiquid {
                    Defaults.Toggle(key: .lockScreenMusicUsesEnhancedLiquidBorder) {
                        Text("Use enhanced liquid border")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Use enhanced liquid border"))
                }
                if lockScreenGlassCustomizationMode == .customLiquid {
                    variantSlider(
                        title: "Music panel variant",
                        value: musicVariantBinding,
                        currentValue: lockScreenMusicLiquidGlassVariant.rawValue,
                        isEnabled: enableLockScreenMediaWidget,
                        highlight: highlightID("Music panel variant")
                    )
                } else if lockScreenGlassStyle == .frosted {
                    Defaults.Toggle(key: .lockScreenPanelUsesBlur) {
                        Text("Enable media panel blur")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Enable media panel blur"))
                } else {
                    blurSettingUnavailableRow
                        .opacity(enableLockScreenMediaWidget ? 1 : 0.5)
                        .settingsHighlight(id: highlightID("Enable media panel blur"))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Defaults.Toggle(key: .lockScreenMusicFullscreenArtworkEnabled) {
                        Text("Fullscreen artwork on right-click")
                    }
                    .disabled(!enableLockScreenMediaWidget)
                    .settingsHighlight(id: highlightID("Fullscreen artwork on right-click"))
                    Defaults.Toggle(key: .lockScreenUseArtworkLayoutOverFullscreenCanvas) {
                        Text("Use album art layout over fullscreen canvas")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Use album art layout over fullscreen canvas"))
                    Defaults.Toggle(key: .lockScreenKeepAlbumArtVisibleDuringFullscreenArtwork) {
                        Text("Keep album art visible during fullscreen artwork")
                    }
                    .disabled(!enableLockScreenMediaWidget || !lockScreenMusicFullscreenArtworkEnabled)
                    .settingsHighlight(id: highlightID("Keep album art visible during fullscreen artwork"))
                    Text("Right-click the album art on the lock screen to set it as the wallpaper. Right-click again or click the background to restore the original wallpaper. If a canvas is available, Atoll can also keep the same album art + player layout on top of the live canvas.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if !showStandardMediaControls {
                    Text("Enable Dynamic Island media controls to manage the lock screen panel.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } header: {
                Text("Media Panel")
            } footer: {
                Text("Enable and style the media controls that appear above the system clock when the screen is locked.")
            }
            .disabled(!showStandardMediaControls)
            .opacity(showStandardMediaControls ? 1 : 0.5)

            Section {
                Defaults.Toggle(key: .enableLockScreenTimerWidget) {
                    Text("Show lock screen timer")
                }
                .settingsHighlight(id: highlightID("Show lock screen timer"))
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
                            variantSlider(
                                title: "Timer widget variant",
                                value: timerVariantBinding,
                                currentValue: lockScreenTimerLiquidGlassVariant.rawValue,
                                isEnabled: enableLockScreenTimerWidget,
                                highlight: highlightID("Timer widget variant")
                            )
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
                Text("Timer Widget")
            } footer: {
                Text("Controls the optional timer widget that floats above the media panel, including its classic, frosted, or liquid glass surface independent of the global material setting.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenWeatherWidget) {
                    Text("Show lock screen weather")
                }
                .settingsHighlight(id: highlightID("Show lock screen weather"))

                if enableLockScreenWeatherWidget {
                    Picker("Layout", selection: $lockScreenWeatherWidgetStyle) {
                        ForEach(LockScreenWeatherWidgetStyle.allCases) { style in
                            Text(style.localizedName).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Layout"))

                    Picker("Weather data provider", selection: $lockScreenWeatherProviderSource) {
                        ForEach(LockScreenWeatherProviderSource.allCases) { source in
                            Text(source.displayName).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Weather data provider"))

                    Picker("Temperature unit", selection: $lockScreenWeatherTemperatureUnit) {
                        ForEach(LockScreenWeatherTemperatureUnit.allCases) { unit in
                            Text(unit.localizedName).tag(unit)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Temperature unit"))

                    Defaults.Toggle(key: .lockScreenWeatherShowsLocation) {
                        Text("Show location label")
                    }
                    .disabled(lockScreenWeatherWidgetStyle == .circular)
                    .settingsHighlight(id: highlightID("Show location label"))

                    Defaults.Toggle(key: .lockScreenWeatherShowsSunrise) {
                        Text("Show sunrise time")
                    }
                    .disabled(lockScreenWeatherWidgetStyle != .inline)
                    .settingsHighlight(id: highlightID("Show sunrise time"))

                    Defaults.Toggle(key: .lockScreenWeatherShowsAQI) {
                        Text("Show AQI widget")
                    }
                    .disabled(!lockScreenWeatherProviderSource.supportsAirQuality)
                    .settingsHighlight(id: highlightID("Show AQI widget"))

                    if lockScreenWeatherShowsAQI && lockScreenWeatherProviderSource.supportsAirQuality {
                        Picker("Air quality scale", selection: $lockScreenWeatherAQIScale) {
                            ForEach(LockScreenWeatherAirQualityScale.allCases) { scale in
                                Text(scale.displayName).tag(scale)
                            }
                        }
                        .pickerStyle(.segmented)
                        .settingsHighlight(id: highlightID("Air quality scale"))
                    }

                    if !lockScreenWeatherProviderSource.supportsAirQuality {
                        Text("Air quality requires the Open Meteo provider.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Defaults.Toggle(key: .lockScreenWeatherUsesGaugeTint) {
                        Text("Use colored gauges")
                    }
                    .settingsHighlight(id: highlightID("Use colored gauges"))
                }
            } header: {
                Text("Weather Widget")
            } footer: {
                Text("Enable the weather capsule and configure its layout, provider, units, and optional battery/AQI indicators.")
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenReminderWidget) {
                    Text("Show lock screen reminder")
                }
                .settingsHighlight(id: highlightID("Show lock screen reminder"))

                Picker("Chip color", selection: $lockScreenReminderChipStyle) {
                    ForEach(LockScreenReminderChipStyle.allCases) { style in
                        Text(style.localizedName).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!enableLockScreenReminderWidget)
                .settingsHighlight(id: highlightID("Chip color"))

                Picker("Alignment", selection: $lockScreenReminderWidgetHorizontalAlignment) {
                    ForEach(ReminderAlignmentOption.allCases) { option in
                        Text(option.title).tag(option.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!enableLockScreenReminderWidget)
                .settingsHighlight(id: highlightID("Reminder alignment"))

                HStack {
                    Text("Vertical offset")
                    Slider(
                        value: $lockScreenReminderWidgetVerticalOffset,
                        in: -160...160,
                        step: 2
                    )
                    .disabled(!enableLockScreenReminderWidget)
                    Text("\(Int(lockScreenReminderWidgetVerticalOffset)) px")
                        .foregroundStyle(.secondary)
                        .frame(width: 70, alignment: .trailing)
                }
                .settingsHighlight(id: highlightID("Reminder vertical offset"))
            } header: {
                Text("Reminder Widget")
            } footer: {
                Text("Controls the lock screen reminder chip and its positioning.")
            }

            if BatteryActivityManager.shared.hasBattery() {
                Section {
                    Defaults.Toggle(key: .lockScreenBatteryShowsBatteryGauge) {
                        Text("Show battery indicator")
                    }
                    .settingsHighlight(id: highlightID("Show battery indicator"))

                    if lockScreenWeatherShowsBatteryGauge {
                        Defaults.Toggle(key: .lockScreenBatteryUsesLaptopSymbol) {
                            Text("Use MacBook icon when on battery")
                        }
                        .settingsHighlight(id: highlightID("Use MacBook icon when on battery"))

                        Defaults.Toggle(key: .lockScreenBatteryShowsCharging) {
                            Text("Show charging status")
                        }
                        .settingsHighlight(id: highlightID("Show charging status"))

                        if lockScreenWeatherShowsCharging {
                            Defaults.Toggle(key: .lockScreenBatteryShowsChargingPercentage) {
                                Text("Show charging percentage")
                            }
                            .settingsHighlight(id: highlightID("Show charging percentage"))
                        }

                        Defaults.Toggle(key: .lockScreenBatteryShowsBluetooth) {
                            Text("Show Bluetooth battery")
                        }
                        .settingsHighlight(id: highlightID("Show Bluetooth battery"))
                    }
                } header: {
                    Text("Battery Widget")
                } footer: {
                    Text("Enable the battery capsule and configure its layout.")
                }
            }

            Section {
                Defaults.Toggle(key: .enableLockScreenFocusWidget) {
                    Text("Show focus widget")
                }
                .settingsHighlight(id: highlightID("Show focus widget"))
            } header: {
                Text("Focus Widget")
            } footer: {
                Text("Displays the current Focus state above the weather capsule whenever Focus detection is enabled.")
            }

            Section {
                Defaults.Toggle(key: .lockScreenShowCalendarEvent) {
                    Text("Show next calendar event")
                }
                .settingsHighlight(id: highlightID("Show next calendar event"))

                LabeledContent("Show events within the next") {
                    HStack {
                        Spacer(minLength: 0)
                        Picker("", selection: $lockScreenCalendarEventLookaheadWindow) {
                            ForEach(CalendarLookaheadOption.allCases) { option in
                                Text(option.title).tag(option.rawValue)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show events within the next"))

                Toggle("Show events from all calendars", isOn: Binding(
                    get: { lockScreenCalendarSelectionMode == "all" },
                    set: { useAll in
                        if useAll {
                            lockScreenCalendarSelectionMode = "all"
                        } else {
                            lockScreenCalendarSelectionMode = "selected"
                            lockScreenSelectedCalendarIDs = Set(calendarManager.eventCalendars.map { $0.id })
                        }
                    }
                ))
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show events from all calendars"))

                if lockScreenCalendarSelectionMode != "all" {
                    HStack {
                        Spacer()
                        Button("Deselect All") {
                            lockScreenSelectedCalendarIDs = []
                        }
                        .buttonStyle(.link)
                    }
                    .padding(.top, 2)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(calendarManager.eventCalendars, id: \.id) { calendar in
                            Toggle(isOn: Binding(
                                get: { lockScreenSelectedCalendarIDs.contains(calendar.id) },
                                set: { isOn in
                                    if isOn {
                                        lockScreenSelectedCalendarIDs.insert(calendar.id)
                                    } else {
                                        lockScreenSelectedCalendarIDs.remove(calendar.id)
                                    }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(Color(calendar.color))
                                        .frame(width: 8, height: 8)
                                    Text(calendar.title)
                                }
                            }
                        }
                    }
                    .padding(.top, 4)
                    .padding(.leading, 2)
                    .disabled(!lockScreenShowCalendarEvent)
                }

                Defaults.Toggle(key: .lockScreenShowCalendarCountdown) {
                    Text("Show countdown")
                }
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show countdown"))

                Defaults.Toggle(key: .lockScreenShowCalendarEventEntireDuration) {
                    Text("Show event for entire duration")
                }
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show event for entire duration"))
                .onChange(of: Defaults[.lockScreenShowCalendarEventEntireDuration]) { _, newValue in
                    if newValue {
                        Defaults[.lockScreenShowCalendarEventAfterStartEnabled] = false
                    }
                }

                Defaults.Toggle(
                    "Hide active event and show next upcoming event",
                    key: .lockScreenShowCalendarEventAfterStartEnabled
                )
                .disabled(!lockScreenShowCalendarEvent || lockScreenShowCalendarEventEntireDuration)
                .settingsHighlight(id: highlightID("Hide active event and show next upcoming event"))

                LabeledContent("Show event after it starts") {
                    HStack {
                        Spacer(minLength: 0)
                        Picker("", selection: $lockScreenShowCalendarEventAfterStartWindow) {
                            Text("1 min").tag("1m")
                            Text("5 mins").tag("5m")
                            Text("10 mins").tag("10m")
                            Text("15 mins").tag("15m")
                            Text("30 mins").tag("30m")
                            Text("45 mins").tag("45m")
                            Text("1 hour").tag("1h")
                            Text("2 hours").tag("2h")
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .disabled(!lockScreenShowCalendarEvent || lockScreenShowCalendarEventEntireDuration || !lockScreenShowCalendarEventAfterStartEnabled)

                Text("Turn off 'Show event for entire duration' to use the post-start duration option.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Defaults.Toggle(key: .lockScreenShowCalendarTimeRemaining) {
                    Text("Show time remaining")
                }
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show time remaining"))

                Defaults.Toggle(key: .lockScreenShowCalendarStartTimeAfterBegins) {
                    Text("Show start time after event begins")
                }
                .disabled(!lockScreenShowCalendarEvent)
                .settingsHighlight(id: highlightID("Show start time after event begins"))
            } header: {
                Text("Calendar Widget")
            } footer: {
                Text("Displays your next upcoming calendar event above or below the weather capsule. Calendar selection here is independent from the Dynamic Island calendar filter.")
            }

            LockScreenPositioningControls()

            Section {
                Button("Copy Latest Crash Report") {
                    copyLatestCrashReport()
                }
            } header: {
                Text("Diagnostics")
            } footer: {
                Text("Collect the latest crash report to share with the developer when reporting lock screen or overlay issues.")
            }
        }
        .onAppear(perform: enforceLockScreenGlassConsistency)
        .onChange(of: lockScreenGlassStyle) { _, _ in enforceLockScreenGlassConsistency() }
        .onChange(of: lockScreenGlassCustomizationMode) { _, _ in enforceLockScreenGlassConsistency() }
        .navigationTitle("Lock Screen")
    }
}

extension LockScreenSettings {
    private func enforceLockScreenGlassConsistency() {
        if lockScreenGlassStyle == .frosted && lockScreenGlassCustomizationMode != .standard {
            lockScreenGlassCustomizationMode = .standard
        }
        if lockScreenGlassCustomizationMode == .customLiquid && lockScreenGlassStyle != .liquid {
            lockScreenGlassStyle = .liquid
        }
    }

    private var blurSettingUnavailableRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Enable media panel blur")
                .foregroundStyle(.secondary)
            Text("Only available when Material is set to Frosted Glass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func variantSlider(
        title: String,
        value: Binding<Double>,
        currentValue: Int,
        isEnabled: Bool,
        highlight: String,
        preview: AnyView? = nil
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text("v\(currentValue)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: liquidVariantRange, step: 1)

            if let preview {
                preview
                    .padding(.top, 6)
            }
        }
        .settingsHighlight(id: highlight)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct LockScreenPositioningControls: View {
    @Default(.lockScreenWeatherVerticalOffset) private var weatherOffset
    @Default(.lockScreenMusicVerticalOffset) private var musicOffset
    @Default(.lockScreenTimerVerticalOffset) private var timerOffset
    @Default(.lockScreenMusicPanelWidth) private var musicWidth
    @Default(.lockScreenTimerWidgetWidth) private var timerWidth
    private let offsetRange: ClosedRange<Double> = -160...160
    private let musicWidthRange: ClosedRange<Double> = 320...Double(LockScreenMusicPanel.defaultCollapsedWidth)
    private let timerWidthRange: ClosedRange<Double> = 320...LockScreenTimerWidget.defaultWidth

    var body: some View {
        Section {
            let weatherBinding = Binding<Double>(
                get: { weatherOffset },
                set: { newValue in
                    let clampedValue = clampOffset(newValue)
                    if weatherOffset != clampedValue {
                        weatherOffset = clampedValue
                    }
                    propagateWeatherOffsetChange(animated: false)
                }
            )

            let timerBinding = Binding<Double>(
                get: { timerOffset },
                set: { newValue in
                    let clampedValue = clampOffset(newValue)
                    if timerOffset != clampedValue {
                        timerOffset = clampedValue
                    }
                    propagateTimerOffsetChange(animated: false)
                }
            )

            let musicBinding = Binding<Double>(
                get: { musicOffset },
                set: { newValue in
                    let clampedValue = clampOffset(newValue)
                    if musicOffset != clampedValue {
                        musicOffset = clampedValue
                    }
                    propagateMusicOffsetChange(animated: false)
                }
            )

            let musicWidthBinding = Binding<Double>(
                get: { musicWidth },
                set: { newValue in
                    let clampedValue = clamp(newValue, within: musicWidthRange)
                    if musicWidth != clampedValue {
                        musicWidth = clampedValue
                        propagateMusicWidthChange(animated: false)
                    }
                }
            )

            let timerWidthBinding = Binding<Double>(
                get: { timerWidth },
                set: { newValue in
                    let clampedValue = clamp(newValue, within: timerWidthRange)
                    if timerWidth != clampedValue {
                        timerWidth = clampedValue
                        propagateTimerWidthChange(animated: false)
                    }
                }
            )

            LockScreenPositioningPreview(
                weatherOffset: weatherBinding,
                timerOffset: timerBinding,
                musicOffset: musicBinding,
                musicWidth: musicWidthBinding,
                timerWidth: timerWidthBinding
            )
            .frame(height: 260)
            .padding(.vertical, 8)

            HStack(alignment: .top, spacing: 24) {
                offsetColumn(
                    title: String(localized: "Weather"),
                    value: weatherOffset,
                    resetTitle: String(localized: "Reset Weather"),
                    resetAction: resetWeatherOffset
                )

                Divider()
                    .frame(height: 64)

                offsetColumn(
                    title: String(localized: "Timer"),
                    value: timerOffset,
                    resetTitle: String(localized: "Reset Timer"),
                    resetAction: resetTimerOffset
                )

                Divider()
                    .frame(height: 64)

                offsetColumn(
                    title: String(localized: "Music"),
                    value: musicOffset,
                    resetTitle: String(localized: "Reset Music"),
                    resetAction: resetMusicOffset
                )

                Spacer()
            }

            Divider()
                .padding(.vertical, 8)

            VStack(alignment: .leading, spacing: 16) {
                widthSlider(
                    title: String(localized: "Media Panel Width"),
                    value: musicWidthBinding,
                    range: musicWidthRange,
                    resetTitle: String(localized: "Reset Media Width"),
                    resetAction: resetMusicWidth,
                    helpText: String(localized: "Shrinks the lock screen media panel while keeping the expanded view full width.")
                )

                widthSlider(
                    title: String(localized: "Timer Widget Width"),
                    value: timerWidthBinding,
                    range: timerWidthRange,
                    resetTitle: String(localized: "Reset Timer Width"),
                    resetAction: resetTimerWidth,
                    helpText: String(localized: "Adjusts the lock screen timer widget width without affecting button sizing.")
                )
            }
        } header: {
            Text("Lock Screen Positioning")
        } footer: {
            Text("Drag the previews to adjust vertical placement. Positive values lift the panel; negative values lower it. Use the width sliders below to narrow the media and timer widgets without exceeding their default size. Changes apply instantly while the widgets are visible.")
                .textCase(nil)
        }
    }

    private func clampOffset(_ value: Double) -> Double {
        min(max(value, offsetRange.lowerBound), offsetRange.upperBound)
    }

    private func clamp(_ value: Double, within range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func resetWeatherOffset() {
        weatherOffset = 0
        propagateWeatherOffsetChange(animated: true)
    }

    private func resetTimerOffset() {
        timerOffset = 0
        propagateTimerOffsetChange(animated: true)
    }

    private func resetMusicOffset() {
        musicOffset = 0
        propagateMusicOffsetChange(animated: true)
    }

    private func resetMusicWidth() {
        musicWidth = Double(LockScreenMusicPanel.defaultCollapsedWidth)
        propagateMusicWidthChange(animated: true)
    }

    private func resetTimerWidth() {
        timerWidth = LockScreenTimerWidget.defaultWidth
        propagateTimerWidthChange(animated: true)
    }

    private func propagateWeatherOffsetChange(animated: Bool) {
        Task { @MainActor in
            LockScreenWeatherPanelManager.shared.refreshPositionForOffsets(animated: animated)
        }
    }

    private func propagateTimerOffsetChange(animated: Bool) {
        Task { @MainActor in
            LockScreenTimerWidgetManager.shared.refreshPositionForOffsets(animated: animated)
        }
    }

    private func propagateMusicOffsetChange(animated: Bool) {
        Task { @MainActor in
            LockScreenPanelManager.shared.applyOffsetAdjustment(animated: animated)
        }
    }

    private func propagateMusicWidthChange(animated: Bool) {
        Task { @MainActor in
            LockScreenPanelManager.shared.applyOffsetAdjustment(animated: animated)
        }
    }

    private func propagateTimerWidthChange(animated: Bool) {
        Task { @MainActor in
            LockScreenTimerWidgetPanelManager.shared.refreshPosition(animated: animated)
        }
    }

    @ViewBuilder
    private func offsetColumn(title: String, value: Double, resetTitle: String, resetAction: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("\(title) Offset")
                .font(.subheadline.weight(.semibold))

            Text("\(formattedPoints(value)) pt")
                .font(.caption)
                .foregroundStyle(.secondary)

            Button(resetTitle) {
                resetAction()
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private func widthSlider(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        resetTitle: String,
        resetAction: @escaping () -> Void,
        helpText: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(formattedWidth(value.wrappedValue))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Slider(value: value, in: range)

            HStack(alignment: .top) {
                Button(resetTitle) {
                    resetAction()
                }
                .buttonStyle(.bordered)

                Spacer()

                Text(helpText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.trailing)
            }
        }
    }

    private func formattedPoints(_ value: Double) -> String {
        String(format: "%+.0f", value)
    }

    private func formattedWidth(_ value: Double) -> String {
        String(format: "%.0f pt", value)
    }
}

private struct LockScreenPositioningPreview: View {
    @Binding var weatherOffset: Double
    @Binding var timerOffset: Double
    @Binding var musicOffset: Double
    @Binding var musicWidth: Double
    @Binding var timerWidth: Double

    @State private var weatherStartOffset: Double = 0
    @State private var timerStartOffset: Double = 0
    @State private var musicStartOffset: Double = 0
    @State private var isWeatherDragging = false
    @State private var isTimerDragging = false
    @State private var isMusicDragging = false

    private let offsetRange: ClosedRange<Double> = -160...160

    var body: some View {
        GeometryReader { geometry in
            let screenPadding: CGFloat = 26
            let screenCornerRadius: CGFloat = 28
            let screenRect = CGRect(
                x: screenPadding,
                y: screenPadding,
                width: geometry.size.width - (screenPadding * 2),
                height: geometry.size.height - (screenPadding * 2)
            )
            let centerX = screenRect.midX
            let weatherBaseY = screenRect.minY + (screenRect.height * 0.28)
            let timerBaseY = screenRect.minY + (screenRect.height * 0.5)
            let musicBaseY = screenRect.minY + (screenRect.height * 0.78)
            let weatherSize = CGSize(width: screenRect.width * 0.42, height: screenRect.height * 0.22)
            let defaultMusicWidth = Double(LockScreenMusicPanel.defaultCollapsedWidth)
            let musicWidthScale = CGFloat(musicWidth / defaultMusicWidth)
            let timerWidthScale = CGFloat(timerWidth / LockScreenTimerWidget.defaultWidth)
            let timerSize = CGSize(
                width: (screenRect.width * 0.5) * timerWidthScale,
                height: screenRect.height * 0.2
            )
            let musicSize = CGSize(
                width: (screenRect.width * 0.56) * musicWidthScale,
                height: screenRect.height * 0.34
            )

            ZStack {
                RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
                    .frame(width: screenRect.width, height: screenRect.height)
                    .overlay(
                        RoundedRectangle(cornerRadius: screenCornerRadius, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .shadow(color: Color.black.opacity(0.22), radius: 20, x: 0, y: 18)
                    .position(x: screenRect.midX, y: screenRect.midY)

                weatherPanel(size: weatherSize)
                    .position(x: centerX, y: weatherBaseY - CGFloat(weatherOffset))
                    .gesture(weatherDragGesture(in: screenRect, baseY: weatherBaseY, panelSize: weatherSize))

                timerPanel(size: timerSize)
                    .position(x: centerX, y: timerBaseY - CGFloat(timerOffset))
                    .gesture(timerDragGesture(in: screenRect, baseY: timerBaseY, panelSize: timerSize))

                musicPanel(size: musicSize)
                    .position(x: centerX, y: musicBaseY - CGFloat(musicOffset))
                    .gesture(musicDragGesture(in: screenRect, baseY: musicBaseY, panelSize: musicSize))
            }
        }
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: weatherOffset)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: musicOffset)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: timerOffset)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: musicWidth)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.82), value: timerWidth)
    }

    private func weatherPanel(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.blue.opacity(0.78), Color.blue.opacity(0.52)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Weather", systemImage: "cloud.sun.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text("Inline snapshot preview")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(.horizontal, 16)
            }
            .shadow(color: Color.blue.opacity(0.22), radius: 10, x: 0, y: 8)
    }

    private func musicPanel(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 20, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.purple.opacity(0.68), Color.pink.opacity(0.5)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size.width, height: size.height)
            .overlay(alignment: .leading) {
                VStack(alignment: .leading, spacing: 6) {
                    Label("Media", systemImage: "play.square.stack")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.white)
                    Text("Lock screen panel preview")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.white.opacity(0.72))
                }
                .padding(.horizontal, 18)
            }
            .shadow(color: Color.purple.opacity(0.24), radius: 12, x: 0, y: 9)
    }

    private func timerPanel(size: CGSize) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color.orange.opacity(0.75), Color.purple.opacity(0.55)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size.width, height: size.height)
            .overlay {
                VStack(spacing: 6) {
                    Text("Timer")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                    Text("00:05:00")
                        .font(.system(size: 18, weight: .bold, design: .monospaced))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: Color.orange.opacity(0.3), radius: 12, x: 0, y: 8)
    }

    private func weatherDragGesture(in screenRect: CGRect, baseY: CGFloat, panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isWeatherDragging {
                    isWeatherDragging = true
                    weatherStartOffset = weatherOffset
                }

                let proposed = weatherStartOffset - Double(value.translation.height)
                weatherOffset = clampedOffset(
                    proposed,
                    baseCenterY: baseY,
                    panelHeight: panelSize.height,
                    screenRect: screenRect
                )
            }
            .onEnded { _ in
                isWeatherDragging = false
            }
    }

    private func musicDragGesture(in screenRect: CGRect, baseY: CGFloat, panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isMusicDragging {
                    isMusicDragging = true
                    musicStartOffset = musicOffset
                }

                let proposed = musicStartOffset - Double(value.translation.height)
                musicOffset = clampedOffset(
                    proposed,
                    baseCenterY: baseY,
                    panelHeight: panelSize.height,
                    screenRect: screenRect
                )
            }
            .onEnded { _ in
                isMusicDragging = false
            }
    }

    private func timerDragGesture(in screenRect: CGRect, baseY: CGFloat, panelSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                if !isTimerDragging {
                    isTimerDragging = true
                    timerStartOffset = timerOffset
                }

                let proposed = timerStartOffset - Double(value.translation.height)
                timerOffset = clampedOffset(
                    proposed,
                    baseCenterY: baseY,
                    panelHeight: panelSize.height,
                    screenRect: screenRect
                )
            }
            .onEnded { _ in
                isTimerDragging = false
            }
    }

    private func clampedOffset(
        _ proposed: Double,
        baseCenterY: CGFloat,
        panelHeight: CGFloat,
        screenRect: CGRect
    ) -> Double {
        let halfHeight = panelHeight / 2
        let minCenterY = screenRect.minY + halfHeight
        let maxCenterY = screenRect.maxY - halfHeight
        let proposedCenter = baseCenterY - CGFloat(proposed)
        let clampedCenter = min(max(proposedCenter, minCenterY), maxCenterY)
        let derivedOffset = Double(baseCenterY - clampedCenter)
        return min(max(derivedOffset, offsetRange.lowerBound), offsetRange.upperBound)
    }
}

private func copyLatestCrashReport() {
    let crashReportsPath = NSString(string: "~/Library/Logs/DiagnosticReports").expandingTildeInPath
    let fileManager = FileManager.default

    do {
        let files = try fileManager.contentsOfDirectory(atPath: crashReportsPath)
        let crashFiles = files.filter { $0.contains("DynamicIsland") && $0.hasSuffix(".crash") }

        guard let latestCrash = crashFiles.sorted(by: >).first else {
            let alert = NSAlert()
            alert.messageText = "No Crash Reports Found"
            alert.informativeText = "No crash reports found for DynamicIsland"
            alert.alertStyle = .informational
            alert.runModal()
            return
        }

        let crashPath = (crashReportsPath as NSString).appendingPathComponent(latestCrash)
        let crashContent = try String(contentsOfFile: crashPath, encoding: .utf8)

        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(crashContent, forType: .string)

        let alert = NSAlert()
        alert.messageText = "Crash Report Copied"
        alert.informativeText = "Crash report '\(latestCrash)' has been copied to clipboard"
        alert.alertStyle = .informational
        alert.runModal()
    } catch {
        let alert = NSAlert()
        alert.messageText = "Error"
        alert.informativeText = "Failed to read crash reports: \(error.localizedDescription)"
        alert.alertStyle = .warning
        alert.runModal()
    }
}
