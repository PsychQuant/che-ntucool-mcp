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
public enum CanvasAuthError: Error, LocalizedError, Equatable {
    case itemNotFound
    /// Reading would need a keychain dialog and the caller asked for none
    /// (no human at a terminal). Treated like "no token" by the ladder.
    case uiRequired
    case keychainError(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .itemNotFound:
            return "NTU COOL access token missing from keychain. Run: security add-generic-password -s \(CanvasAuth.defaultService) -a default -w   (omit the value; security will prompt)"
        case .uiRequired:
            return "Reading the NTU COOL token needs a keychain permission dialog, and no one is at a terminal to answer it"
        case .keychainError(let status):
            return "Keychain error (OSStatus \(status))"
        }
    }
}

public enum CanvasAuth {
    /// Keychain service name. Mirrors the naming convention documented in
    /// CLAUDE.md's SSH/credential tables (`<system>-<purpose>` service handles).
    public static let defaultService = "ntu-cool-canvas"

    /// - Parameter allowUI: false makes the read fail with `.uiRequired`
    ///   instead of showing an "allow access" dialog. An unsigned or rebuilt
    ///   binary gets that dialog on every new signature, and from a headless
    ///   caller (an agent's Bash tool) it blocks forever — found in the live
    ///   acceptance run of #1.
    public static func read(service: String = defaultService, account: String, allowUI: Bool = true) throws -> String {
        var item: CFTypeRef?
        // kSecUseAuthenticationUIFail alone does not stop the file-keychain
        // "allow access" dialog (verified live: still hung). The legacy switch
        // does; it is process-global, so restore it right after the one read.
        var previous: DarwinBoolean = true
        if !allowUI {
            SecKeychainGetUserInteractionAllowed(&previous)
            SecKeychainSetUserInteractionAllowed(false)
        }
        defer { if !allowUI { SecKeychainSetUserInteractionAllowed(previous.boolValue) } }
        let status = SecItemCopyMatching(query(service: service, account: account, allowUI: allowUI) as CFDictionary, &item)
        guard status == errSecSuccess else { throw classify(status) }
        guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
            throw CanvasAuthError.itemNotFound
        }
        return value
    }

    static func query(service: String, account: String, allowUI: Bool) -> [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        if !allowUI { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        return q
    }

    static func classify(_ status: OSStatus) -> CanvasAuthError {
        switch status {
        case errSecItemNotFound: return .itemNotFound
        case errSecInteractionNotAllowed, errSecAuthFailed: return .uiRequired
        default: return .keychainError(status)
        }
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
