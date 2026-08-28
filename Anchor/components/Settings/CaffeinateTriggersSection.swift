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
import Defaults
import SwiftUI
import UniformTypeIdentifiers

/// Conditions that hold the keep-awake assertion on their own.
///
/// Split out of `SettingsGeneral` rather than added to it: that file is already
/// long, and the app-trigger list needs its own local state for the picker.
struct CaffeinateTriggersSection: View {
    let highlightID: (String) -> String

    @Default(.caffeinateTriggerWhileOnPower) private var onPower
    @Default(.caffeinateTriggerWhileExternalDisplay) private var onExternalDisplay
    @Default(.caffeinateTriggerApps) private var triggerApps
    @Default(.caffeinateJigglePointer) private var jigglePointer

    @ObservedObject private var caffeinate = CaffeinateManager.shared

    var body: some View {
        Toggle("Also stay awake while plugged in", isOn: $onPower)
            .settingsHighlight(id: highlightID("Also stay awake while plugged in"))
            .help("Takes effect on the power-source notification, not a timer.")

        Toggle("Also stay awake with an external display", isOn: $onExternalDisplay)
            .settingsHighlight(id: highlightID("Also stay awake with an external display"))
            .help("Any display other than the built-in one counts.")

        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Also stay awake while these apps run")
                Spacer()
                Button("Add App…") { addApp() }
                    .controlSize(.small)
            }

            if triggerApps.isEmpty {
                Text("No apps chosen.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(triggerApps, id: \.self) { bundleID in
                    HStack(spacing: 8) {
                        appIcon(for: bundleID)
                            .resizable()
                            .frame(width: 16, height: 16)
                        Text(appName(for: bundleID))
                            .font(.callout)
                        Spacer()
                        Button {
                            triggerApps.removeAll { $0 == bundleID }
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Stop this app from keeping the Mac awake")
                    }
                }
            }
        }
        .settingsHighlight(id: highlightID("Also stay awake while these apps run"))

        Toggle("Nudge the pointer while awake", isOn: $jigglePointer)
            .settingsHighlight(id: highlightID("Nudge the pointer while awake"))
            .help(
                "A power assertion only tells macOS not to sleep. Other apps decide "
                + "you are away from real pointer and keyboard activity, so this moves "
                + "the pointer one point and back every minute while the Mac is being "
                + "kept awake. Needs Accessibility.")

        if !caffeinate.reasons.isEmpty {
            HStack(spacing: 4) {
                Image(systemName: "bolt.fill")
                    .foregroundStyle(.yellow)
                Text("Awake: \(reasonSummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var reasonSummary: String {
        caffeinate.reasons
            .map(\.label)
            .sorted()
            .joined(separator: ", ")
    }

    // MARK: - App picker

    /// Picks by bundle identifier, not path, so an app that moves or updates
    /// keeps its trigger.
    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.prompt = String(localized: "Choose")

        guard panel.runModal() == .OK else { return }

        for url in panel.urls {
            guard let bundle = Bundle(url: url),
                  let identifier = bundle.bundleIdentifier,
                  !triggerApps.contains(identifier)
            else { continue }
            triggerApps.append(identifier)
        }
    }

    private func appURL(for bundleID: String) -> URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    private func appName(for bundleID: String) -> String {
        guard let url = appURL(for: bundleID) else { return bundleID }
        return FileManager.default.displayName(atPath: url.path)
    }

    private func appIcon(for bundleID: String) -> Image {
        guard let url = appURL(for: bundleID) else {
            return Image(systemName: "app.dashed")
        }
        return Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
    }
}
