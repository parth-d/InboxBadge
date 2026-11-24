import Foundation

public enum HistoryDelta: Equatable, Sendable {
    case unchanged(historyId: String)
    case changed(historyId: String)
    case expired
}

public struct GmailClient: Sendable {
    private let tokens: TokenProvider
    private let transport: HTTPTransport
    private let base: String

    public init(tokens: TokenProvider, transport: HTTPTransport,
                base: String = "https://gmail.googleapis.com/gmail/v1/users/me") {
        self.tokens = tokens
        self.transport = transport
        self.base = base
    }

    private func get(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        for attempt in 0..<2 {
            var url = base + "/" + path
            if !query.isEmpty { url += "?" + FormEncoding.encode(query) }
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, status) = try await transport.send(request)
            if status == 401 {
                if attempt == 0 { await tokens.invalidate(); continue }
                throw InboxError.reauthRequired
            }
            if status == 404 { throw InboxError.notFound }
            guard status == 200 else { throw InboxError.http(status) }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw InboxError.malformed(path)
            }
            return object
        }
        throw InboxError.reauthRequired
    }

    public func profile() async throws -> (email: String, historyId: String) {
        let o = try await get("profile")
        guard let email = o["emailAddress"] as? String, let history = o["historyId"] as? String else {
            throw InboxError.malformed("profile")
        }
        return (email, history)
    }

    public func inboxUnreadCount() async throws -> Int {
        let o = try await get("labels/INBOX")
        guard let n = o["threadsUnread"] as? Int else { throw InboxError.malformed("labels") }
        return n
    }

    public func history(since startHistoryId: String) async throws -> HistoryDelta {
        let query: [(String, String)] = [
            ("startHistoryId", startHistoryId), ("labelId", "INBOX"), ("maxResults", "1"),
            ("historyTypes", "messageAdded"), ("historyTypes", "messageDeleted"),
            ("historyTypes", "labelAdded"), ("historyTypes", "labelRemoved"),
        ]
        let o: [String: Any]
        do { o = try await get("history", query) } catch InboxError.notFound { return .expired }
        let latest = (o["historyId"] as? String) ?? startHistoryId
        let records = o["history"] as? [Any] ?? []
        return records.isEmpty ? .unchanged(historyId: latest) : .changed(historyId: latest)
    }

    public func unreadRefs(limit: Int) async throws -> [MessageRef] {
        let o = try await get("messages", [
            ("labelIds", "INBOX"), ("labelIds", "UNREAD"), ("maxResults", String(max(limit * 3, 50))),
        ])
        var seen = Set<String>()
        var refs: [MessageRef] = []
        for m in o["messages"] as? [[String: Any]] ?? [] {
            guard let id = m["id"] as? String, let thread = m["threadId"] as? String else { continue }
            if seen.insert(thread).inserted { refs.append(MessageRef(id: id, threadId: thread)) }
            if refs.count == limit { break }
        }
        return refs
    }

    public func metadata(of ref: MessageRef) async throws -> UnreadThread {
        let o = try await get("messages/\(ref.id)", [
            ("format", "metadata"), ("metadataHeaders", "From"),
            ("metadataHeaders", "Subject"), ("metadataHeaders", "Message-ID"),
        ])
        let headers = (o["payload"] as? [String: Any])?["headers"] as? [[String: Any]] ?? []
        func header(_ name: String) -> String {
            headers.first { ($0["name"] as? String)?.lowercased() == name.lowercased() }?["value"] as? String ?? ""
        }
        let date = (o["internalDate"] as? String).flatMap(Double.init).map { Date(timeIntervalSince1970: $0 / 1000) }
        let subject = header("Subject")
        return UnreadThread(id: ref.threadId, messageID: ref.id, from: header("From"),
                            subject: subject.isEmpty ? "(no subject)" : subject, date: date)
    }
}
