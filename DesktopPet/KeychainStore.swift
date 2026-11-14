import Foundation
import Security

enum KeychainStore {
    enum Account: String {
        case deepSeek = "deepseek.apiKey"
        case doubao = "doubao.voice.apiKey"

        var serviceName: String {
            switch self {
            case .deepSeek: "DeepSeek"
            case .doubao: "豆包语音"
            }
        }
    }

    struct KeychainError: LocalizedError {
        let status: OSStatus

        var errorDescription: String? {
            "钥匙串操作失败（\(status)）。"
        }
    }

    private static func keyQuery(account: Account) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Bundle.main.bundleIdentifier ?? "com.haozi.desktoppet",
            kSecAttrAccount as String: account.rawValue
        ]
    }

    static func readAPIKey(account: Account) throws -> String? {
        var query = keyQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError(status: errSecDecode)
        }
        return key
    }

    static func saveAPIKey(_ key: String, account: Account) throws {
        let query = keyQuery(account: account)
        let value = Data(key.utf8)
        let attributes = [kSecValueData as String: value]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = value
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let addStatus = SecItemAdd(item as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    static func removeAPIKey(account: Account) throws {
        let status = SecItemDelete(keyQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }
}
