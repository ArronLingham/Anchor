/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation
import Security

/// The API keys, in the Keychain.
enum AIAssistantCredential {
    private static let service = "com.arronlingham.Anchor.ai"

    static func read(provider: AIProvider) -> [String] {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let keyString = String(data: data, encoding: .utf8),
              !keyString.isEmpty
        else { return [] }
        return keyString.components(separatedBy: "\n").filter { !$0.isEmpty }
    }

    @discardableResult
    static func write(_ keys: [String], provider: AIProvider) -> Bool {
        let filtered = keys.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !filtered.isEmpty else { return delete(provider: provider) }
        let joined = filtered.joined(separator: "\n")
        guard let data = joined.data(using: .utf8) else { return false }

        var attributes = baseQuery(provider: provider)
        attributes[kSecValueData as String] = data
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let added = SecItemAdd(attributes as CFDictionary, nil)
        if added == errSecSuccess { return true }
        guard added == errSecDuplicateItem else { return false }

        return SecItemUpdate(
            baseQuery(provider: provider) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary) == errSecSuccess
    }

    @discardableResult
    static func delete(provider: AIProvider) -> Bool {
        let status = SecItemDelete(baseQuery(provider: provider) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    private static func baseQuery(provider: AIProvider) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "apiKeys_\(provider.rawValue)",
        ]
    }
}
