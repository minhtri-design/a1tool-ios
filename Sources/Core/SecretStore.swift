import Foundation
import Security

/// Lưu tài khoản đăng nhập: ưu tiên Keychain; nếu máy không cho (app không ký) thì dùng UserDefaults.
enum SecretStore {
    private static let service = "com.a1tool.app"

    static func get(_ key: String) -> String {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8) {
            return s
        }
        return UserDefaults.standard.string(forKey: "secret_" + key) ?? ""
    }

    static func set(_ value: String, _ key: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        let st = SecItemAdd(add as CFDictionary, nil)
        if st == errSecSuccess {
            UserDefaults.standard.removeObject(forKey: "secret_" + key)
        } else {
            UserDefaults.standard.set(value, forKey: "secret_" + key)
        }
    }
}

struct Credentials {
    var username: String
    var password: String
    var totpSecret: String

    static func load() -> Credentials {
        return Credentials(
            username: SecretStore.get("username"),
            password: SecretStore.get("password"),
            totpSecret: SecretStore.get("totp")
        )
    }

    func save() {
        SecretStore.set(username, "username")
        SecretStore.set(password, "password")
        SecretStore.set(totpSecret, "totp")
    }
}
