import Foundation

public struct OAuthClient: Codable, Equatable, Sendable {
    public var clientID: String
    public var clientSecret: String

    public init(clientID: String, clientSecret: String) {
        self.clientID = clientID
        self.clientSecret = clientSecret
    }

    public static func fromGoogleJSON(_ data: Data) throws -> OAuthClient {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let body = (root["installed"] ?? root["web"]) as? [String: Any],
              let id = body["client_id"] as? String, !id.isEmpty,
              let secret = body["client_secret"] as? String, !secret.isEmpty
        else { throw InboxError.malformed("client json") }
        return OAuthClient(clientID: id, clientSecret: secret)
    }
}

public struct StoredAccount: Codable, Equatable, Sendable {
    public var email: String
    public var client: OAuthClient
    public var refreshToken: String

    public init(email: String, client: OAuthClient, refreshToken: String) {
        self.email = email
        self.client = client
        self.refreshToken = refreshToken
    }
}

public struct MessageRef: Equatable, Sendable {
    public let id: String
    public let threadId: String

    public init(id: String, threadId: String) {
        self.id = id
        self.threadId = threadId
    }
}

public struct UnreadThread: Equatable, Sendable, Identifiable {
    public let id: String
    public let messageID: String
    public let from: String
    public let subject: String
    public let date: Date?

    public init(id: String, messageID: String, from: String, subject: String, date: Date?) {
        self.id = id
        self.messageID = messageID
        self.from = from
        self.subject = subject
        self.date = date
    }
}

public struct InboxSnapshot: Equatable, Sendable {
    public var unreadCount: Int
    public var threads: [UnreadThread]

    public init(unreadCount: Int, threads: [UnreadThread]) {
        self.unreadCount = unreadCount
        self.threads = threads
    }
}

public enum InboxError: Error, Equatable {
    case reauthRequired
    case notFound
    case cancelled
    case http(Int)
    case malformed(String)
    case authorization(String)
}

public protocol SecretStore: Sendable {
    func loadAll() throws -> [StoredAccount]
    func save(_ account: StoredAccount) throws
    func delete(email: String) throws
}

public enum SenderName {
    public static func display(_ from: String) -> String {
        let s = from.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "Unknown sender" }
        if let lt = s.lastIndex(of: "<"), s[lt...].contains(">") {
            let quotes = CharacterSet.whitespaces.union(CharacterSet(charactersIn: "\""))
            let name = s[..<lt].trimmingCharacters(in: quotes)
            if !name.isEmpty { return name }
            return String(s[s.index(after: lt)...].prefix { $0 != ">" })
        }
        return s
    }
}

public enum GmailLinks {
    public static func thread(email: String, threadId: String) -> URL {
        URL(string: "https://mail.google.com/mail/?authuser=\(FormEncoding.escape(email))#inbox/\(threadId)")!
    }

    public static func inbox(email: String) -> URL {
        URL(string: "https://mail.google.com/mail/?authuser=\(FormEncoding.escape(email))#inbox")!
    }
}
