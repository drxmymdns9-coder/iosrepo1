#if canImport(UIKit)
import AnililiCore
import Foundation
import Security

/// Account tokens in the Keychain (Android keeps them in `SecureTokenStore`). An unsigned
/// simulator build can lack the Keychain entitlement (errSecMissingEntitlement); there the token
/// falls back to UserDefaults, with a warning, so sign-in can still be tested.
enum Keychain {
    private static let service = "com.anilili.ios.account"
    private static let fallbackPrefix = "keychain_fallback."

    static func string(_ key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return String(data: data, encoding: .utf8) }
        if status != errSecItemNotFound { Log.warning("account", "Keychain read \(key): OSStatus \(status)") }
        return UserDefaults.standard.string(forKey: fallbackPrefix + key)
    }

    static func set(_ value: String?, for key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        UserDefaults.standard.removeObject(forKey: fallbackPrefix + key)
        guard let value else { return }
        var item = base
        item[kSecValueData as String] = Data(value.utf8)
        item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(item as CFDictionary, nil)
        if status != errSecSuccess {
            Log.warning("account", "Keychain write \(key): OSStatus \(status); keeping it in app storage instead")
            UserDefaults.standard.set(value, forKey: fallbackPrefix + key)
        }
    }
}
#endif
