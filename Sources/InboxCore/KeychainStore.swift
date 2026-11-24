import Foundation
import Security

struct Vault: Codable, Equatable {
    var accounts: [StoredAccount] = []
    var client: OAuthClient?
}

public struct KeychainStore: SecretStore, @unchecked Sendable {
    static let bundleAccount = "accounts"

    public let service: String
    private let keychain: SecKeychain?

    public init(service: String, keychain: SecKeychain? = nil) {
        self.service = service
        self.keychain = keychain
    }

    private func base(_ account: String? = nil) -> [String: Any] {
        var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
        if let keychain { query[kSecMatchSearchList as String] = [keychain] }
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }

    public func loadAll() throws -> [StoredAccount] { try loadVault().accounts }

    public func loadClient() throws -> OAuthClient? {
        let vault = try loadVault()
        return vault.client ?? vault.accounts.first?.client
    }

    public func saveClient(_ client: OAuthClient) throws {
        var vault = try loadVault()
        vault.client = client
        try writeVault(vault)
    }

    public func save(_ account: StoredAccount) throws {
        var vault = try loadVault()
        if let i = vault.accounts.firstIndex(where: { $0.email == account.email }) { vault.accounts[i] = account } else { vault.accounts.append(account) }
        if vault.client == nil { vault.client = account.client }
        try writeVault(vault)
    }

    public func delete(email: String) throws {
        var vault = try loadVault()
        vault.accounts.removeAll { $0.email == email }
        try writeVault(vault)
    }

    private func loadVault() throws -> Vault {
        var vault = try readVault()
        let legacy = try readLegacyItems()
        guard !legacy.isEmpty else { return vault }
        for item in legacy where !vault.accounts.contains(where: { $0.email == item.account.email }) { vault.accounts.append(item.account) }
        try writeVault(vault)
        for item in legacy { try? deleteItem(item.itemAccount) }
        return vault
    }

    func itemAccounts() throws -> [String] {
        var listing = base()
        listing[kSecReturnAttributes as String] = true
        listing[kSecMatchLimit as String] = kSecMatchLimitAll
        var found: AnyObject?
        let status = SecItemCopyMatching(listing as CFDictionary, &found)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let rows = found as? [[String: Any]] else { throw KeychainError.status(status) }
        return rows.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    func addLegacyItem(_ account: StoredAccount) throws {
        try writeItem(account: account.email, data: try JSONEncoder().encode(account))
    }

    func addLegacyBundle(_ accounts: [StoredAccount]) throws {
        try writeItem(account: Self.bundleAccount, data: try JSONEncoder().encode(accounts))
    }

    private func readData(_ itemAccount: String) throws -> Data? {
        var query = base(itemAccount)
        query[kSecReturnData as String] = true
        var data: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &data)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let bytes = data as? Data else { throw KeychainError.status(status) }
        return bytes
    }

    private func readVault() throws -> Vault {
        guard let data = try readData(Self.bundleAccount) else { return Vault() }
        if let vault = try? JSONDecoder().decode(Vault.self, from: data) { return vault }
        return Vault(accounts: (try? JSONDecoder().decode([StoredAccount].self, from: data)) ?? [], client: nil)
    }

    private func readLegacyItems() throws -> [(itemAccount: String, account: StoredAccount)] {
        try itemAccounts().filter { $0 != Self.bundleAccount }.compactMap { itemAccount in
            guard let data = try readData(itemAccount), let account = try? JSONDecoder().decode(StoredAccount.self, from: data)
            else { return nil }
            return (itemAccount, account)
        }
    }

    private func writeVault(_ vault: Vault) throws {
        if vault.accounts.isEmpty && vault.client == nil { try deleteItem(Self.bundleAccount); return }
        try writeItem(account: Self.bundleAccount, data: try JSONEncoder().encode(vault))
    }

    private func writeItem(account: String, data: Data) throws {
        let update = SecItemUpdate(base(account) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw KeychainError.status(update) }
        var add = base(account)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        add[kSecAttrSynchronizable as String] = false
        if let keychain { add[kSecUseKeychain as String] = keychain }
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.status(status) }
    }

    private func deleteItem(_ account: String) throws {
        let status = SecItemDelete(base(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}

public enum KeychainError: Error, Equatable { case status(OSStatus) }
