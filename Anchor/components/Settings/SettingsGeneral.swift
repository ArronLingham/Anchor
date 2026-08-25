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

struct GeneralSettings: View {
    @State private var screens: [String] = NSScreen.screens.compactMap { $0.localizedName }
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject var coordinator = AnchorViewCoordinator.shared
    @Default(.showEmojis) var showEmojis
    @Default(.gestureSensitivity) var gestureSensitivity
    @Default(.minimumHoverDuration) var minimumHoverDuration
    @Default(.nonNotchHeight) var nonNotchHeight
    @Default(.nonNotchHeightMode) var nonNotchHeightMode
    @Default(.notchHeight) var notchHeight
    @Default(.closedNotchWidth) var closedNotchWidth
    @Default(.customizePhysicalNotchWidth) var customizePhysicalNotchWidth
    @Default(.notchHeightMode) var notchHeightMode
    @Default(.showOnAllDisplays) var showOnAllDisplays
    @Default(.automaticallySwitchDisplay) var automaticallySwitchDisplay
    @Default(.enableGestures) var enableGestures
    @Default(.openNotchOnHover) var openNotchOnHover
    @Default(.enableMinimalisticUI) var enableMinimalisticUI
    @Default(.showMinimalisticBatteryIndicator) var showMinimalisticBatteryIndicator
    @Default(.enableHorizontalMusicGestures) var enableHorizontalMusicGestures
    @Default(.musicGestureBehavior) var musicGestureBehavior
    @Default(.reverseSwipeGestures) var reverseSwipeGestures
    @Default(.reverseScrollGestures) var reverseScrollGestures
    @Default(.externalDisplayStyle) var externalDisplayStyle
    @Default(.hideNonNotchUntilHover) var hideNonNotchUntilHover

    private func highlightID(_ title: String) -> String {
        SettingsTab.general.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableMinimalisticUI) {
                    Text("Enable Minimalistic UI")
                }
                .onChange(of: enableMinimalisticUI) { _, newValue in
                    if newValue {
                        // Auto-enable simpler animation mode
                        Defaults[.useModernCloseAnimation] = true
                    }
                }
                .settingsHighlight(id: highlightID("Enable Minimalistic UI"))

                Defaults.Toggle(key: .showMinimalisticBatteryIndicator) {
                    Text("Show battery indicator")
                }
                .disabled(!enableMinimalisticUI)
                .settingsHighlight(id: highlightID("Show battery indicator in Minimalistic UI"))

                Defaults.Toggle(key: .showBatteryPercentInside) {
                    Text("Show battery percentage inside icon")
                }
                .disabled(!enableMinimalisticUI || !Defaults[.showMinimalisticBatteryIndicator])
                .settingsHighlight(id: highlightID("Show battery percentage inside icon"))
            } header: {
                Text("UI Mode")
            } footer: {
                Text("Minimalistic mode focuses on media controls and system HUDs, hiding all extra features for a clean, focused experience. Automatically enables simpler animations.")
            }

            Section {
                Defaults.Toggle(key: .menubarIcon) {
                    Text("Menubar icon")
                }
                .settingsHighlight(id: highlightID("Menubar icon"))
                LaunchAtLogin.Toggle {
                    Text("Launch at login")
                }
                .settingsHighlight(id: highlightID("Launch at login"))
                Defaults.Toggle(key: .showOnAllDisplays) {
                    Text("Show on all displays")
                }
                .onChange(of: showOnAllDisplays) {
                    NotificationCenter.default.post(name: Notification.Name.showOnAllDisplaysChanged, object: nil)
                }
                .settingsHighlight(id: highlightID("Show on all displays"))
                Picker("Show on a specific display", selection: $coordinator.preferredScreen) {
                    ForEach(screens, id: \.self) { screen in
                        Text(screen)
                    }
                }
                .onChange(of: NSScreen.screens) {
                    screens =  NSScreen.screens.compactMap({$0.localizedName})
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: highlightID("Show on a specific display"))
                Defaults.Toggle(key: .automaticallySwitchDisplay) {
                    Text("Automatically switch displays")
                }
                .onChange(of: automaticallySwitchDisplay) {
                    NotificationCenter.default.post(name: Notification.Name.automaticallySwitchDisplayChanged, object: nil)
                }
                .disabled(showOnAllDisplays)
                .settingsHighlight(id: highlightID("Automatically switch displays"))
                Defaults.Toggle(key: .hideDynamicIslandFromScreenCapture) {
                    Text("Hide Dynamic Island during screenshots & recordings")
                }
                .settingsHighlight(id: highlightID("Hide Dynamic Island during screenshots & recordings"))
            } header: {
                Text("System features")
            }

            Section {
                Picker(selection: $notchHeightMode, label:
                        Text("Notch display height")) {
                    Text("Match real notch size")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                        .onChange(of: notchHeightMode) {
                            switch notchHeightMode {
                            case .matchRealNotchSize:
                                notchHeight = 38
                            case .matchMenuBar:
                                notchHeight = 44
                            case .custom:
                                notchHeight = 38
                            }
                            NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                        }
                        .settingsHighlight(id: highlightID("Notch display height"))
                if notchHeightMode == .custom {
                    Slider(value: $notchHeight, in: 15...45, step: 1) {
                        Text("Custom notch size - \(notchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: notchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
                Picker("Non-notch display height", selection: $nonNotchHeightMode) {
                    Text("Match menubar height")
                        .tag(WindowHeightMode.matchMenuBar)
                    Text("Match real notch size")
                        .tag(WindowHeightMode.matchRealNotchSize)
                    Text("Custom height")
                        .tag(WindowHeightMode.custom)
                }
                .onChange(of: nonNotchHeightMode) {
                    switch nonNotchHeightMode {
                    case .matchMenuBar:
                        nonNotchHeight = 24
                    case .matchRealNotchSize:
                        nonNotchHeight = 32
                    case .custom:
                        nonNotchHeight = 32
                    }
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
                if nonNotchHeightMode == .custom {
                    Slider(value: $nonNotchHeight, in: 0...40, step: 1) {
                        Text("Custom notch size - \(nonNotchHeight, specifier: "%.0f")")
                    }
                    .onChange(of: nonNotchHeight) {
                        NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                    }
                }
            } header: {
                Text("Notch Height")
            }

            NotchBehaviour()

            gestureControls()
        }
        .toolbar {
            Button("Quit app") {
                NSApp.terminate(self)
            }
            .controlSize(.extraLarge)
        }
        .navigationTitle("General")
        .onChange(of: openNotchOnHover) {
            if !openNotchOnHover {
                enableGestures = true
            }
        }
    }

    @ViewBuilder
    func gestureControls() -> some View {
        Section {
            Defaults.Toggle(key: .enableGestures) {
                Text("Enable gestures")
            }
            .disabled(!openNotchOnHover)
            .settingsHighlight(id: highlightID("Enable gestures"))
            if enableGestures {
                Defaults.Toggle(key: .enableHorizontalMusicGestures) {
                    Text("Media change with horizontal gestures")
                }
                .settingsHighlight(id: highlightID("Horizontal media gestures"))

                if enableHorizontalMusicGestures {
                    Picker("Gesture skip behavior", selection: $musicGestureBehavior) {
                        ForEach(MusicSkipBehavior.allCases) { behavior in
                            Text(behavior.displayName)
                                .tag(behavior)
                        }
                    }
                    .pickerStyle(.segmented)
                    .settingsHighlight(id: highlightID("Gesture skip behavior"))

                    Text(musicGestureBehavior.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Defaults.Toggle(key: .reverseSwipeGestures) {
                        Text("Reverse swipe gestures")
                    }
                    .settingsHighlight(id: highlightID("Reverse swipe gestures"))
                }

                Defaults.Toggle(key: .closeGestureEnabled) {
                    Text("Close gesture")
                }
                .settingsHighlight(id: highlightID("Close gesture"))
                Slider(value: $gestureSensitivity, in: 100...300, step: 100) {
                    HStack {
                        Text("Gesture sensitivity")
                        Spacer()
                        Text(Defaults[.gestureSensitivity] == 100 ? "High" : Defaults[.gestureSensitivity] == 200 ? "Medium" : "Low")
                            .foregroundStyle(.secondary)
                    }
                }

                Defaults.Toggle(key: .reverseScrollGestures) {
                    Text("Reverse open/close scroll gestures")
                }
                .settingsHighlight(id: highlightID("Reverse scroll gestures"))
            }
        } header: {
            HStack {
                Text("Gesture control")
                customBadge(text: "Beta")
            }
        } footer: {
            Text("Two-finger swipe up on notch to close, two-finger swipe down on notch to open when **Open notch on hover** option is disabled")
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.secondary)
                .font(.caption)
        }
    }

    @ViewBuilder
    func NotchBehaviour() -> some View {
        Section {
            Defaults.Toggle(key: .extendHoverArea) {
                Text("Extend hover area")
            }
            .settingsHighlight(id: highlightID("Extend hover area"))
            Defaults.Toggle(key: .enableHaptics) {
                Text("Enable haptics")
            }
            .settingsHighlight(id: highlightID("Enable haptics"))
            Defaults.Toggle(key: .openNotchOnHover) {
                Text("Open notch on hover")
            }
            .settingsHighlight(id: highlightID("Open notch on hover"))
            Toggle("Remember last tab", isOn: $coordinator.openLastTabByDefault)
            if openNotchOnHover {
                Slider(value: $minimumHoverDuration, in: 0...1, step: 0.1) {
                    HStack {
                        Text("Minimum hover duration")
                        Spacer()
                        Text("\(minimumHoverDuration, specifier: "%.1f")s")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: minimumHoverDuration) {
                    NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
                }
            }
            Picker("External display style", selection: $externalDisplayStyle) {
                ForEach(ExternalDisplayStyle.allCases) { style in
                    Text(style.localizedName)
                        .tag(style)
                }
            }
            .onChange(of: externalDisplayStyle) {
                NotificationCenter.default.post(name: Notification.Name.notchHeightChanged, object: nil)
            }
            .settingsHighlight(id: highlightID("External display style"))
            Text(externalDisplayStyle.description)
                .font(.caption)
                .foregroundStyle(.secondary)
            Defaults.Toggle(key: .hideNonNotchUntilHover) {
                Text("Hide until hovered on non-notch displays")
            }
            .settingsHighlight(id: highlightID("Hide until hovered"))
            Text("When enabled, the notch slides up and hides on external (non-notch) displays until you hover over it.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Notch behavior")
        }
    }
}
