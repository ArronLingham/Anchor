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

import Defaults
import SwiftUI

struct ClaudeUsageSettings: View {
    @Default(.claudeUsageWatchEnabled) private var watchEnabled
    @Default(.claudeUsageAutoResume) private var autoResume

    /// Held in the Keychain rather than `Defaults`, so it is loaded once into
    /// local state and written back explicitly instead of being bound.
    @State private var topic: String = ""
    @State private var topicLoaded = false
    @State private var saveResult: SaveResult?
    @State private var testState: TestState = .idle

    private enum SaveResult: Equatable {
        case saved
        case cleared
        case failed
    }

    private enum TestState: Equatable {
        case idle
        case sending
        case sent
        case failed
    }

    private func highlightID(_ title: String) -> String {
        SettingsTab.claudeUsage.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .claudeUsageWatchEnabled) {
                    Text("Watch for usage limits")
                }
                .settingsHighlight(id: highlightID("Watch for usage limits"))

                Defaults.Toggle(key: .claudeUsageNotifyOnMac) {
                    Text("Show in the notch")
                }
                .disabled(!watchEnabled)
                .settingsHighlight(id: highlightID("Show in the notch"))
            } header: {
                Text("Claude Usage")
            } footer: {
                Text(
                    "Anchor watches Claude Code's own transcripts for the message that says when your usage window reopens, then counts down to it. Nothing polls and nothing is sent anywhere unless you set up a phone notification below."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                // Secure, not plain: the topic is the only access control on the
                // channel, so it should not be shoulder-surfable or captured by
                // anything that renders this pane.
                SecureField("ntfy topic", text: $topic, prompt: Text("e.g. anchor-a8f3c1d9"))
                    .textFieldStyle(.roundedBorder)
                    .disableAutocorrection(true)
                    .settingsHighlight(id: highlightID("ntfy topic"))

                HStack {
                    Button("Save") { saveTopic() }
                        .disabled(!topicLoaded)
                    Button("Send test") { sendTest() }
                        .disabled(trimmedTopic.isEmpty || testState == .sending)
                    Spacer()
                    statusLabel
                }
            } header: {
                Text("Phone notification")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        "Install the ntfy app on your phone and subscribe to a topic, then enter the same topic here. When a limit is hit, Anchor schedules the notification with ntfy immediately so it still arrives at the reset time even if this Mac is asleep."
                    )
                    Text(
                        "Anyone who knows the topic name can read it, so treat it as a password — use a long random one. It is stored in your Keychain, never in preferences. Only the reset time is sent; never your prompts, transcripts, or project names."
                    )
                }
                .foregroundStyle(.secondary)
                .font(.caption)
            }

            Section {
                Defaults.Toggle(key: .claudeUsageAutoResume) {
                    Text("Resume the halted session automatically")
                }
                .disabled(!watchEnabled)
                .settingsHighlight(id: highlightID("Resume the halted session automatically"))

                LabeledContent("Resume with") {
                    TextField("", text: resumePromptBinding, prompt: Text("continue"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 220)
                        .disabled(!autoResume || !watchEnabled)
                }
                .settingsHighlight(id: highlightID("Resume with"))
            } header: {
                Text("Auto-resume")
            } footer: {
                Text(
                    "Only the most recently halted session is resumed — restarting every queued session at once would exhaust the new window within minutes. A session that recovered on its own is left alone. If the task is still too big, it will stop again and resume on the next window."
                )
                .foregroundStyle(.secondary)
                .font(.caption)
            }
        }
        .onAppear(perform: loadTopic)
    }

    private var trimmedTopic: String {
        topic.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var resumePromptBinding: Binding<String> {
        Binding(
            get: { Defaults[.claudeUsageResumePrompt] },
            set: { Defaults[.claudeUsageResumePrompt] = $0 }
        )
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch (saveResult, testState) {
        case (_, .sending):
            Text("Sending…").foregroundStyle(.secondary)
        case (_, .sent):
            Label("Sent", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case (_, .failed):
            Label("Failed", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case (.saved, _):
            Label("Saved", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        case (.cleared, _):
            Text("Cleared").foregroundStyle(.secondary)
        case (.failed, _):
            Label("Keychain error", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        case (nil, .idle):
            EmptyView()
        }
    }

    private func loadTopic() {
        guard !topicLoaded else { return }
        topic = ClaudeUsageKeychain.ntfyTopic() ?? ""
        topicLoaded = true
    }

    private func saveTopic() {
        let value = trimmedTopic
        testState = .idle
        if value.isEmpty {
            saveResult = ClaudeUsageKeychain.setNtfyTopic(nil) ? .cleared : .failed
        } else {
            saveResult = ClaudeUsageKeychain.setNtfyTopic(value) ? .saved : .failed
        }
    }

    /// Sends immediately rather than scheduled — the point is to confirm the
    /// topic reaches the phone at all, which a delayed message would not show.
    private func sendTest() {
        saveTopic()
        guard saveResult != .failed else { return }
        testState = .sending
        PhonePush.send(
            title: String(localized: "Anchor test"),
            body: String(localized: "Phone notifications are working."),
            deliverAt: nil
        ) { ok in
            DispatchQueue.main.async { testState = ok ? .sent : .failed }
        }
    }
}
