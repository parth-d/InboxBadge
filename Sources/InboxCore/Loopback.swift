import Foundation
import Network

public final class LoopbackListener: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "io.github.parth-d.InboxBadge.loopback")
    private let lock = NSLock()
    private var waiter: CheckedContinuation<[String: String], Error>?
    private var outcome: Result<[String: String], Error>?

    public init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters, on: .any)
    }

    public static func parseCallback(requestLine: String) -> [String: String]? {
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2, parts[0] == "GET",
              let items = URLComponents(string: "http://127.0.0.1" + parts[1])?.queryItems,
              items.contains(where: { $0.name == "state" || $0.name == "error" })
        else { return nil }
        return Dictionary(items.map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { a, _ in a })
    }

    public func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            let once = OneShot(continuation)
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready:
                    if let port = listener.port?.rawValue { once.resume(.success(port)) }
                case .failed(let error):
                    once.resume(.failure(error))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
            listener.start(queue: queue)
        }
    }

    public func awaitCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let outcome { lock.unlock(); continuation.resume(with: outcome); return }
            waiter = continuation
            lock.unlock()
        }
    }

    public func cancel() {
        listener.cancel()
        _ = deliver(.failure(InboxError.cancelled))
    }

    private func deliver(_ result: Result<[String: String], Error>) -> Bool {
        lock.lock()
        if outcome != nil { lock.unlock(); return false }
        outcome = result
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.resume(with: result)
        return true
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, _, _ in
            func reply(_ status: String, _ body: String) {
                let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in connection.cancel() })
            }
            guard let self, let data, let text = String(data: data, encoding: .utf8),
                  let line = text.components(separatedBy: "\r\n").first,
                  let params = Self.parseCallback(requestLine: line)
            else { reply("404 Not Found", "not found"); return }
            if self.deliver(.success(params)) {
                reply("200 OK", "<html><body>InboxBadge: done. You can close this tab.</body></html>")
            } else {
                reply("409 Conflict", "already handled")
            }
        }
    }
}

final class OneShot<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    init(_ continuation: CheckedContinuation<T, Error>) { self.continuation = continuation }

    func resume(_ result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

public enum SignIn {
    public static func run(client: OAuthClient, loginHint: String? = nil, transport: HTTPTransport,
                           timeout: TimeInterval = 300,
                           openURL: @escaping @Sendable (URL) -> Void) async throws -> StoredAccount {
        let listener = try LoopbackListener()
        let port = try await listener.start()
        defer { listener.cancel() }
        let redirect = "http://127.0.0.1:\(port)"
        let verifier = PKCE.randomToken(bytes: 48)
        let state = PKCE.randomToken(bytes: 16)
        openURL(OAuth.authorizationURL(client: client, redirectURI: redirect,
                                       challenge: PKCE.challenge(for: verifier), state: state, loginHint: loginHint))
        let timer = Task {
            try await Task.sleep(for: .seconds(timeout))
            listener.cancel()
        }
        defer { timer.cancel() }
        let params = try await listener.awaitCallback()
        if let error = params["error"] { throw InboxError.authorization(error) }
        guard params["state"] == state, let code = params["code"] else { throw InboxError.malformed("callback") }
        let grant = try await OAuth.exchange(code: code, verifier: verifier, redirectURI: redirect,
                                             client: client, transport: transport)
        guard let refresh = grant.refreshToken else { throw InboxError.malformed("no refresh token") }
        let tokens = TokenProvider(client: client, refreshToken: refresh, transport: transport, initial: grant)
        let profile = try await GmailClient(tokens: tokens, transport: transport).profile()
        return StoredAccount(email: profile.email, client: client, refreshToken: refresh)
    }
}
