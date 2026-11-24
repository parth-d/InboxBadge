import Foundation
@testable import InboxCore

final class StubTransport: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var log: [URLRequest] = []
    private let handler: @Sendable (URLRequest) -> (Data, Int)

    init(_ handler: @escaping @Sendable (URLRequest) -> (Data, Int)) { self.handler = handler }

    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return log }

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { log.append(request) }
        return handler(request)
    }

    func count(pathSuffix: String) -> Int { requests.filter { $0.url!.path.hasSuffix(pathSuffix) }.count }
    func bodies(host: String) -> [String] {
        requests.filter { $0.url!.host == host }.map { String(decoding: $0.httpBody ?? Data(), as: UTF8.self) }
    }
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    init(_ start: Date = Date(timeIntervalSince1970: 1_700_000_000)) { current = start }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current.addTimeInterval(seconds); lock.unlock() }
}

func jsonData(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }

let testClient = OAuthClient(clientID: "cid", clientSecret: "csecret")
let gmailBase = "https://gmail.test/v1/users/me"

func makeGmail(_ transport: StubTransport, token: String = "tok") -> GmailClient {
    let tokens = TokenProvider(client: testClient, refreshToken: "refresh", transport: transport,
                               initial: TokenGrant(accessToken: token, refreshToken: nil, expiresIn: 3600))
    return GmailClient(tokens: tokens, transport: transport, base: gmailBase)
}

final class FakeMailbox: @unchecked Sendable {
    struct Msg { var id: String; var thread: String; var from: String; var subject: String }
    private let lock = NSLock()
    var messages: [Msg] = []
    var historyChanged = false
    var historyStatus = 200
    var failMetadata: Set<String> = []
    var historyId = 100

    func handle(_ request: URLRequest) -> (Data, Int) {
        lock.lock(); defer { lock.unlock() }
        let path = request.url!.path
        if path.hasSuffix("/profile") {
            return (jsonData(["emailAddress": "me@x.com", "historyId": "\(historyId)"]), 200)
        }
        if path.hasSuffix("/labels/INBOX") {
            return (jsonData(["threadsUnread": Set(messages.map(\.thread)).count]), 200)
        }
        if path.hasSuffix("/history") {
            if historyStatus != 200 { return (Data(), historyStatus) }
            var object: [String: Any] = ["historyId": "\(historyId)"]
            if historyChanged { object["history"] = [["id": "1"]] }
            return (jsonData(object), 200)
        }
        if path.hasSuffix("/messages") {
            let list = messages.map { ["id": $0.id, "threadId": $0.thread] }
            return (jsonData(list.isEmpty ? [:] : ["messages": list]), 200)
        }
        if path.contains("/messages/") {
            let id = String(path.split(separator: "/").last!)
            guard !failMetadata.contains(id), let m = messages.first(where: { $0.id == id }) else { return (Data(), 404) }
            return (jsonData([
                "id": m.id, "threadId": m.thread, "internalDate": "1700000000000",
                "payload": ["headers": [["name": "From", "value": m.from], ["name": "subject", "value": m.subject]]],
            ]), 200)
        }
        return (Data(), 500)
    }
}

func waitUntil(timeout: TimeInterval = 3, _ condition: @Sendable () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

final class Tally: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    private var values: [Double] = []
    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var recorded: [Double] { lock.lock(); defer { lock.unlock() }; return values }
    func hit() { lock.lock(); n += 1; lock.unlock() }
    func record(_ v: Double) { lock.lock(); values.append(v); lock.unlock() }
}

final class FakeEnvironment: PollEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var asleep = false
    private var low = false
    var displaysAsleep: Bool { get { lock.lock(); defer { lock.unlock() }; return asleep } set { lock.lock(); asleep = newValue; lock.unlock() } }
    var lowPower: Bool { get { lock.lock(); defer { lock.unlock() }; return low } set { lock.lock(); low = newValue; lock.unlock() } }
}
