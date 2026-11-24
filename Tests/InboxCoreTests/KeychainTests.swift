import Foundation
import Testing
@testable import InboxCore

final class TempKeychain: @unchecked Sendable {
    let keychain: SecKeychain
    private let path: String

    init() throws {
        path = NSTemporaryDirectory() + "inboxbadge-test-\(UUID().uuidString).keychain-db"
        var created: SecKeychain?
        let password = "test"
        let status = SecKeychainCreate(path, UInt32(password.utf8.count), password, false, nil, &created)
        guard status == errSecSuccess, let created else { throw KeychainError.status(status) }
        keychain = created
    }

    deinit {
        SecKeychainDelete(keychain)
        try? FileManager.default.removeItem(atPath: path)
    }

    func store(service: String = "inboxbadge.test.\(UUID().uuidString)") -> KeychainStore {
        KeychainStore(service: service, keychain: keychain)
    }
}

struct KeychainTests {
    private func account(_ email: String, refresh: String = "r") -> StoredAccount {
        StoredAccount(email: email, client: OAuthClient(clientID: "cid", clientSecret: "sec"), refreshToken: refresh)
    }

    @Test func emptyStoreLoadsNothing() throws {
        let kc = try TempKeychain()
        #expect(try kc.store().loadAll().isEmpty)
    }

    @Test func savedAccountsRoundTripAndSurviveANewStoreInstance() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        try store.save(account("a@x.com"))
        try store.save(account("b@x.com", refresh: "r2"))
        let loaded = try kc.store(service: store.service).loadAll()
        #expect(Set(loaded.map(\.email)) == ["a@x.com", "b@x.com"])
        #expect(loaded.first { $0.email == "b@x.com" }?.refreshToken == "r2")
        #expect(loaded.first { $0.email == "a@x.com" }?.client == OAuthClient(clientID: "cid", clientSecret: "sec"))
    }

    @Test func savingTheSameEmailReplacesTheEntry() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        try store.save(account("a@x.com", refresh: "old"))
        try store.save(account("a@x.com", refresh: "new"))
        let loaded = try store.loadAll()
        #expect(loaded.count == 1)
        #expect(loaded[0].refreshToken == "new")
    }

    @Test func deleteRemovesOnlyThatAccountAndIsIdempotent() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        try store.save(account("a@x.com"))
        try store.save(account("b@x.com"))
        try store.delete(email: "a@x.com")
        try store.delete(email: "a@x.com")
        #expect(try store.loadAll().map(\.email) == ["b@x.com"])
    }

    @Test func storesWithDifferentServicesAreIsolated() throws {
        let kc = try TempKeychain()
        let one = kc.store(), two = kc.store()
        try one.save(account("a@x.com"))
        #expect(try two.loadAll().isEmpty)
    }

    @Test func everyAccountLivesInOneKeychainItem() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        for email in ["a@x.com", "b@x.com", "c@x.com"] { try store.save(account(email)) }
        #expect(try store.itemAccounts() == ["accounts"])
        #expect(try store.loadAll().count == 3)
    }

    @Test func legacyPerAccountItemsMigrateIntoTheSingleItem() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        try store.addLegacyItem(account("a@x.com", refresh: "ra"))
        try store.addLegacyItem(account("b@x.com", refresh: "rb"))
        #expect(try store.itemAccounts() == ["a@x.com", "b@x.com"])
        let loaded = try store.loadAll()
        #expect(Set(loaded.map(\.email)) == ["a@x.com", "b@x.com"])
        #expect(try store.itemAccounts() == ["accounts"])
        let again = try store.loadAll()
        #expect(Set(again.map(\.refreshToken)) == ["ra", "rb"])
    }

    @Test func removingTheLastAccountRemovesTheItem() throws {
        let kc = try TempKeychain()
        let store = kc.store()
        try store.save(account("a@x.com"))
        try store.delete(email: "a@x.com")
        #expect(try store.itemAccounts().isEmpty)
    }
}
