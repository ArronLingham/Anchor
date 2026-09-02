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

import Foundation

/// Every settings pane's own sections, so the sidebar can list them.
///
/// A pane is one long Form and its sections are the only structure inside it;
/// without this the sidebar could take you to "Controls" but not to the
/// "Placement" or "Step size" part of it.
///
/// `anchor` is the highlight id of the FIRST row in that section, because
/// section headers carry no id of their own — adding one to all 135 of them
/// would be a far larger change than pointing at the row underneath.
///
/// Generated from the panes themselves and pinned by
/// tests/run_settingssections_tests.sh, so a renamed section cannot leave the
/// sidebar pointing at nothing.
enum SettingsSectionIndex {
    struct Section: Identifiable, Hashable {
        let title: String
        /// Highlight id of the first row in the section.
        let anchor: String
        var id: String { anchor }
    }

    static let sections: [SettingsTab: [Section]] = [
        .appearance: [.init(title: "General", anchor: "Settings icon in notch"), .init(title: "Display Style", anchor: "Main screen style"), .init(title: "Lock Screen Glass", anchor: "Lock screen material"), .init(title: "Media", anchor: "Enable colored spectrograms"), .init(title: "Additional features", anchor: "Idle Animation"), .init(title: "Colour picker", anchor: "Screen colour picker"), .init(title: "App icon", anchor: "App icon"), .init(title: "Notch Width", anchor: "Customize physical notch width")],
        .battery: [.init(title: "General", anchor: "Show battery indicator"), .init(title: "Battery Information", anchor: "Show battery percentage"), .init(title: "History", anchor: "Record battery history"), .init(title: "Battery HUDs", anchor: "Charging HUD"), .init(title: "HUD Duration", anchor: "Charging duration"), .init(title: "Low Battery", anchor: "Low battery style"), .init(title: "Full Battery", anchor: "Full battery style")],
        .calendar: [.init(title: "Third-party Calendar Integration", anchor: "Enable third-party calendar app launch")],
        .claudeUsage: [.init(title: "Claude Usage", anchor: "Watch for usage limits"), .init(title: "Phone notification", anchor: "ntfy topic"), .init(title: "Auto-resume", anchor: "Resume the halted session automatically")],
        .cleanup: [.init(title: "Reclaim space", anchor: "Scan"), .init(title: "Updates", anchor: "Check for updates")],
        .clipboard: [.init(title: "Clipboard Manager", anchor: "Enable Clipboard Manager"), .init(title: "Settings", anchor: "Show Clipboard Icon"), .init(title: "Clipboard tools", anchor: "Clean tracking parameters from copied links")],
        .dictation: [.init(title: "Dictation", anchor: "Enable Dictation"), .init(title: "Output", anchor: "Paste into the focused app"), .init(title: "Appearance", anchor: "Show in the notch while dictating")],
        .downloads: [.init(title: "Download Detection", anchor: "Enable download detection")],
        .gemini: [.init(title: "Assistant", anchor: "AI Assistant"), .init(title: "AI Provider & Model", anchor: "Model")],
        .general: [.init(title: "UI Mode", anchor: "Enable Minimalistic UI"), .init(title: "Desktop", anchor: "Show desktop number"), .init(title: "Windows", anchor: "Snap windows to screen edges"), .init(title: "Pointer", anchor: "Invert mouse wheel scrolling"), .init(title: "Keyboard", anchor: "Filter repeated keystrokes"), .init(title: "Media apps", anchor: "Stop Music opening itself"), .init(title: "Alerts", anchor: "Warn when the battery is low"), .init(title: "Disk images", anchor: "Offer to install apps from disk images"), .init(title: "Stats", anchor: "System stats"), .init(title: "Shelf", anchor: "File shelf"), .init(title: "Eye break", anchor: "Eye break reminders"), .init(title: "System features", anchor: "Menubar icon"), .init(title: "Notch Height", anchor: "Notch display height"), .init(title: "Gesture control", anchor: "Enable gestures"), .init(title: "Notch behavior", anchor: "Keep the notch open")],
        .hudAndOSD: [.init(title: "Controls", anchor: "Volume OSD"), .init(title: "Appearance", anchor: "Material"), .init(title: "Step size", anchor: "Volume step"), .init(title: "Bluetooth Audio Devices", anchor: "Show Bluetooth device connections"), .init(title: "Battery Indicator Styling", anchor: "Color-coded battery display"), .init(title: "Audio feedback", anchor: "Play feedback when volume is changed"), .init(title: "Dynamic Island Progress Bars", anchor: "Color-coded volume display")],
        .launcher: [.init(title: "Launcher", anchor: "Enable Launcher"), .init(title: "App switcher", anchor: "Enable app switcher"), .init(title: "Grid", anchor: "Show all apps when the field is empty"), .init(title: "Results", anchor: "Evaluate arithmetic"), .init(title: "Index", anchor: "Rebuild index now")],
        .liveActivities: [.init(title: "Screen Recording", anchor: "Enable Screen Recording Detection"), .init(title: "Do Not Disturb", anchor: "Enable Focus Detection"), .init(title: "Caps Lock Indicator", anchor: "Show Caps Lock Indicator"), .init(title: "Privacy Indicators", anchor: "Enable Microphone Detection"), .init(title: "Media Live Activity", anchor: "Enable music live activity"), .init(title: "Reminder Live Activity", anchor: "Enable reminder live activity")],
        .lockScreen: [.init(title: "Live Activity & Feedback", anchor: "Enable lock screen live activity"), .init(title: "Preview", anchor: "Preview lock screen widgets"), .init(title: "Lock Screen Glass", anchor: "Material"), .init(title: "Media Panel", anchor: "Show lock screen media panel"), .init(title: "Timer Widget", anchor: "Show lock screen timer"), .init(title: "Weather Widget", anchor: "Show lock screen weather"), .init(title: "Reminder Widget", anchor: "Show lock screen reminder"), .init(title: "Battery Widget", anchor: "Show battery indicator"), .init(title: "Focus Widget", anchor: "Show focus widget"), .init(title: "Calendar Widget", anchor: "Show next calendar event")],
        .media: [.init(title: "Per-app audio", anchor: "Per-app mute"), .init(title: "Audio devices", anchor: "Pin microphone"), .init(title: "Camera", anchor: "Camera mirror"), .init(title: "External display brightness", anchor: "External display brightness"), .init(title: "Media Source", anchor: "Music Source"), .init(title: "Dynamic Island Visibility", anchor: "Show media controls in Dynamic Island"), .init(title: "Media controls", anchor: "Show Change Media Output control"), .init(title: "Floating window panel skip behaviour", anchor: "Skip buttons"), .init(title: "Media playback live activity", anchor: "Enable lyrics"), .init(title: "Music Visualizer", anchor: "Enable real-time waveform"), .init(title: "Lock Screen Integration", anchor: "Show merged AirPlay and output devices")],
        .menuBar: [.init(title: "Live readout", anchor: "Show CPU")],
        .notes: [.init(title: "Apple Notes", anchor: "Sync with Apple Notes")],
        .shortcuts: [.init(title: "General", anchor: "Enable global keyboard shortcuts")],
        .terminal: [.init(title: "General", anchor: "Enable terminal"), .init(title: "Shell", anchor: "Shell path"), .init(title: "Appearance", anchor: "Font family"), .init(title: "Colors", anchor: "Background color"), .init(title: "Cursor", anchor: "Cursor style"), .init(title: "Scrollback", anchor: "Scrollback lines"), .init(title: "Input", anchor: "Option as Meta")],
        .timer: [.init(title: "Timer Feature", anchor: "Enable timer feature"), .init(title: "Lock Screen Integration", anchor: "Show lock screen timer widget"), .init(title: "Appearance", anchor: "Timer tint")],
    ]

    static func sections(for tab: SettingsTab) -> [Section] { sections[tab] ?? [] }
}
