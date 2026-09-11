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
    @Default(.enableAIAssistant) private var enableAIAssistant
    @Default(.aiHistoryTurns) private var aiHistoryTurns
    @Default(.aiProvider) private var aiProvider
    @Default(.aiModel) private var aiModel

    /// Live list when the provider has answered, a short built-in list until
    /// then — never empty, so the picker always has something to show.
    private var modelChoices: [String] {
        manager.availableModels.isEmpty
            ? AIProtocol.fallbackModels(for: aiProvider)
            : manager.availableModels
    }

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

            if enableAIAssistant {
                Section {
                Picker("Provider", selection: $aiProvider) {
                    ForEach(AIProvider.allCases, id: \.self) { p in
                        Text(p.rawValue).tag(p)
                    }
                }
                
                // Populated from the provider's own model list, not a
                // hardcoded one. The hardcoded version is what went stale: it
                // offered a model the API had stopped serving, so every message
                // failed and the picker could not help you fix it.
                Picker("Model", selection: $aiModel) {
                    ForEach(modelChoices, id: \.self) { id in
                        Text(id).tag(id)
                    }
                    // Keep whatever is stored selectable even when it is not in
                    // the list, so opening Settings never silently reassigns it.
                    if !modelChoices.contains(aiModel) {
                        Text(aiModel).tag(aiModel)
                    }
                }
                .settingsHighlight(id: highlightID("Model"))
                .onChange(of: aiProvider) { _, _ in
                    // Model ids do not carry across providers; reset to the
                    // first the new provider offers, then ask what it has.
                    aiModel = AIProtocol.fallbackModels(for: aiProvider).first ?? aiModel
                    manager.refreshModels()
                }

                HStack {
                    Button {
                        manager.refreshModels()
                    } label: {
                        Label(
                            manager.isLoadingModels ? "Loading models…" : "Reload model list",
                            systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.link)
                    .disabled(manager.isLoadingModels)
                    Spacer()
                    if !manager.availableModels.isEmpty {
                        Text("\(manager.availableModels.count) available")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let err = manager.modelListError {
                    Text(err).font(.caption).foregroundStyle(.orange)
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
        }
        .formStyle(.grouped)
    }
}
