import Foundation
import Security
import InboxCore

struct KeychainStore: SecretStore {
    let service: String

    private func base(_ email: String? = nil) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let email { q[kSecAttrAccount as String] = email }
        return q
    }

    func loadAll() throws -> [StoredAccount] {
        var q = base()
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: AnyObject?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else { throw KeychainError.status(status) }
        return items.compactMap { try? JSONDecoder().decode(StoredAccount.self, from: $0) }
    }

    func save(_ account: StoredAccount) throws {
        let data = try JSONEncoder().encode(account)
        let update = SecItemUpdate(base(account.email) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = base(account.email)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    func delete(email: String) throws {
        let status = SecItemDelete(base(email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

enum KeychainError: Error { case status(OSStatus) }
