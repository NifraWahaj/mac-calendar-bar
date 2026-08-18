import Foundation
import Security

struct StoredTokens: Codable {
    var refreshToken: String
    var accessToken: String?
    var expiresAt: Date?
    var email: String?
    var scope: String?

    var isAccessTokenValid: Bool {
        guard accessToken != nil, let expiresAt else { return false }
        // Treat tokens expiring in the next 60s as already expired.
        return expiresAt.timeIntervalSinceNow > 60
    }
}

/// Persists the OAuth token set in the macOS Keychain as a single generic-password item.
enum KeychainStore {
    private static let service = "com.calendarbar.app.google-oauth"
    private static let account = "default"

    enum KeychainError: LocalizedError {
        case status(OSStatus)

        var errorDescription: String? {
            switch self {
            case .status(let code):
                let message = SecCopyErrorMessageString(code, nil) as String? ?? "unknown error"
                return "Keychain error \(code): \(message)"
            }
        }
    }

    static func save(_ tokens: StoredTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]

        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus != errSecItemNotFound { throw KeychainError.status(updateStatus) }

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        if addStatus != errSecSuccess { throw KeychainError.status(addStatus) }
    }

    static func load() -> StoredTokens? {
        load().tokens
    }

    /// Also reports the `OSStatus`, so a denied read (which happens when the app's code
    /// signature changes) can be told apart from "no tokens stored yet". Without this a
    /// rebuild looks identical to being signed out.
    static func load() -> (tokens: StoredTokens?, status: OSStatus) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            return (nil, status)
        }
        return (try? JSONDecoder().decode(StoredTokens.self, from: data), status)
    }

    /// Human-readable explanation for a non-success status, or nil when there is simply
    /// nothing stored.
    static func explain(_ status: OSStatus) -> String? {
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return nil
        case errSecInteractionNotAllowed:
            return "The Keychain could not be unlocked without user interaction. Launch Calendar Bar normally (not from a script) and allow access."
        case errSecAuthFailed, errSecUserCanceled:
            return "Keychain access was denied, so the saved Google tokens could not be read. Sign in again, and choose \"Always Allow\" if macOS asks."
        default:
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "unknown error"
            return "Could not read the saved Google tokens (Keychain error \(status): \(message)). Sign in again."
        }
    }

    static func clear() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}
