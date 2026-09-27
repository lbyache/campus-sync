import Foundation
import Security

/// Token del campus en el Llavero de macOS (contraseña genérica, servicio `campus-sync`,
/// cuenta = host del campus). Nunca se escribe en disco ni en la configuración.
public enum Keychain {
    static let service = "campus-sync"

    public static func saveToken(_ token: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: Data(token.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrLabel as String: "campus-sync (\(account))",
        ]

        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CampusSyncError.keychain(status) }
    }

    public static func readToken(account: String) throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { throw CampusSyncError.notLoggedIn }
        guard status == errSecSuccess,
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8), !token.isEmpty
        else {
            throw CampusSyncError.keychain(status)
        }
        return token
    }

    public static func deleteToken(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CampusSyncError.keychain(status)
        }
    }
}
