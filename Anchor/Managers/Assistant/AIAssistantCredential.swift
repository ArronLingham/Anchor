/*
 * Anchor
 * Derived from Atoll (DynamicIsland), itself derived from boring.notch.
 * Copyright (C) 2024-2026 Atoll Contributors
 */

import Foundation
import LocalAuthentication
import Security

/// The API keys, in the Keychain.
enum AIAssistantCredential {
    private static let service = "com.arronlingham.Anchor.ai"
    struct ReadResult: Sendable {
        let keys: [String]
        let requiresAuthorization: Bool
    }

    /// Passive reads must never open a Keychain permission dialog. In
    /// particular, a development build may have a different signing identity.
    /// Interactive access is reserved for the explicit Load Saved Keys action.
    static func read(
        provider: AIProvider,
        allowAuthentication: Bool = false,
        readItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) -> [String] {
        readResult(provider: provider, allowAuthentication: allowAuthentication, readItem: readItem).keys
    }

    static func readResult(
        provider: AIProvider,
        allowAuthentication: Bool = false,
        readItem: (CFDictionary, UnsafeMutablePointer<CFTypeRef?>?) -> OSStatus = SecItemCopyMatching
    ) -> ReadResult {
        var query = baseQuery(provider: provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        let context = LAContext()
        context.interactionNotAllowed = !allowAuthentication
        query[kSecUseAuthenticationContext as String] = context

        var item: CFTypeRef?
        let status = readItem(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            return ReadResult(keys: [], requiresAuthorization: status != errSecItemNotFound)
        }
        guard let data = item as? Data,
              let keyString = String(data: data, encoding: .utf8),
              !keyString.isEmpty
        else { return ReadResult(keys: [], requiresAuthorization: false) }
        return ReadResult(keys: keyString.components(separatedBy: "\n").filter { !$0.isEmpty },
                          requiresAuthorization: false)
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
