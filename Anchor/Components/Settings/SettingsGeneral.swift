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

struct GeneralSettings: View {
    @Default(.enableBatteryAlert) private var enableBatteryAlert
    @Default(.enableCPUAlert) private var enableCPUAlert
    @Default(.enableDiskAlert) private var enableDiskAlert
    @Default(.enableFocusFollowsMouse) private var enableFocusFollowsMouse
    @Default(.enableKeyDebounce) private var enableKeyDebounce
    @Default(.enableQuitOnLastWindowClose) private var enableQuitOnLastWindowClose
    @Default(.batteryAlertPercent) private var batteryAlertPercent
    @Default(.cpuAlertPercent) private var cpuAlertPercent
    @Default(.diskAlertPercent) private var diskAlertPercent
    @Default(.focusFollowsMouseDelayMs) private var focusFollowsMouseDelayMs
    @Default(.keyDebounceMilliseconds) private var keyDebounceMilliseconds
    @Default(.enableShelf) var enableShelf
    @Default(.eyeBreakEnabled) var eyeBreakEnabled
    @Default(.eyeBreakWorkMinutes) var eyeBreakWorkMinutes
    @Default(.eyeBreakRestSeconds) var eyeBreakRestSeconds
    @State private var screens: [String] = NSScreen.screens.compactMap { $0.localizedName }
    @EnvironmentObject var vm: AnchorViewModel
    @ObservedObject var coordinator = AnchorViewCoordinator.shared
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

    // Sourced from @Default rather than `Binding(get: { Defaults[...] })`.
    // An imperative read inside a binding closure records no SwiftUI
    // dependency, so writing the value never invalidated the view and the
    // control went on rendering its old selection — the "settings dropdowns
    // don't update" bug. @Default subscribes to the key and republishes.
    @Default(.biometricGraceSeconds) private var biometricGrace
    private var biometricGraceBinding: Binding<Int> { $biometricGrace }

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
                if BiometricAuthManager.shared.isAvailable {
                    Defaults.Toggle(key: .requireBiometricForClipboard) {
                        Text("Lock clipboard history")
                    }
                    .settingsHighlight(id: highlightID("Lock clipboard history"))

                    Defaults.Toggle(key: .requireBiometricForNotes) {
                        Text("Lock notes")
                    }
                    .settingsHighlight(id: highlightID("Lock notes"))

                    Picker("Stay unlocked for", selection: biometricGraceBinding) {
                        Text("1 minute").tag(60)
                        Text("5 minutes").tag(300)
                        Text("15 minutes").tag(900)
                        Text("Always ask").tag(0)
                    }
                    .settingsHighlight(id: highlightID("Stay unlocked for"))
                } else {
                    Text("This Mac has no enrolled biometrics.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(BiometricAuthManager.shared.biometryName)
            } footer: {
                Text("Asks before revealing clipboard history or notes, and again after the screen sleeps. Falls back to your login password if the sensor is unavailable. This is a convenience lock over the notch UI — it does not encrypt anything on disk.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .showSpaceIndicator) {
                    Text("Show desktop number")
                }
                .settingsHighlight(id: highlightID("Show desktop number"))
                .settingsInfo("Shows which desktop you are on, updated when macOS reports a Space change. Fullscreen apps are not counted as desktops.")
            } header: {
                Text("Desktop")
            }

            Section {
                Defaults.Toggle(key: .enableSnapZones) {
                    Text("Snap windows to screen edges")
                }
                .settingsHighlight(id: highlightID("Snap windows to screen edges"))
                .settingsInfo("Drag a window against the left or right edge to tile it to that half, or the top edge to fill the screen. Sixteen zones are also available as shortcuts in the Shortcuts pane. Needs Accessibility, which dictation already requires. Nothing is observed until a drag begins.")

                Defaults.Toggle(key: .enableQuitOnLastWindowClose) {
                    Text("Quit apps when their last window closes")
                }
                .settingsHighlight(id: highlightID("Quit apps when their last window closes"))
                .settingsInfo("Windows-style behaviour: closing the last window quits the app instead of leaving it running with no windows. Minimised windows do not count as closed, apps are left alone for ten seconds after launching, and menu bar agents are never touched. Finder, Dock and Anchor are always excluded.")

                if enableQuitOnLastWindowClose {
                    QuitOnCloseExclusions()
                        .settingsHighlight(id: highlightID("Never quit these apps"))
                }
            } header: {
                Text("Windows")
            }

            Section {
                Defaults.Toggle(key: .invertScrollVertical) {
                    Text("Invert mouse wheel scrolling")
                }
                .settingsHighlight(id: highlightID("Invert mouse wheel scrolling"))
                .settingsInfo("Flips the direction of a mouse wheel only. Trackpads are left alone \u{2014} macOS's own natural scrolling already governs those, and inverting both would cancel out.")

                Defaults.Toggle(key: .invertScrollHorizontal) {
                    Text("Invert horizontal scrolling")
                }
                .settingsHighlight(id: highlightID("Invert horizontal scrolling"))

                Defaults.Toggle(key: .mouseSideButtonNavigation) {
                    Text("Mouse side buttons go back and forward")
                }
                .settingsHighlight(id: highlightID("Mouse side buttons go back and forward"))
                .settingsInfo("Maps mouse buttons 3 and 4 to \u{2318}[ and \u{2318}], which is Back and Forward in Finder, browsers and most document apps. Needs Accessibility and Input Monitoring.")

                Defaults.Toggle(key: .enableFocusFollowsMouse) {
                    Text("Focus follows the mouse")
                }
                .settingsHighlight(id: highlightID("Focus follows the mouse"))
                .settingsInfo("Brings the window under the pointer forward once the pointer settles there. Suspended while dragging, while a modifier is held and while a menu is open, so it cannot steal focus mid-action.")

                if enableFocusFollowsMouse {
                    Picker("Settle for", selection: $focusFollowsMouseDelayMs) {
                        Text("Fast (150 ms)").tag(150)
                        Text("Normal (300 ms)").tag(300)
                        Text("Relaxed (600 ms)").tag(600)
                        Text("Slow (1 second)").tag(1000)
                    }
                    .settingsHighlight(id: highlightID("Settle for"))
                }
            } header: {
                Text("Pointer")
            }

            Section {
                Defaults.Toggle(key: .enableKeyDebounce) {
                    Text("Filter repeated keystrokes")
                }
                .settingsHighlight(id: highlightID("Filter repeated keystrokes"))
                .settingsInfo("For a worn keyboard that types a letter twice. A second press of the same key sooner than the threshold is dropped; different keys in quick succession are never touched, so ordinary fast typing is unaffected. Needs Accessibility and Input Monitoring.")

                if enableKeyDebounce {
                    Picker("Ignore repeats within", selection: $keyDebounceMilliseconds) {
                        Text("15 ms").tag(15)
                        Text("25 ms (default)").tag(25)
                        Text("40 ms").tag(40)
                        Text("60 ms").tag(60)
                    }
                    .settingsHighlight(id: highlightID("Ignore repeats within"))

                    Text("Filtered so far: \(KeyDebounceManager.shared.suppressedCount)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Raise the threshold only if doubles still get through. Above about 60 ms this starts eating deliberate double-taps, which is a worse problem than the one it solves.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .blockMediaAppAutoLaunch) {
                    Text("Stop Music opening itself")
                }
                .settingsHighlight(id: highlightID("Stop Music opening itself"))
                .settingsInfo("Closes Music, TV or Podcasts when they launch on their own \u{2014} which macOS does when a Bluetooth headset sends a play command on connect. An app you open yourself is left alone.")
            } header: {
                Text("Media apps")
            }

            Section {
                Defaults.Toggle(key: .enableBatteryAlert) {
                    Text("Warn when the battery is low")
                }
                .settingsHighlight(id: highlightID("Warn when the battery is low"))
                if enableBatteryAlert {
                    Picker("Warn below", selection: $batteryAlertPercent) {
                        ForEach([10, 15, 20, 25, 30], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }

                Defaults.Toggle(key: .enableDiskAlert) {
                    Text("Warn when the disk is nearly full")
                }
                .settingsHighlight(id: highlightID("Warn when the disk is nearly full"))
                if enableDiskAlert {
                    Picker("Warn above", selection: $diskAlertPercent) {
                        ForEach([80, 85, 90, 95], id: \.self) { Text("\($0)% used").tag($0) }
                    }
                }

                Defaults.Toggle(key: .enableCPUAlert) {
                    Text("Warn when the CPU stays busy")
                }
                .settingsHighlight(id: highlightID("Warn when the CPU stays busy"))
                if enableCPUAlert {
                    Picker("Warn above", selection: $cpuAlertPercent) {
                        ForEach([70, 80, 85, 90], id: \.self) { Text("\($0)%").tag($0) }
                    }
                }
            } header: {
                Text("Alerts")
            } footer: {
                Text("Each alert fires once and then stays quiet until the value recovers well past its threshold \u{2014} a battery hovering at the warning level does not produce a stream of notifications. The CPU warning needs five sustained minutes, so a build or a page load never triggers it. Battery is event-driven; disk and CPU share one check a minute that stops while the display sleeps.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .enableDiskImageInstaller) {
                    Text("Offer to install apps from disk images")
                }
                .settingsHighlight(id: highlightID("Offer to install apps from disk images"))
            } header: {
                Text("Disk images")
            } footer: {
                Text("When you mount a .dmg holding a single app, Anchor asks whether to copy it to Applications and eject the image. It always asks \u{2014} nothing is ever copied on its own. An image with several apps is left alone rather than guessed at, and replacing an existing copy moves the old one to the Trash so you can put it back.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }


            SettingsSnippets()

            Section {
                Defaults.Toggle(key: .enableSystemStats) {
                    Text("System stats")
                }
                .settingsHighlight(id: highlightID("System stats"))
                .settingsInfo("Adds a Stats tab showing CPU, memory and network throughput. Sampling only runs while that tab is open — nothing is measured in the background.")
            } header: {
                Text("Stats")
            }

            Section {
                Defaults.Toggle(key: .enableShelf) {
                    Text("File shelf")
                }
                .settingsHighlight(id: highlightID("File shelf"))
                .settingsInfo("Adds a Shelf tab to the notch. Drop files onto it to park them, drag them back out to move them on. Files are referenced, not copied, so a large file costs a bookmark rather than a second copy.")
            } header: {
                Text("Shelf")
            }

            Section {
                Defaults.Toggle(key: .eyeBreakEnabled) {
                    Text("Eye break reminders")
                }
                .settingsHighlight(id: highlightID("Eye break reminders"))
                .settingsInfo("The 20-20-20 rule: every twenty minutes, look twenty feet away for twenty seconds. Reminders pause while the display sleeps or the Mac is locked, and the interval restarts when you come back — time away from the screen is not screen time.")

                Stepper(value: $eyeBreakWorkMinutes, in: 5...60, step: 5) {
                    HStack {
                        Text("Break every")
                        Spacer()
                        Text("\(eyeBreakWorkMinutes) min").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .disabled(!eyeBreakEnabled)

                Stepper(value: $eyeBreakRestSeconds, in: 10...60, step: 5) {
                    HStack {
                        Text("Look away for")
                        Spacer()
                        Text("\(eyeBreakRestSeconds)s").foregroundStyle(.secondary).monospacedDigit()
                    }
                }
                .disabled(!eyeBreakEnabled)
            } header: {
                Text("Eye break")
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
            Defaults.Toggle(key: .notchPinnedOpen) {
                Text("Keep the notch open")
            }
            .settingsHighlight(id: highlightID("Keep the notch open"))
            .settingsInfo("Stops the notch closing when you click elsewhere, type, or move the pointer away. There is a pin button in the notch itself, and ⌘⇧K toggles it from anywhere.")

            Defaults.Toggle(key: .alwaysShowOnExternalDisplays) {
                Text("Always show on external displays")
            }
            .settingsHighlight(id: highlightID("Always show on external displays"))
            .settingsInfo("Pins the pill above other windows on displays that have no real notch. Without this it is drawn but sits behind whatever window is in front, which looks like it is missing.")

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
