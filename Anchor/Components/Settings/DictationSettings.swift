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

import AVFoundation
import AppKit
import Defaults
import KeyboardShortcuts
import SwiftUI

struct DictationSettings: View {
    @Default(.enableDictation) private var enableDictation
    @Default(.dictationAutoPaste) private var autoPaste

    /// Re-checked when the window regains focus, since the user grants these in
    /// System Settings and comes back — polling for it would be wasteful.
    @State private var micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
    @State private var accessibilityTrusted = AXIsProcessTrusted()

    private func highlightID(_ title: String) -> String {
        SettingsTab.dictation.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableDictation) {
                    Text("Enable Dictation")
                }
                .settingsHighlight(id: highlightID("Enable Dictation"))

                KeyboardShortcuts.Recorder("Push-to-talk:", name: .pushToTalkDictation)
                    .disabled(!enableDictation)
                    .settingsHighlight(id: highlightID("Push-to-talk"))
            } header: {
                Text("Dictation")
            } footer: {
                Text(
                    "Hold the shortcut, speak, and release. Transcription runs entirely on-device using Apple's speech models — nothing is sent anywhere."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                permissionRow(
                    title: "Microphone",
                    granted: micStatus == .authorized,
                    detail: micStatus == .denied
                        ? "Denied — enable it in System Settings"
                        : "Needed to record your voice",
                    settingsPane: "Privacy_Microphone"
                )

                permissionRow(
                    title: "Accessibility",
                    granted: accessibilityTrusted,
                    detail: accessibilityTrusted
                        ? "Allows the transcript to be typed for you"
                        : "Without this the transcript is only copied, never pasted",
                    settingsPane: "Privacy_Accessibility"
                )
            } header: {
                Text("Permissions")
            }

            Section {
                Defaults.Toggle(key: .dictationAutoPaste) {
                    Text("Paste into the focused app")
                }
                .disabled(!enableDictation)
                .settingsHighlight(id: highlightID("Paste into the focused app"))

                if !autoPaste {
                    Text("The transcript will be copied to the clipboard instead.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Defaults.Toggle(key: .dictationTidyWhitespace) {
                    Text("Tidy spacing")
                }
                .disabled(!enableDictation)
                .settingsHighlight(id: highlightID("Tidy spacing"))

                Defaults.Toggle(key: .dictationFeedbackSound) {
                    Text("Play a sound when finished")
                }
                .disabled(!enableDictation)
                .settingsHighlight(id: highlightID("Play a sound when finished"))
            } header: {
                Text("Output")
            }

            Section {
                Defaults.Toggle(key: .showDictationLiveActivity) {
                    Text("Show in the notch while dictating")
                }
                .disabled(!enableDictation)
                .settingsHighlight(id: highlightID("Show in the notch while dictating"))
            } header: {
                Text("Appearance")
            } footer: {
                Text("Shows a level meter and the live transcript as you speak.")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
        ) { _ in
            micStatus = AVCaptureDevice.authorizationStatus(for: .audio)
            accessibilityTrusted = AXIsProcessTrusted()
        }
    }

    @ViewBuilder
    private func permissionRow(
        title: String, granted: Bool, detail: String, settingsPane: String
    ) -> some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? .green : .orange)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if !granted {
                Button("Open Settings…") {
                    NSWorkspace.shared.open(
                        URL(
                            string:
                                "x-apple.systempreferences:com.apple.preference.security?\(settingsPane)"
                        )!)
                }
                .buttonStyle(.link)
            }
        }
    }
}
