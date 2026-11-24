import AppKit
import Observation
import os
import InboxCore

let log = Logger(subsystem: "io.github.parth-d.InboxBadge", category: "app")

enum AccountStatus: Equatable {
    case starting
    case ok
    case reauthRequired
    case error(String)
}

struct AccountView: Identifiable, Equatable {
    let email: String
    var unread = 0
    var threads: [UnreadThread] = []
    var status: AccountStatus = .starting
    var id: String { email }
}

@MainActor
@Observable
final class AppModel {
    private(set) var accounts: [AccountView] = []
    private(set) var isSigningIn = false
    var signInError: String?
    var showImporter = false

    var totalUnread: Int { accounts.reduce(0) { $0 + $1.unread } }

    @ObservationIgnored private let store: SecretStore = KeychainStore(service: Bundle.main.bundleIdentifier ?? "io.github.parth-d.InboxBadge")
    @ObservationIgnored private let transport: HTTPTransport = URLSession(configuration: .ephemeral)
    @ObservationIgnored private let environment = SystemEnvironment()
    @ObservationIgnored private var runtimes: [String: Runtime] = [:]
    @ObservationIgnored private var storedClient: OAuthClient?

    struct Runtime {
        let poller: AccountPoller
        let loop: PollLoop
    }

    init() {
        environment.onWake = { [weak self] in
            Task { @MainActor in await self?.pokeAll() }
        }
        do {
            for account in try store.loadAll() { startRuntime(for: account) }
        } catch {
            log.error("keychain load failed: \(String(describing: error), privacy: .public)")
        }
    }

    var hasClient: Bool { storedClient != nil }

    func addAccount(clientJSON: Data?) async {
        isSigningIn = true
        signInError = nil
        defer { isSigningIn = false }
        do {
            let client: OAuthClient
            if let clientJSON { client = try OAuthClient.fromGoogleJSON(clientJSON) }
            else if let storedClient { client = storedClient }
            else { throw InboxError.malformed("client json") }
            let account = try await SignIn.run(client: client, transport: transport) { url in
                Task { @MainActor in NSWorkspace.shared.open(url) }
            }
            try store.save(account)
            if let old = runtimes[account.email] { await old.loop.stop() }
            startRuntime(for: account)
        } catch {
            signInError = Self.describe(error)
            log.error("sign-in failed: \(Self.describe(error), privacy: .public)")
        }
    }

    func removeAccount(_ email: String) async {
        if let runtime = runtimes.removeValue(forKey: email) { await runtime.loop.stop() }
        accounts.removeAll { $0.email == email }
        try? store.delete(email: email)
        if accounts.isEmpty { storedClient = nil }
    }

    func checkNow() async {
        for (email, runtime) in runtimes {
            do {
                if let snapshot = try await runtime.poller.resync() { apply(snapshot, to: email) }
                setStatus(.ok, for: email)
            } catch {
                setStatus(statusFor(error), for: email)
            }
        }
    }

    private func pokeAll() async {
        for runtime in runtimes.values { await runtime.loop.poke() }
    }

    private func startRuntime(for account: StoredAccount) {
        storedClient = account.client
        let tokens = TokenProvider(client: account.client, refreshToken: account.refreshToken, transport: transport)
        let poller = AccountPoller(client: GmailClient(tokens: tokens, transport: transport))
        let email = account.email
        let loop = PollLoop(policy: EnergyPolicy(), environment: environment) { [weak self] in
            do {
                if let snapshot = try await poller.tick() { await self?.apply(snapshot, to: email) }
                await self?.setStatus(.ok, for: email)
            } catch {
                await self?.setStatus(Self.statusFor(error), for: email)
                throw error
            }
        }
        runtimes[email] = Runtime(poller: poller, loop: loop)
        if !accounts.contains(where: { $0.email == email }) { accounts.append(AccountView(email: email)) }
        Task { await loop.start() }
    }

    private func apply(_ snapshot: InboxSnapshot, to email: String) {
        guard let i = accounts.firstIndex(where: { $0.email == email }) else { return }
        accounts[i].unread = snapshot.unreadCount
        accounts[i].threads = snapshot.threads
        log.info("snapshot unread=\(snapshot.unreadCount) listed=\(snapshot.threads.count)")
    }

    private func setStatus(_ status: AccountStatus, for email: String) {
        guard let i = accounts.firstIndex(where: { $0.email == email }), accounts[i].status != status else { return }
        accounts[i].status = status
        log.info("status \(String(describing: status), privacy: .public)")
    }

    private func statusFor(_ error: Error) -> AccountStatus { Self.statusFor(error) }

    nonisolated static func statusFor(_ error: Error) -> AccountStatus {
        if error as? InboxError == .reauthRequired { return .reauthRequired }
        return .error(describe(error))
    }

    nonisolated static func describe(_ error: Error) -> String {
        switch error {
        case InboxError.http(let code): return "Gmail returned HTTP \(code)"
        case InboxError.authorization(let reason): return "Google refused: \(reason)"
        case InboxError.cancelled: return "Sign-in timed out"
        case InboxError.reauthRequired: return "Sign in again"
        case InboxError.malformed(let what): return what == "client json" ? "That is not a Google client JSON" : "Unexpected response (\(what))"
        case is URLError: return "Offline"
        default: return "Something went wrong"
        }
    }
}
