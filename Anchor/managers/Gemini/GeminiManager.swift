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
import Combine
import Defaults
import Foundation

/// The Gemini assistant in the notch.
///
/// ## Scope, stated plainly
///
/// Sapphire's version advertises "tool execution and direct computer use".
/// **That is not built here, deliberately.** An agent that turns model output
/// into actions on the machine is one prompt injection away from running
/// whatever a web page it read told it to. The chat, the memory and the voice
/// input below are the useful part and carry none of that risk; if tool use is
/// wanted later it needs per-action confirmation, not autonomy, and that is a
/// design decision rather than a missing afternoon of typing.
///
/// Screen awareness is also absent, for a duller reason: Screen Recording is
/// not granted to this bundle id — see the TCC note in CLAUDE.md.
///
/// ## Cost
///
/// Nothing runs unless the user sends a message. No timer, no background
/// polling, no connection held open.
@MainActor
final class GeminiManager: ObservableObject {
    static let shared = GeminiManager()

    @Published private(set) var messages: [GeminiMessage] = []
    @Published private(set) var isSending = false
    @Published private(set) var lastError: String?
    /// Whether a key is stored. The key itself is never published.
    @Published private(set) var hasAPIKey = false

    private var cancellables = Set<AnyCancellable>()
    private var started = false

    private init() {}

    func start() {
        guard !started else { return }
        started = true
        hasAPIKey = GeminiCredential.read() != nil
        loadHistory()
    }

    // MARK: Key

    func setAPIKey(_ key: String) -> Bool {
        let ok = GeminiCredential.write(key)
        hasAPIKey = GeminiCredential.read() != nil
        return ok
    }

    func clearAPIKey() {
        GeminiCredential.delete()
        hasAPIKey = false
    }

    // MARK: Conversation

    func clearConversation() {
        messages = []
        persistHistory()
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isSending else { return }

        guard let key = GeminiCredential.read() else {
            lastError = "Add a Gemini API key in Settings first."
            return
        }
        guard let url = GeminiProtocol.endpoint(model: Defaults[.geminiModel]) else {
            lastError = "Could not build the request URL."
            return
        }

        messages.append(GeminiMessage(role: .user, text: trimmed))
        persistHistory()
        isSending = true
        lastError = nil
        defer { isSending = false }

        let history = GeminiProtocol.trimmed(messages, limit: Defaults[.geminiHistoryTurns])
        let body = GeminiProtocol.requestBody(
            history: history,
            systemInstruction: Defaults[.geminiSystemInstruction])

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // Header, not `?key=` — see GeminiProtocol.endpoint.
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
                lastError = "The API key was rejected (HTTP \(http.statusCode))."
                return
            }
            switch GeminiProtocol.parse(data) {
            case .reply(let reply):
                // The reply is appended as text and rendered as text. It is
                // never interpreted, executed, or matched for commands.
                messages.append(GeminiMessage(role: .model, text: reply))
                persistHistory()
            case .failure(let message):
                lastError = message
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Persistence

    /// History lives in `Defaults`, which is fine — it is the user's own
    /// conversation, not a credential. The key is the only secret here and it
    /// is in the Keychain.
    private func loadHistory() {
        guard Defaults[.geminiRememberConversation] else { return }
        guard let data = Defaults[.geminiHistory].data(using: .utf8),
              let decoded = try? JSONDecoder().decode([GeminiMessage].self, from: data)
        else { return }
        messages = decoded
    }

    private func persistHistory() {
        guard Defaults[.geminiRememberConversation] else {
            Defaults[.geminiHistory] = ""
            return
        }
        // Cap what is stored so a long conversation cannot grow the plist
        // without bound.
        let recent = Array(messages.suffix(100))
        guard let data = try? JSONEncoder().encode(recent),
              let json = String(data: data, encoding: .utf8)
        else { return }
        Defaults[.geminiHistory] = json
    }
}
