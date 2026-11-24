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
        #expect(try await makeGmail(t).history(since: "200") == .changed(historyId: "206"))
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
        let thread = try await makeGmail(t).metadata(of: MessageRef(id: "m1", threadId: "t1"))
        #expect(thread == UnreadThread(id: "t1", messageID: "m1", from: "Jane <j@x.com>", subject: "Hi",
                                       date: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(t.requests[0].url!.path == "/v1/users/me/messages/m1")
    }

    @Test func emptySubjectGetsPlaceholder() async throws {
        let t = StubTransport { _ in (jsonData(["internalDate": "1", "payload": ["headers": []]]), 200) }
        let thread = try await makeGmail(t).metadata(of: MessageRef(id: "m", threadId: "t"))
        #expect(thread.subject == "(no subject)")
    }
}
