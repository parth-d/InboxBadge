import Foundation
import Testing
@testable import InboxCore

struct GmailClientTests {
    @Test func inboxCountReadsLabelAndSendsBearer() async throws {
        let t = StubTransport { _ in (jsonData(["threadsUnread": 3]), 200) }
        #expect(try await makeGmail(t).inboxUnreadCount() == 3)
        let r = t.requests[0]
        #expect(r.url!.path == "/v1/users/me/labels/INBOX")
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func profileReturnsAddressAndHistory() async throws {
        let t = StubTransport { _ in (jsonData(["emailAddress": "a@b.c", "historyId": "77"]), 200) }
        let p = try await makeGmail(t).profile()
        #expect(p.email == "a@b.c")
        #expect(p.historyId == "77")
    }

    @Test func unauthorizedRefreshesOnceThenRetries() async throws {
        let t = StubTransport { r in
            if r.url!.host == "oauth2.googleapis.com" { return (jsonData(["access_token": "new", "expires_in": 3600]), 200) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer tok"
                ? (Data(), 401) : (jsonData(["threadsUnread": 5]), 200)
        }
        #expect(try await makeGmail(t).inboxUnreadCount() == 5)
        let gmail = t.requests.filter { $0.url!.host == "gmail.test" }
        #expect(gmail.count == 2)
        #expect(gmail[1].value(forHTTPHeaderField: "Authorization") == "Bearer new")
    }

    @Test func persistentUnauthorizedMeansReauth() async {
        let t = StubTransport { r in
            r.url!.host == "oauth2.googleapis.com" ? (jsonData(["access_token": "n", "expires_in": 3600]), 200) : (Data(), 401)
        }
        await #expect(throws: InboxError.reauthRequired) { _ = try await makeGmail(t).inboxUnreadCount() }
        #expect(t.requests.filter { $0.url!.host == "gmail.test" }.count == 2)
    }

    @Test func serverErrorSurfacesStatus() async {
        let t = StubTransport { _ in (Data(), 503) }
        await #expect(throws: InboxError.http(503)) { _ = try await makeGmail(t).inboxUnreadCount() }
    }

    @Test func unreadRefsDedupeThreadsKeepOrderAndLimit() async throws {
        let t = StubTransport { _ in
            (jsonData(["messages": [["id": "m1", "threadId": "t1"], ["id": "m2", "threadId": "t1"],
                                    ["id": "m3", "threadId": "t2"], ["id": "m4", "threadId": "t3"]]]), 200)
        }
        let refs = try await makeGmail(t).unreadRefs(limit: 2)
        #expect(refs == [MessageRef(id: "m1", threadId: "t1"), MessageRef(id: "m3", threadId: "t2")])
        let query = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.filter { $0.name == "labelIds" }.compactMap(\.value).sorted() == ["INBOX", "UNREAD"])
    }

    @Test func unreadRefsEmptyWhenNoMessagesKey() async throws {
        let t = StubTransport { _ in (jsonData([String: Any]()), 200) }
        #expect(try await makeGmail(t).unreadRefs(limit: 5).isEmpty)
    }

    @Test func historyUnchangedWhenNoRecords() async throws {
        let t = StubTransport { _ in (jsonData(["historyId": "205"]), 200) }
        #expect(try await makeGmail(t).history(since: "200") == .unchanged(historyId: "205"))
        let query = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "startHistoryId" }?.value == "200")
        #expect(query.first { $0.name == "labelId" }?.value == "INBOX")
        #expect(query.filter { $0.name == "historyTypes" }.count == 4)
    }

    @Test func historyChangedWhenRecordsPresent() async throws {
        let t = StubTransport { _ in (jsonData(["historyId": "206", "history": [["id": "201"]]]), 200) }
        #expect(try await makeGmail(t).history(since: "200") == .changed(historyId: "206", added: []))
    }

    @Test func historyExpiredOn404() async throws {
        let t = StubTransport { _ in (Data(), 404) }
        #expect(try await makeGmail(t).history(since: "1") == .expired)
    }

    @Test func metadataParsesHeadersAndDate() async throws {
        let t = StubTransport { _ in
            (jsonData(["internalDate": "1700000000000",
                       "payload": ["headers": [["name": "FROM", "value": "Jane <j@x.com>"], ["name": "subject", "value": "Hi"]]]]), 200)
        }
        let meta = try await makeGmail(t).metadata(of: MessageRef(id: "m1", threadId: "t1"))
        let thread = meta.thread
        #expect(thread == UnreadThread(id: "t1", messageID: "m1", from: "Jane <j@x.com>", subject: "Hi",
                                       date: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(t.requests[0].url!.path == "/v1/users/me/messages/m1")
    }

    @Test func emptySubjectGetsPlaceholder() async throws {
        let t = StubTransport { _ in (jsonData(["internalDate": "1", "payload": ["headers": []]]), 200) }
        let thread = try await makeGmail(t).metadata(of: MessageRef(id: "m", threadId: "t")).thread
        #expect(thread.subject == "(no subject)")
    }

    @Test func metadataExposesLabels() async throws {
        let t = StubTransport { _ in (jsonData(["internalDate": "1", "labelIds": ["INBOX", "UNREAD"], "payload": ["headers": []]]), 200) }
        let meta = try await makeGmail(t).metadata(of: MessageRef(id: "m", threadId: "t"))
        #expect(meta.labelIds == ["INBOX", "UNREAD"])
        #expect(meta.isUnreadInbox)
        let read = MessageMeta(thread: meta.thread, labelIds: ["INBOX"])
        #expect(!read.isUnreadInbox)
    }

    @Test func historyCollectsAddedMessagesAcrossPagesWithoutDuplicates() async throws {
        let t = StubTransport { r in
            let token = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageToken" }?.value
            if token == nil {
                return (jsonData(["historyId": "300", "nextPageToken": "p2",
                                  "history": [["id": "1", "messagesAdded": [["message": ["id": "a", "threadId": "ta"]]]]]]), 200)
            }
            return (jsonData(["historyId": "300", "history": [
                ["id": "2", "messagesAdded": [["message": ["id": "a", "threadId": "ta"]], ["message": ["id": "b", "threadId": "tb"]]]],
                ["id": "3", "labelsRemoved": [["message": ["id": "c", "threadId": "tc"]]]],
            ]]), 200)
        }
        let delta = try await makeGmail(t).history(since: "1")
        #expect(delta == .changed(historyId: "300", added: [MessageRef(id: "a", threadId: "ta"), MessageRef(id: "b", threadId: "tb")]))
        #expect(t.requests.count == 2)
    }

    @Test func markReadRemovesUnreadLabelFromTheThread() async throws {
        let t = StubTransport { _ in (jsonData(["id": "t1"]), 200) }
        try await makeGmail(t).markRead(threadId: "t1")
        let r = t.requests[0]
        #expect(r.httpMethod == "POST")
        #expect(r.url!.path == "/v1/users/me/threads/t1/modify")
        #expect(r.value(forHTTPHeaderField: "Content-Type") == "application/json")
        let body = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        #expect(body["removeLabelIds"] as? [String] == ["UNREAD"])
        #expect(r.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
    }

    @Test func trashPostsToTheTrashEndpoint() async throws {
        let t = StubTransport { _ in (jsonData(["id": "t1"]), 200) }
        try await makeGmail(t).trash(threadId: "t1")
        #expect(t.requests[0].httpMethod == "POST")
        #expect(t.requests[0].url!.path == "/v1/users/me/threads/t1/trash")
    }

    @Test func actionFailureSurfacesStatus() async {
        let t = StubTransport { _ in (Data(), 403) }
        await #expect(throws: InboxError.http(403)) { try await makeGmail(t).markRead(threadId: "t1") }
        await #expect(throws: InboxError.http(403)) { try await makeGmail(t).trash(threadId: "t1") }
    }

    @Test func actionRetriesOnceAfterUnauthorized() async throws {
        let t = StubTransport { r in
            if r.url!.host == "oauth2.googleapis.com" { return (jsonData(["access_token": "new", "expires_in": 3600]), 200) }
            return r.value(forHTTPHeaderField: "Authorization") == "Bearer tok" ? (Data(), 401) : (jsonData(["id": "t"]), 200)
        }
        try await makeGmail(t).markRead(threadId: "t1")
        #expect(t.requests.filter { $0.url!.host == "gmail.test" }.count == 2)
    }

    @Test func markAllReadPagesThenBatchesInChunksOfAThousand() async throws {
        let t = StubTransport { r in
            if r.url!.path.hasSuffix("/batchModify") { return (Data(), 204) }
            let token = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageToken" }?.value
            let page = Int(token ?? "0")!
            let ids = (page * 500..<(page + 1) * 500).map { ["id": "m\($0)", "threadId": "t\($0)"] }
            var o: [String: Any] = ["messages": ids]
            if page < 4 { o["nextPageToken"] = "\(page + 1)" }
            return (jsonData(o), 200)
        }
        let n = try await makeGmail(t).markAllRead()
        #expect(n == 2500)
        let batches = t.requests.filter { $0.url!.path.hasSuffix("/batchModify") }.map {
            try! JSONSerialization.jsonObject(with: $0.httpBody!) as! [String: Any]
        }
        #expect(batches.map { ($0["ids"] as! [String]).count } == [1000, 1000, 500])
        #expect(batches.allSatisfy { $0["removeLabelIds"] as? [String] == ["UNREAD"] })
        #expect(batches[0]["ids"] as? [String] == (0..<1000).map { "m\($0)" })
        let gets = t.requests.filter { $0.httpMethod == "GET" }
        #expect(gets.count == 5)
        let first = URLComponents(url: gets[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(first.first { $0.name == "maxResults" }?.value == "500")
    }

    @Test func markAllReadWithNothingUnreadSendsNoBatch() async throws {
        let t = StubTransport { _ in (jsonData([String: Any]()), 200) }
        #expect(try await makeGmail(t).markAllRead() == 0)
        #expect(t.requests.filter { $0.url!.path.hasSuffix("/batchModify") }.isEmpty)
    }

    @Test func noContentResponseCountsAsSuccess() async throws {
        let t = StubTransport { _ in (Data(), 204) }
        try await makeGmail(t).markRead(threadId: "t1")
    }
}
