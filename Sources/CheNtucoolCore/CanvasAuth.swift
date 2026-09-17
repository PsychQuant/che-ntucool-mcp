import Foundation
import Security

/// Keychain-backed storage for the NTU COOL (Canvas LMS) Personal Access Token.
///
/// Token is never read from an env var or written to disk — it lives only in the
/// macOS login keychain, following the same generic-password pattern as
/// `Rush/Auth.swift` (service "che-transport-tdx"). Users provision the token once
/// via `security add-generic-password`, and every server process reads it fresh.
///
/// The documented incantation deliberately omits the value after `-w` so
/// `security` prompts for it: `-w <token>` would expose the token in the process
/// argument list for the lifetime of the command.
public enum CanvasAuthError: Error, LocalizedError {
    case itemNotFound
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "NTU COOL access token missing from keychain. Run: security add-generic-password -s \(CanvasAuth.defaultService) -a default -w   (omit the value; security will prompt)"
        case .keychainError(let status):
            return "Keychain error (OSStatus \(status))"
        }
    }
}

public enum CanvasAuth {
    /// Keychain service name. Mirrors the naming convention documented in
    /// CLAUDE.md's SSH/credential tables (`<system>-<purpose>` service handles).
    public static let defaultService = "ntu-cool-canvas"

    public static func read(service: String = defaultService, account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw CanvasAuthError.itemNotFound }
            throw CanvasAuthError.keychainError(status)
        }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CanvasAuthError.itemNotFound
        }
        return value
    }

    public static func save(service: String = defaultService, account: String, value: String) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw CanvasAuthError.keychainError(status) }
    }
}
