import Foundation
import Security

enum KeychainStore {
    static let service = "dev.barkvisor.console"
    static let tokenAccount = "jwt"
    static let refreshAccount = "refresh"

    static func readToken() -> String? {
        read(account: tokenAccount)
    }

    static func readRefreshToken() -> String? {
        read(account: refreshAccount)
    }

    @discardableResult
    static func saveToken(_ token: String) -> Bool {
        save(account: tokenAccount, value: token)
    }

    @discardableResult
    static func saveRefreshToken(_ token: String) -> Bool {
        save(account: refreshAccount, value: token)
    }

    @discardableResult
    static func saveSession(token: String, refreshToken: String) -> Bool {
        saveToken(token) && saveRefreshToken(refreshToken)
    }

    @discardableResult
    static func deleteToken() -> Bool {
        delete(account: tokenAccount)
    }

    @discardableResult
    static func deleteRefreshToken() -> Bool {
        delete(account: refreshAccount)
    }

    @discardableResult
    static func deleteSession() -> Bool {
        let token = deleteToken()
        let refresh = deleteRefreshToken()
        return token && refresh
    }

    private static func read(account: String) -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    private static func save(account: String, value: String) -> Bool {
        delete(account: account)
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecUseDataProtectionKeychain as String: true,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    @discardableResult
    private static func delete(account: String) -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}

enum JWT {
    static let refreshLeeway: TimeInterval = 5 * 60

    static func secondsRemaining(_ token: String, now: Date = Date()) -> TimeInterval? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 {
            payload.append("=")
        }
        guard let data = Data(base64Encoded: payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        let exp: TimeInterval
        if let value = object["exp"] as? TimeInterval {
            exp = value
        } else if let value = object["exp"] as? Int {
            exp = TimeInterval(value)
        } else {
            return nil
        }
        return exp - now.timeIntervalSince1970
    }

    static func isExpired(_ token: String, now: Date = Date()) -> Bool {
        guard let remaining = secondsRemaining(token, now: now) else { return true }
        return remaining < 0
    }

    static func needsRefresh(_ token: String?, now: Date = Date(), leeway: TimeInterval = refreshLeeway) -> Bool {
        guard let token else { return true }
        guard let remaining = secondsRemaining(token, now: now) else { return true }
        return remaining <= leeway
    }
}
