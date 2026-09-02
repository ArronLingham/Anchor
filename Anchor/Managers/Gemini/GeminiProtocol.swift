/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 */

import Foundation
import CoreGraphics

/// One turn in a conversation.
struct AIMessage: Equatable, Identifiable, Codable {
    enum Role: String, Codable { case user, model }
    let id: UUID
    let role: Role
    var text: String
    var imageData: Data?

    init(id: UUID = UUID(), role: Role, text: String, imageData: Data? = nil) {
        self.id = id
        self.role = role
        self.text = text
        self.imageData = imageData
    }
}

import Defaults

enum AIProvider: String, Codable, CaseIterable, Defaults.Serializable {
    case gemini = "Gemini"
    case openai = "OpenAI"
    case anthropic = "Anthropic"
}

enum AIProtocol {
    enum ParseResult: Equatable {
        case reply(String)
        case failure(String)
    }

    static func trimmed(_ history: [AIMessage], limit: Int) -> [AIMessage] {
        guard limit > 0 else { return [] }
        var kept = Array(history.suffix(limit))
        while let first = kept.first, first.role == .model { kept.removeFirst() }
        return kept
    }

    /// A request that asks the provider which models this key may use.
    ///
    /// The model picker used to be a hardcoded list, and it went stale exactly
    /// as you would expect — the default named a model the API no longer
    /// served, so the assistant failed with a model error and nothing in the UI
    /// hinted why. Enumerating is the only version of this that stays correct.
    ///
    /// Same credential rule as `buildRequest`: the key travels in a header,
    /// never in the URL.
    static func buildModelListRequest(provider: AIProvider, key: String) -> URLRequest? {
        let url: URL?
        switch provider {
        case .gemini:  url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models")
        case .openai:  url = URL(string: "https://api.openai.com/v1/models")
        case .anthropic: url = URL(string: "https://api.anthropic.com/v1/models")
        }
        guard let url else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        switch provider {
        case .gemini:
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        case .openai:
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        case .anthropic:
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        }
        return request
    }

    /// Model ids from a ListModels response, newest-looking first.
    ///
    /// Gemini reports `supportedGenerationMethods`; anything that cannot
    /// `generateContent` (embedding and tuning endpoints, mostly) is dropped,
    /// because offering one in the picker produces a 400 the user cannot
    /// diagnose.
    static func parseModelList(provider: AIProvider, data: Data) -> [String] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        switch provider {
        case .gemini:
            let models = (root["models"] as? [[String: Any]]) ?? []
            return models.compactMap { m in
                let methods = (m["supportedGenerationMethods"] as? [String]) ?? []
                guard methods.contains("generateContent") else { return nil }
                guard let name = m["name"] as? String else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }
        case .openai:
            let models = (root["data"] as? [[String: Any]]) ?? []
            return models.compactMap { $0["id"] as? String }
                // Chat completions only; the account also lists embeddings,
                // moderation, whisper and tts, none of which can answer here.
                .filter { $0.hasPrefix("gpt-") || $0.hasPrefix("o1") || $0.hasPrefix("o3") || $0.hasPrefix("o4") }
        case .anthropic:
            let models = (root["data"] as? [[String: Any]]) ?? []
            return models.compactMap { $0["id"] as? String }
        }
    }

    /// What to offer before the API has answered, and if it never does.
    ///
    /// Deliberately short. A long hardcoded list is what went stale; this is a
    /// fallback so the picker is never empty, not a catalogue.
    static func fallbackModels(for provider: AIProvider) -> [String] {
        switch provider {
        case .gemini:    return ["gemini-3.6-flash", "gemini-3.5-flash-lite"]
        case .openai:    return ["gpt-4o-mini", "gpt-4o"]
        case .anthropic: return ["claude-sonnet-4-5", "claude-haiku-4-5"]
        }
    }

    static func buildRequest(provider: AIProvider, model: String, key: String, history: [AIMessage], systemInstruction: String?) -> URLRequest? {
        switch provider {
        case .gemini:
            // Gemini's own ListModels returns names as "models/gemini-…", and
            // users paste them that way. Strip the prefix rather than building
            // ".../models/models/gemini-…", which 404s.
            let bare = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
            let urlStr = "https://generativelanguage.googleapis.com/v1beta/models/\(bare):generateContent"
            guard let url = URL(string: urlStr) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
            
            var body: [String: Any] = [
                "contents": history.map { message -> [String: Any] in
                    var parts: [[String: Any]] = [["text": message.text]]
                    if let img = message.imageData {
                        parts.append([
                            "inlineData": [
                                "mimeType": "image/jpeg",
                                "data": img.base64EncodedString()
                            ]
                        ])
                    }
                    return [
                        "role": message.role.rawValue,
                        "parts": parts,
                    ]
                }
            ]
            if let systemInstruction, !systemInstruction.isEmpty {
                body["systemInstruction"] = ["parts": [["text": systemInstruction]]]
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
            
        case .openai:
            let urlStr = "https://api.openai.com/v1/chat/completions"
            guard let url = URL(string: urlStr) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            
            var msgs: [[String: Any]] = []
            if let systemInstruction, !systemInstruction.isEmpty {
                msgs.append(["role": "system", "content": systemInstruction])
            }
            for message in history {
                let role = message.role == .user ? "user" : "assistant"
                if let img = message.imageData {
                    msgs.append([
                        "role": role,
                        "content": [
                            ["type": "text", "text": message.text],
                            ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(img.base64EncodedString())"]]
                        ]
                    ])
                } else {
                    msgs.append(["role": role, "content": message.text])
                }
            }
            let body: [String: Any] = [
                "model": model,
                "messages": msgs
            ]
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
            
        case .anthropic:
            let urlStr = "https://api.anthropic.com/v1/messages"
            guard let url = URL(string: urlStr) else { return nil }
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(key, forHTTPHeaderField: "x-api-key")
            request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            
            var msgs: [[String: Any]] = []
            for message in history {
                let role = message.role == .user ? "user" : "assistant"
                var content: [[String: Any]] = [["type": "text", "text": message.text]]
                if let img = message.imageData {
                    content.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/jpeg",
                            "data": img.base64EncodedString()
                        ]
                    ])
                }
                msgs.append(["role": role, "content": content])
            }
            
            var body: [String: Any] = [
                "model": model,
                "max_tokens": 1024,
                "messages": msgs
            ]
            if let systemInstruction, !systemInstruction.isEmpty {
                body["system"] = systemInstruction
            }
            request.httpBody = try? JSONSerialization.data(withJSONObject: body)
            return request
        }
    }

    static func parse(provider: AIProvider, data: Data) -> ParseResult {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .failure("The reply could not be read.")
        }
        
        switch provider {
        case .gemini:
            if let error = root["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Unknown error"
                return .failure(message)
            }
            guard let candidates = root["candidates"] as? [[String: Any]],
                  let first = candidates.first else { return .failure("The model returned no reply.") }
            let text = ((first["content"] as? [String: Any])?["parts"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined()
            guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .failure("The model stopped without replying.")
            }
            return .reply(text)
            
        case .openai:
            if let error = root["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Unknown error"
                return .failure(message)
            }
            guard let choices = root["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                return .failure("The model returned no reply.")
            }
            return .reply(text)
            
        case .anthropic:
            if let error = root["error"] as? [String: Any] {
                let message = (error["message"] as? String) ?? "Unknown error"
                return .failure(message)
            }
            guard let content = root["content"] as? [[String: Any]],
                  let first = content.first(where: { $0["type"] as? String == "text" }),
                  let text = first["text"] as? String else {
                return .failure("The model returned no reply.")
            }
            return .reply(text)
        }
    }
}
