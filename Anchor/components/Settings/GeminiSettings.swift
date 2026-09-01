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

/// Settings for the Gemini assistant.
///
/// The key field is a `SecureField` deliberately. `ANCHOR_RENDER_UI` renders
/// every settings pane to a PNG, and the ntfy topic was readable out of one of
/// those before the harness was made Debug-only — an API key is the same class
/// of mistake waiting to be repeated.
struct GeminiSettings: View {
    @ObservedObject private var manager = GeminiManager.shared
    @State private var keyDraft = ""
    @State private var saveResult: String?

    private func highlightID(_ title: String) -> String {
        SettingsTab.gemini.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableGeminiAssistant) {
                    Text("Gemini assistant")
                }
                .settingsHighlight(id: highlightID("Gemini assistant"))
            } header: {
                Text("Assistant")
            } footer: {
                Text("Adds a Gemini tab to the open notch. Nothing is sent anywhere until you type a message.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    SecureField("API key", text: $keyDraft,
                                prompt: Text(manager.hasAPIKey ? "Stored in your Keychain" : "AIza…"))
                    Button("Save") {
                        guard GeminiProtocol.looksLikeAPIKey(keyDraft) else {
                            saveResult = "That does not look like an API key."
                            return
                        }
                        saveResult = manager.setAPIKey(keyDraft)
                            ? "Saved to the Keychain."
                            : "Could not write to the Keychain."
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty)
                }
                .settingsHighlight(id: highlightID("API key"))

                if manager.hasAPIKey {
                    Button("Remove stored key", role: .destructive) {
                        manager.clearAPIKey()
                        saveResult = "Key removed."
                    }
                }
                if let saveResult {
                    Text(saveResult).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("API key")
            } footer: {
                Text("Get a key from Google AI Studio. It is stored in your **Keychain**, never in Anchor's preferences file — that file is world-readable and the key is billable.\n\nRequests send it in a header rather than the URL, so it does not end up in proxy logs or crash reports.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Model", selection: Binding(
                    get: { Defaults[.geminiModel] },
                    set: { Defaults[.geminiModel] = $0 })) {
                    Text("Flash (fast, cheap)").tag("gemini-2.0-flash")
                    Text("Flash Lite").tag("gemini-2.0-flash-lite")
                    Text("Pro (slower, stronger)").tag("gemini-1.5-pro")
                }

                Defaults.Toggle(key: .geminiRememberConversation) {
                    Text("Remember the conversation")
                }
                .settingsInfo("Keeps your chat between launches so the assistant has context. Turning this off clears what is stored.")

                Picker("Turns of context", selection: Binding(
                    get: { Defaults[.geminiHistoryTurns] },
                    set: { Defaults[.geminiHistoryTurns] = $0 })) {
                    ForEach([6, 12, 20, 40], id: \.self) { Text("\($0)").tag($0) }
                }

                Button("Clear conversation") { manager.clearConversation() }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("More turns of context give better answers and cost more per request, because the whole history is sent each time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Text("Sapphire's version also does screen awareness and direct computer use. Neither is built here.\n\n**Screen awareness** needs Screen Recording, which is not granted to this build.\n\n**Tool execution** is left out on purpose: an assistant that turns model output into actions on your Mac can be steered by anything it reads. If you want it, it should ask before each action rather than act on its own — say so and it can be built that way.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("What this does not do")
            }
        }
        .formStyle(.grouped)
    }
}
