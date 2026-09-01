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

import Foundation

/// One turn in a conversation.
struct GeminiMessage: Equatable, Identifiable, Codable {
    enum Role: String, Codable { case user, model }
    let id: UUID
    let role: Role
    var text: String

    init(id: UUID = UUID(), role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

/// Builds requests and reads replies.
///
/// Pure, so the wire format can be tested without a key, a network or a bill.
/// Everything here is shaped by one rule: **the model's output is data, never
/// instructions to this app.** Nothing in the parse path can cause an action.
enum GeminiProtocol {

    static let defaultModel = "gemini-2.0-flash"
    private static let host = "https://generativelanguage.googleapis.com"

    /// The endpoint for a model.
    ///
    /// The key is **not** in the URL, even though Google's own examples put it
    /// there as `?key=…`. URLs are logged by proxies, land in crash reports and
    /// show up in `nettop`; a billable credential does not belong in one. The
    /// `x-goog-api-key` header carries it instead, which the API accepts
    /// identically.
    static func endpoint(model: String = defaultModel) -> URL? {
        URL(string: "\(host)/v1beta/models/\(model):generateContent")
    }

    /// Trims history to the most recent `limit` turns, keeping pairs intact.
    ///
    /// Gemini rejects a `contents` array that starts with a `model` turn, so a
    /// naive "keep the last N" produces a 400 roughly half the time. This drops
    /// a leading model turn after trimming.
    static func trimmed(_ history: [GeminiMessage], limit: Int) -> [GeminiMessage] {
        guard limit > 0 else { return [] }
        var kept = Array(history.suffix(limit))
        while let first = kept.first, first.role == .model { kept.removeFirst() }
        return kept
    }

    /// The JSON body for a request.
    static func requestBody(history: [GeminiMessage],
                            systemInstruction: String?) -> [String: Any] {
        var body: [String: Any] = [
            "contents": history.map { message in
                [
                    "role": message.role.rawValue,
                    "parts": [["text": message.text]],
                ]
            }
        ]
        if let systemInstruction, !systemInstruction.isEmpty {
            body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
        }
        return body
    }

    enum ParseResult: Equatable {
        case reply(String)
        /// A structured API error, surfaced to the user rather than swallowed.
        case failure(String)
    }

    /// Reads a `generateContent` response.
    ///
    /// Handles the three shapes that actually occur: a normal reply, an
    /// `error` object, and a candidate with no text — which happens when the
    /// response was blocked, and which must not be reported as an empty
    /// message from the assistant.
    static func parse(_ data: Data) -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return .failure("The reply could not be read.") }

        if let error = root["error"] as? [String: Any] {
            let message = (error["message"] as? String) ?? "Unknown error"
            let status = (error["status"] as? String).map { " (\($0))" } ?? ""
            return .failure(message + status)
        }

        guard let candidates = root["candidates"] as? [[String: Any]],
              let first = candidates.first
        else { return .failure("The model returned no reply.") }

        // A blocked response has a finishReason but no usable parts. Saying so
        // is better than showing an empty bubble.
        let text = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]])?
            .compactMap { $0["text"] as? String }
            .joined()

        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            let reason = (first["finishReason"] as? String) ?? "no content"
            return .failure("The model stopped without replying (\(reason)).")
        }
        return .reply(text)
    }

    /// Whether a string looks like a Google API key.
    ///
    /// Only a shape check, to catch an obviously pasted-wrong value before
    /// spending a network round trip. It deliberately does **not** reject
    /// anything unusual — Google has changed key formats before, and a
    /// validator that is too strict locks the user out of their own key.
    static func looksLikeAPIKey(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 20 else { return false }
        guard !trimmed.contains(" "), !trimmed.contains("\n") else { return false }
        return true
    }
}
