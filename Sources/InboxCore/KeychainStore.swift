import Foundation
import Security

public struct KeychainStore: SecretStore, @unchecked Sendable {
    public let service: String
    private let keychain: SecKeychain?

    public init(service: String, keychain: SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }

    private func base(_ email: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        if let email { query[kSecAttrAccount as String] = email }
        return query
    }

    public func loadAll() throws -> [StoredAccount] {
        var listing = base()
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: AnyObject?
        let status = SecItemCopyMatching(listing as CFDictionary, &found)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = found as? [[String: Any]] else { throw KeychainError.status(status) }
        return try rows.compactMap { row in
            guard let email = row[kSecAttrAccount as String] as? String else { return nil }
            var one = base(email)
            one[kSecReturnData as String] = true
            var data: AnyObject?
            let result = SecItemCopyMatching(one as CFDictionary, &data)
            if result == errSecItemNotFound { return nil }
            guard result == errSecSuccess, let bytes = data as? Data else { throw KeychainError.status(result) }
            return try? JSONDecoder().decode(StoredAccount.self, from: bytes)
        }
    }

    public func save(_ account: StoredAccount) throws {
        let data = try JSONEncoder().encode(account)
        let update = SecItemUpdate(base(account.email) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = base(account.email)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    public func delete(email: String) throws {
        let status = SecItemDelete(base(email) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

public enum KeychainError: Error, Equatable { case status(OSStatus) }
