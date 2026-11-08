import Foundation
import LocalAuthentication
import Security

/// Passphrases of encrypted sub-chats, in the Keychain behind Face ID (`.biometryCurrentSet`:
/// re-enrolling a face invalidates them, as for a banking app).
public enum PrivateVault {
    static let service = "hermes.subchat.passphrase"

    public static func save(passphrase: String, topic: TopicID) throws {
        delete(topic: topic)
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenPasscodeSetThisDeviceOnly,
                                                           .biometryCurrentSet, &error) else {
            throw error!.takeRetainedValue() as Error
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(topic),
            kSecAttrAccessControl as String: access,
            kSecValueData as String: Data(passphrase.utf8),
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    /// Prompts Face ID through the Keychain item itself.
    public static func passphrase(topic: TopicID, reason: String) async throws -> String? {
        try await Task.detached {
            let context = LAContext()
            context.localizedReason = reason
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: String(topic),
                kSecReturnData as String: true,
                kSecUseAuthenticationContext as String: context,
            ]
            var out: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = out as? Data else {
                throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
            }
            return String(decoding: data, as: UTF8.self)
        }.value
    }

    public static func hasPassphrase(topic: TopicID) -> Bool {
        let context = LAContext()
        context.interactionNotAllowed = true
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(topic),
            kSecUseAuthenticationContext as String: context,
        ]
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        // An item behind biometrics answers "interaction not allowed": it exists.
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    @discardableResult
    public static func delete(topic: TopicID) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: String(topic),
        ]
        return SecItemDelete(query as CFDictionary) == errSecSuccess
    }

    /// Face ID alone, to open a private sub-chat's view.
    public static func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        var error: NSError?
        let policy: LAPolicy = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error)
            ? .deviceOwnerAuthenticationWithBiometrics : .deviceOwnerAuthentication
        return (try? await context.evaluatePolicy(policy, localizedReason: reason)) ?? false
    }

    public static var biometryName: String {
        let context = LAContext()
        _ = context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return L("your passcode")
        }
    }
}
