import Foundation
import LocalAuthentication
import Security

// Provider identity is the only dependency of the real Keychain adapter.
enum AIProvider: String, CaseIterable {
    case gemini = "Gemini", openai = "OpenAI", anthropic = "Anthropic"
}

@main
struct AIAssistantCredentialTests {
    static func main() {
        var checks = 0
        func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        for provider in AIProvider.allCases {
            let result = AIAssistantCredential.read(provider: provider) { query, output in
                let fields = query as! [String: Any]
                expect((fields[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == true,
                       "Passive reads must not ask for Keychain authorization")
                expect(fields[kSecAttrAccount as String] as? String == "apiKeys_\(provider.rawValue)",
                       "Provider accounts must stay separate")
                expect(fields[kSecAttrService as String] as? String == "com.arronlingham.Anchor.ai",
                       "Existing saved-key service must be preserved")
                expect(fields[kSecReturnData as String] as? Bool == true, "Read requests data")
                output?.pointee = "fake-key-1\n\nfake-key-2".data(using: .utf8)! as CFData
                return errSecSuccess
            }
            expect(result == ["fake-key-1", "fake-key-2"], "All stored keys must survive decoding")
        }
        let authorized = AIAssistantCredential.read(provider: .gemini, allowAuthentication: true) { query, _ in
            let fields = query as! [String: Any]
            expect((fields[kSecUseAuthenticationContext as String] as? LAContext)?.interactionNotAllowed == false,
                   "Explicit Load Saved Keys may ask for access")
            return errSecUserCanceled
        }
        expect(authorized.isEmpty, "Canceled access must not return keys")
        for status in [errSecInteractionNotAllowed, errSecItemNotFound, errSecAuthFailed] {
            let result = AIAssistantCredential.read(provider: .openai) { _, _ in status }
            expect(result.isEmpty, "Unavailable keys must remain unavailable")
            let details = AIAssistantCredential.readResult(provider: .openai) { _, _ in status }
            expect(details.requiresAuthorization == (status != errSecItemNotFound),
                   "Locked keys must remain distinct from a new empty account")
        }
        let malformed = AIAssistantCredential.read(provider: .anthropic) { _, output in
            output?.pointee = Data([0xff, 0xfe]) as CFData
            return errSecSuccess
        }
        expect(malformed.isEmpty, "Invalid key data must be rejected")
        print("\(checks)/\(checks) credential checks passed; no real Keychain access")
    }
}
