/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Defaults
import SwiftUI

struct AIAssistantSettings: View {
    @ObservedObject private var manager = AIAssistantManager.shared
    @State private var keyDraft = ""
    @State private var saveResult: String?
    @Default(.aiHistoryTurns) private var aiHistoryTurns
    @Default(.aiProvider) private var aiProvider
    @Default(.aiModel) private var aiModel

    private func highlightID(_ title: String) -> String {
        SettingsTab.gemini.highlightID(for: title)
    }

    var body: some View {
        Form {
            Section {
                Defaults.Toggle(key: .enableAIAssistant) {
                    Text("AI Assistant")
                }
                .settingsHighlight(id: highlightID("AI Assistant"))
            } header: {
                Text("Assistant")
            }

            Section {
                Picker("Provider", selection: $aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                
                Picker("Model", selection: $aiModel) {
                    if aiProvider == .gemini {
                        Text("Flash 2.5").tag("gemini-2.5-flash")
                        Text("Pro 1.5").tag("gemini-1.5-pro-latest")
                        Text("Flash 2.0").tag("gemini-2.0-flash")
                    } else if aiProvider == .openai {
                        Text("GPT-4o").tag("gpt-4o")
                        Text("GPT-4o mini").tag("gpt-4o-mini")
                        Text("o1-preview").tag("o1-preview")
                    } else if aiProvider == .anthropic {
                        Text("Claude 3.5 Sonnet").tag("claude-3-5-sonnet-latest")
                        Text("Claude 3.5 Haiku").tag("claude-3-5-haiku-latest")
                    }
                }
                .onChange(of: aiProvider) { newProvider in
                    if newProvider == .gemini { aiModel = "gemini-2.5-flash" }
                    else if newProvider == .openai { aiModel = "gpt-4o-mini" }
                    else if newProvider == .anthropic { aiModel = "claude-3-5-sonnet-latest" }
                }
            } header: {
                Text("AI Provider & Model")
            }

            Section {
                HStack {
                    SecureField("Add API key", text: $keyDraft,
                                prompt: Text("Add a key for \(aiProvider.rawValue)…"))
                    Button("Add") {
                        let existing = manager.keys(for: aiProvider)
                        var updated = existing
                        updated.append(keyDraft)
                        let ok = manager.setKeys(updated, for: aiProvider)
                        saveResult = ok ? "Key added for \(aiProvider.rawValue)." : "Could not write key."
                        keyDraft = ""
                    }
                    .disabled(keyDraft.isEmpty)
                }
                
                let keys = manager.keys(for: aiProvider)
                if !keys.isEmpty {
                    List {
                        ForEach(keys.indices, id: \.self) { idx in
                            HStack {
                                Text("Key \(idx + 1): ••••••••••")
                                Spacer()
                                Button(role: .destructive) {
                                    var updated = keys
                                    updated.remove(at: idx)
                                    _ = manager.setKeys(updated, for: aiProvider)
                                } label: {
                                    Image(systemName: "trash")
                                }
                                .buttonStyle(.borderless)
                            }
                        }
                    }
                    .frame(height: max(CGFloat(keys.count * 35), 40))
                }

                if let saveResult {
                    Text(saveResult).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("API Keys")
            } footer: {
                Text("Add multiple keys for failover if one gets rate limited.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            Section {
                Defaults.Toggle(key: .aiRememberConversation) {
                    Text("Remember the conversation")
                }
                Picker("Turns of context", selection: $aiHistoryTurns) {
                    ForEach([6, 12, 20, 40], id: \.self) { Text("\($0)").tag($0) }
                }
                Button("Clear conversation") { manager.clearConversation() }
            } header: {
                Text("Behaviour")
            }
        }
        .formStyle(.grouped)
    }
}
