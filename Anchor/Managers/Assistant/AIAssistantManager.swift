/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import AppKit
import Combine
import Defaults
import Foundation
import CoreGraphics

@MainActor
final class AIAssistantManager: ObservableObject {
    static let shared = AIAssistantManager()

    @Published private(set) var messages: [AIMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?
    @Published private(set) var hasAPIKey = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {
        Defaults.observe(.aiProvider) { [weak self] _ in
            self?.checkKey()
        }.tieToLifetime(of: self)
    }

    func start() {
        guard !started else { return }
        started = true
        checkKey()
        loadHistory()
    }

    private func checkKey() {
        hasAPIKey = !keys(for: Defaults[.aiProvider]).isEmpty
    }

    func keys(for provider: AIProvider) -> [String] {
        AIAssistantCredential.read(provider: provider)
    }

    func setKeys(_ keys: [String], for provider: AIProvider) -> Bool {
        let ok = AIAssistantCredential.write(keys, provider: provider)
        if provider == Defaults[.aiProvider] { checkKey() }
        return ok
    }

    func clearKeys(for provider: AIProvider) {
        AIAssistantCredential.delete(provider: provider)
        if provider == Defaults[.aiProvider] { checkKey() }
    }

    // MARK: - Model listing

    /// Models this key may actually use, fetched from the provider.
    ///
    /// Empty until the first fetch answers; the settings picker falls back to
    /// `AIProtocol.fallbackModels` so it is never blank.
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var isLoadingModels = false
    @Published private(set) var modelListError: String?

    /// Asks the provider which models it will serve.
    ///
    /// Enumerating rather than hardcoding is the whole point: the previous
    /// hardcoded list named a model the API had stopped serving, and the only
    /// symptom was the assistant failing with an error the picker could not
    /// help you fix.
    func refreshModels() {
        let provider = Defaults[.aiProvider]
        guard let key = keys(for: provider).first, !key.isEmpty else {
            availableModels = []
            modelListError = String(localized: "Add an API key first.")
            return
        }
        guard let request = AIProtocol.buildModelListRequest(provider: provider, key: key) else { return }
        isLoadingModels = true
        modelListError = nil
        Task { [weak self] in
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                let models = AIProtocol.parseModelList(provider: provider, data: data)
                await MainActor.run {
                    guard let self else { return }
                    self.isLoadingModels = false
                    if models.isEmpty {
                        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                        self.modelListError = code == 401 || code == 403
                            ? String(localized: "That key was rejected.")
                            : String(localized: "No usable models came back.")
                    } else {
                        self.availableModels = models
                        // A stored model the account can no longer use is the
                        // original bug. Correct it rather than leaving a
                        // selection that will fail on the next message.
                        let current = Defaults[.aiModel]
                        let bare = current.hasPrefix("models/")
                            ? String(current.dropFirst("models/".count)) : current
                        if !models.contains(bare), let first = models.first {
                            Defaults[.aiModel] = first
                        }
                    }
                }
            } catch {
                await MainActor.run {
                    self?.isLoadingModels = false
                    self?.modelListError = error.localizedDescription
                }
            }
        }
    }

    func clearConversation() {
        messages = []
        persistHistory()
    }

    func send(_ text: String, screenshot: Data? = nil) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let isTextEmpty = trimmed.isEmpty
        guard (!isTextEmpty || screenshot != nil), !isSending else { return }

        let provider = Defaults[.aiProvider]
        let availableKeys = keys(for: provider)
        guard !availableKeys.isEmpty else {
            lastError = "Add a \(provider.rawValue) API key in Settings first."
            return
        }

        messages.append(AIMessage(role: .user, text: trimmed, imageData: screenshot))
        persistHistory()
        isSending = true
        lastError = nil
        defer { isSending = false }

        let history = AIProtocol.trimmed(messages, limit: Defaults[.aiHistoryTurns])
        
        // Start from whichever key last worked, then wrap.
        //
        // Always starting at index 0 means a dead or exhausted first key costs
        // a wasted round trip on every single message for the rest of the day —
        // which is the thing having several keys was supposed to avoid.
        let start = liveKeyIndex(for: provider, count: availableKeys.count)
        let ordered = Array(availableKeys[start...] + availableKeys[..<start])

        var success = false
        var exhausted: [String] = []
        for (offset, key) in ordered.enumerated() {
            guard let request = AIProtocol.buildRequest(
                provider: provider,
                model: Defaults[.aiModel],
                key: key,
                history: history,
                systemInstruction: Defaults[.aiSystemInstruction]
            ) else {
                lastError = "Could not build the request URL."
                return
            }

            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                if let http = response as? HTTPURLResponse {
                    // Quota, and a rejected key, both mean "not this one" —
                    // advance rather than give up. Returning on 401/403 was the
                    // bug: one stale key at the front stopped the others from
                    // ever being tried, so adding a second key fixed nothing.
                    if http.statusCode == 429 {
                        exhausted.append(String(localized: "one key is rate limited"))
                        continue
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        exhausted.append(String(localized: "one key was rejected"))
                        continue
                    }
                }
                
                switch AIProtocol.parse(provider: provider, data: data) {
                case .reply(let reply):
                    messages.append(AIMessage(role: .model, text: reply))
                    persistHistory()
                    success = true
                    // Remember which key answered, so the next message starts
                    // here instead of walking the dead ones again.
                    setLiveKeyIndex((start + offset) % availableKeys.count, for: provider)
                case .failure(let message):
                    lastError = message
                }
                
                if success || lastError != nil {
                    break
                }
            } catch {
                lastError = error.localizedDescription
                break
            }
        }
        
        if !success && lastError == nil {
            lastError = availableKeys.count == 1
                ? String(localized: "The key was rejected or is out of quota.")
                : String(localized: "All \(availableKeys.count) keys failed — \(exhausted.joined(separator: ", ")).")
        }
    }

    // MARK: - Key rotation

    /// Which key answered last, per provider. In memory only: keys live in the
    /// Keychain and can change under us, so an index persisted across launches
    /// would eventually point at a different key than the one it recorded.
    private var liveKeyIndexByProvider: [AIProvider: Int] = [:]

    private func liveKeyIndex(for provider: AIProvider, count: Int) -> Int {
        guard count > 0 else { return 0 }
        let stored = liveKeyIndexByProvider[provider] ?? 0
        // A key may have been removed since, so never index past the end.
        return stored < count ? stored : 0
    }

    private func setLiveKeyIndex(_ index: Int, for provider: AIProvider) {
        liveKeyIndexByProvider[provider] = index
    }

    private func loadHistory() {
        guard Defaults[.aiRememberConversation] else { return }
        guard let data = Defaults[.aiHistory].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([AIMessage].self, from: data)
        else { return }
        messages = decoded
    }

    private func persistHistory() {
        guard Defaults[.aiRememberConversation] else {
            Defaults[.aiHistory] = ""
            return
        }
        let recent = Array(messages.suffix(100))
        guard let data = try? JSONEncoder().encode(recent),
              let json = String(data: data, encoding: .utf8)
        else { return }
        Defaults[.aiHistory] = json
    }
}
