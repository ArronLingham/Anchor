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
        
        var success = false
        for key in availableKeys {
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
                    if http.statusCode == 429 {
                        // Rate limited, try next key
                        continue
                    }
                    if http.statusCode == 401 || http.statusCode == 403 {
                        lastError = "The API key was rejected (HTTP \(http.statusCode))."
                        return
                    }
                }
                
                switch AIProtocol.parse(provider: provider, data: data) {
                case .reply(let reply):
                    messages.append(AIMessage(role: .model, text: reply))
                    persistHistory()
                    success = true
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
            lastError = "All keys rate limited or failed."
        }
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
