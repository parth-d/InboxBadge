import Foundation

public enum HistoryDelta: Equatable, Sendable {
    case unchanged(historyId: String)
    case changed(historyId: String, added: [MessageRef])
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

    private func call(_ method: String, _ path: String, query: [(String, String)] = [],
                      body: [String: Any]? = nil) async throws -> [String: Any] {
        for attempt in 0..<2 {
            var url = base + "/" + path
            if !query.isEmpty { url += "?" + FormEncoding.encode(query) }
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = method
            if let body {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONSerialization.data(withJSONObject: body)
            }
            request.setValue("Bearer \(try await tokens.accessToken())", forHTTPHeaderField: "Authorization")
            let (data, status) = try await transport.send(request)
            if status == 401 {
                if attempt == 0 { await tokens.invalidate(); continue }
                throw InboxError.reauthRequired
            }
            if status == 404 { throw InboxError.notFound }
            guard status == 200 || status == 204 else { throw InboxError.http(status) }
            if data.isEmpty { return [:] }
            guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
                throw InboxError.malformed(path)
            }
            return object
        }
        throw InboxError.reauthRequired
    }

    private func get(_ path: String, _ query: [(String, String)] = []) async throws -> [String: Any] {
        try await call("GET", path, query: query)
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
        var latest = startHistoryId
        var any = false
        var added: [MessageRef] = []
        var seen = Set<String>()
        var pageToken: String?
        for _ in 0..<10 {
            var query: [(String, String)] = [
                ("startHistoryId", startHistoryId), ("labelId", "INBOX"),
                ("historyTypes", "messageAdded"), ("historyTypes", "messageDeleted"),
                ("historyTypes", "labelAdded"), ("historyTypes", "labelRemoved"),
            ]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let o: [String: Any]
            do { o = try await get("history", query) } catch InboxError.notFound { return .expired }
            latest = (o["historyId"] as? String) ?? latest
            let records = o["history"] as? [[String: Any]] ?? []
            if !records.isEmpty { any = true }
            for record in records {
                for entry in record["messagesAdded"] as? [[String: Any]] ?? [] {
                    guard let m = entry["message"] as? [String: Any], let id = m["id"] as? String,
                          let thread = m["threadId"] as? String, seen.insert(id).inserted else { continue }
                    added.append(MessageRef(id: id, threadId: thread))
                }
            }
            pageToken = o["nextPageToken"] as? String
            if pageToken == nil { break }
        }
        return any ? .changed(historyId: latest, added: added) : .unchanged(historyId: latest)
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

    public func metadata(of ref: MessageRef) async throws -> MessageMeta {
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
        let thread = UnreadThread(id: ref.threadId, messageID: ref.id, from: header("From"),
                                  subject: subject.isEmpty ? "(no subject)" : subject, date: date)
        return MessageMeta(thread: thread, labelIds: Set(o["labelIds"] as? [String] ?? []))
    }

    public func markRead(threadId: String) async throws {
        _ = try await call("POST", "threads/\(threadId)/modify", body: ["removeLabelIds": ["UNREAD"]])
    }

    public func trash(threadId: String) async throws {
        _ = try await call("POST", "threads/\(threadId)/trash")
    }

    @discardableResult
    public func markAllRead() async throws -> Int {
        var ids: [String] = []
        var pageToken: String?
        for _ in 0..<200 {
            var query: [(String, String)] = [("labelIds", "INBOX"), ("labelIds", "UNREAD"), ("maxResults", "500")]
            if let pageToken { query.append(("pageToken", pageToken)) }
            let o = try await get("messages", query)
            ids += (o["messages"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            pageToken = o["nextPageToken"] as? String
            if pageToken == nil { break }
        }
        var index = 0
        while index < ids.count {
            let chunk = Array(ids[index..<min(index + 1000, ids.count)])
            _ = try await call("POST", "messages/batchModify", body: ["ids": chunk, "removeLabelIds": ["UNREAD"]])
            index += 1000
        }
        return ids.count
    }
}
