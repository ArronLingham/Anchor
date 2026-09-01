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

import Defaults
import SwiftUI

/// Editor for text snippets.
struct SettingsSnippets: View {
    @Default(.enableTextSnippets) private var enabled
    @Default(.textSnippets) private var snippets
    @State private var editing: TextSnippet?

    var body: some View {
        Section {
            Defaults.Toggle(key: .enableTextSnippets) {
                Text("Expand text snippets")
            }
            .settingsInfo("Type a short trigger anywhere and it becomes your text. Needs Accessibility and Input Monitoring, because it has to see what you type. Anchor never intercepts a keystroke — it only watches, then types the replacement — and it stops entirely in password fields.")
            if enabled && !hasAccessibility {
                Label(
                    "Accessibility is not granted, so snippets cannot expand. Grant it in System Settings › Privacy & Security › Accessibility.",
                    systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // The list is shown only while the feature is on. Offering it when
            // off invites someone to write three snippets and conclude the
            // feature is broken, having never found the toggle above.
            if enabled {
            if snippets.isEmpty {
                Text("No snippets yet.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }

            ForEach($snippets) { $snippet in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        TextField("Trigger", text: $snippet.trigger)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 140)
                            .font(.system(.body, design: .monospaced))

                        Image(systemName: "arrow.right")
                            .foregroundStyle(.tertiary)
                            .font(.caption)

                        TextField("Expands to", text: $snippet.expansion, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...4)

                        Button {
                            snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.red)
                        .help("Delete this snippet")
                    }

                    HStack(spacing: 10) {
                        Toggle("Expand immediately", isOn: $snippet.expandImmediately)
                            .toggleStyle(.checkbox)
                            .font(.caption)
                            .help("On: fires the moment the trigger is typed. Off: waits for a space or punctuation, so a trigger that is also a real word does not fire mid-sentence.")

                        if !snippet.isValid {
                            Label("Needs a trigger and an expansion", systemImage: "exclamationmark.circle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                .padding(.vertical, 3)
            }

            Button {
                snippets.append(TextSnippet(trigger: "", expansion: ""))
            } label: {
                Label("Add snippet", systemImage: "plus")
            }
            }
        } header: {
            Text("Text snippets")
        } footer: {
            VStack(alignment: .leading, spacing: 3) {
                Text("Placeholders you can use in an expansion:")
                ForEach(TextSnippet.Placeholder.allCases, id: \.self) { placeholder in
                    HStack(spacing: 6) {
                        Text(placeholder.rawValue)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.primary)
                        Text("— \(placeholder.explanation)")
                            .font(.caption2)
                    }
                }
            }
            .foregroundStyle(.secondary)
        }
    }

    /// Snippets silently do nothing without Accessibility, so the pane says so
    /// rather than leaving the user to wonder why nothing expands.
    private var hasAccessibility: Bool {
        AXIsProcessTrusted()
    }
}
