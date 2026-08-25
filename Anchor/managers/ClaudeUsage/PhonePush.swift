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
import Foundation
import Security

/// Keychain storage for the ntfy topic.
///
/// The topic name *is* the credential: on a public ntfy server anyone who knows
/// it can both read every message published to it and publish their own. That
/// rules out `Defaults`, which lands in a world-readable plist under
/// `~/Library/Preferences`.
///
/// This deliberately uses the legacy file-based keychain rather than the data
/// protection keychain (`kSecUseDataProtectionKeychain`). The latter needs a
/// keychain-access-group entitlement, which ad-hoc-signed Debug builds do not
/// have, so it would fail with `errSecMissingEntitlement` during iteration.
enum ClaudeUsageKeychain {
    private static let service = "com.arronlingham.Anchor.claudeUsage"
    private static let account = "ntfyTopic"

    /// The configured topic, or nil when phone push has not been set up.
    static func ntfyTopic() -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status != errSecItemNotFound {
                NSLog("PhonePush: keychain read failed (OSStatus \(status))")
            }
            return nil
        }

        guard let data = item as? Data,
              let topic = String(data: data, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines),
              !topic.isEmpty
        else { return nil }

        return topic
    }

    /// Stores the topic, or deletes it when passed nil or an empty string.
    @discardableResult
    static func setNtfyTopic(_ topic: String?) -> Bool {
        let trimmed = topic?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else { return deleteTopic() }

        let data = Data(trimmed.utf8)

        var attributes = baseQuery()
        attributes[kSecValueData as String] = data
        attributes[kSecAttrLabel as String] = "Anchor — Claude usage ntfy topic"

        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else {
            NSLog("PhonePush: keychain write failed (OSStatus \(added))")
            return false
        }

        let updated = SecItemUpdate(
            baseQuery() as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        if updated != errSecSuccess {
            NSLog("PhonePush: keychain update failed (OSStatus \(updated))")
        }
        return updated == errSecSuccess
    }

    private static func deleteTopic() -> Bool {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            NSLog("PhonePush: keychain delete failed (OSStatus \(status))")
            return false
        }
        return true
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

/// Pushes a notification to the user's phone through ntfy.
///
/// The whole point is *scheduled* delivery. A local timer set for the reset
/// instant never fires if the Mac is asleep then, so nothing waits for the
/// reset: the message is POSTed the moment the limit is seen, carrying ntfy's
/// `Delay` header, and the server holds it and delivers it at the reset instant
/// whatever the Mac is doing by then.
///
/// The body crosses a third-party public server, so it stays generic — no
/// transcript text, no prompts, no file or project names. "Your Claude usage
/// window has reset" is the intended level of detail.
///
/// Phone push is opt-in: with no topic configured every call is a no-op.
enum PhonePush {
    /// ntfy refuses a scheduled delivery nearer than this.
    private static let minimumDelay: TimeInterval = 10
    /// ntfy's ceiling on scheduled delivery. A 5-hour window sits well inside it.
    private static let maximumDelay: TimeInterval = 3 * 24 * 60 * 60

    /// Ephemeral so nothing about these requests touches the on-disk cache or
    /// cookie store. The timeout is short — a push that cannot go out promptly
    /// is not worth holding a connection open for.
    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.httpShouldSetCookies = false
        return URLSession(configuration: config)
    }()

    /// The keychain read is an XPC round-trip to securityd, so even request
    /// construction happens off the caller's thread.
    private static let queue = DispatchQueue(label: "com.anchor.phone-push", qos: .utility)

    /// Sends a notification. `deliverAt == nil` sends immediately; otherwise the
    /// message is handed to ntfy now for delivery at `deliverAt`.
    ///
    /// Returns immediately and never blocks the caller. `completion` runs on an
    /// arbitrary background queue — hop to the main queue yourself if you need it.
    /// It reports false for a missing topic, a malformed server or topic, a reset
    /// further out than ntfy will schedule, and any transport or HTTP failure.
    static func send(title: String, body: String, deliverAt: Date?, completion: ((Bool) -> Void)?) {
        queue.async {
            guard let request = makeRequest(title: title, body: body, deliverAt: deliverAt) else {
                completion?(false)
                return
            }

            session.dataTask(with: request) { _, response, error in
                if let error {
                    NSLog("PhonePush: request failed: \(error.localizedDescription)")
                    completion?(false)
                    return
                }

                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard (200...299).contains(status) else {
                    NSLog("PhonePush: server rejected the message (HTTP \(status))")
                    completion?(false)
                    return
                }

                completion?(true)
            }.resume()
        }
    }

    private static func makeRequest(title: String, body: String, deliverAt: Date?) -> URLRequest? {
        // No topic means the feature was never set up. Silent by design.
        guard let topic = ClaudeUsageKeychain.ntfyTopic() else { return nil }
        guard let url = endpoint(topic: topic) else { return nil }

        var delayHeader: String?
        if let deliverAt {
            let delay = deliverAt.timeIntervalSinceNow
            guard delay <= maximumDelay else {
                NSLog("PhonePush: reset is \(Int(delay / 3600))h out, past ntfy's 3-day scheduling limit")
                return nil
            }
            // Anything nearer than the minimum goes out now rather than being
            // rejected: the window is about to reopen anyway, and a refused
            // schedule delivers nothing at all.
            if delay >= minimumDelay {
                delayHeader = String(Int(deliverAt.timeIntervalSince1970))
            }
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(body.utf8)
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")

        let headerTitle = sanitizedHeaderValue(title)
        if !headerTitle.isEmpty {
            request.setValue(headerTitle, forHTTPHeaderField: "Title")
        }
        if let delayHeader {
            request.setValue(delayHeader, forHTTPHeaderField: "Delay")
        }
        return request
    }

    private static func endpoint(topic: String) -> URL? {
        guard !topic.contains("/"),
              topic.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let encoded = topic.addingPercentEncoding(withAllowedCharacters: topicAllowed)
        else {
            NSLog("PhonePush: configured topic is not a usable ntfy topic name")
            return nil
        }

        var base = Defaults[.claudeUsageNtfyServer].trimmingCharacters(in: .whitespacesAndNewlines)
        while base.hasSuffix("/") { base.removeLast() }

        guard let url = URL(string: "\(base)/\(encoded)"),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil
        else {
            NSLog("PhonePush: ntfy server URL is not usable (expected e.g. https://ntfy.sh)")
            return nil
        }
        return url
    }

    /// ASCII only, and a topic must survive this untouched or it is rejected —
    /// `CharacterSet.alphanumerics` would leave non-ASCII letters unescaped and
    /// `URL(string:)` then refuses the result.
    private static let topicAllowed: CharacterSet = {
        var set = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        set.insert(charactersIn: "-_.")
        return set
    }()

    /// HTTP header values are ASCII, and an embedded newline is how header
    /// injection works. Titles here are fixed English strings, so dropping
    /// everything outside printable ASCII costs nothing.
    private static func sanitizedHeaderValue(_ value: String) -> String {
        let printable = value.unicodeScalars.filter { $0.value >= 0x20 && $0.value < 0x7F }
        return String(String.UnicodeScalarView(printable)).trimmingCharacters(in: .whitespaces)
    }
}
