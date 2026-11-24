import Foundation
import Testing
@testable import InboxCore

struct PrimaryModeTests {
    private func msg(_ id: String, thread: String, _ labels: Set<String>) -> FakeMailbox.Msg {
        .init(id: id, thread: thread, from: "S <s@x>", subject: "Subj \(id)", labels: labels)
    }

    private let personal: Set<String> = ["INBOX", "UNREAD", "CATEGORY_PERSONAL"]
    private let promo: Set<String> = ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"]

    private func rig(_ messages: [FakeMailbox.Msg], mode: InboxMode)
        -> (FakeMailbox, StubTransport, AccountPoller) {
        let box = FakeMailbox()
        box.messages = messages
        let t = StubTransport { box.handle($0) }
        return (box, t, AccountPoller(client: makeGmail(t), mode: mode))
    }

    @Test func primaryCountsDistinctThreadsOfPersonalUnreadInbox() async throws {
        let (_, _, poller) = rig([msg("m1", thread: "t1", personal), msg("m2", thread: "t1", personal),
                                  msg("m3", thread: "t2", personal), msg("m4", thread: "t3", promo)], mode: .primary)
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.unreadCount == 2)
        #expect(snap.threads.map(\.id) == ["t1", "t2"])
    }

    @Test func inboxModeStillCountsEverything() async throws {
        let (_, _, poller) = rig([msg("m1", thread: "t1", personal), msg("m4", thread: "t3", promo)], mode: .inbox)
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.unreadCount == 2)
        #expect(snap.threads.count == 2)
    }

    @Test func primaryModeIgnoresNewPromotionsMail() async throws {
        let (box, _, poller) = rig([msg("m1", thread: "t1", personal)], mode: .primary)
        _ = try await poller.tick()
        box.messages.insert(contentsOf: [msg("m2", thread: "t2", promo), msg("m3", thread: "t3", personal)], at: 0)
        box.added = ["m2", "m3"]
        box.historyChanged = true
        let result = try await poller.tick()
        #expect(result.newMail.map(\.messageID) == ["m3"])
        #expect(result.snapshot?.unreadCount == 2)
    }

    @Test func switchingModeResyncsWithoutNotifying() async throws {
        let (_, _, poller) = rig([msg("m1", thread: "t1", personal), msg("m4", thread: "t3", promo)], mode: .inbox)
        #expect(try await poller.tick().snapshot?.unreadCount == 2)
        await poller.setMode(.primary)
        let result = try await poller.tick()
        #expect(result.snapshot?.unreadCount == 1)
        #expect(result.newMail.isEmpty)
    }

    @Test func settingTheSameModeKeepsTheCursor() async throws {
        let (_, t, poller) = rig([msg("m1", thread: "t1", personal)], mode: .inbox)
        _ = try await poller.tick()
        await poller.setMode(.inbox)
        _ = try await poller.tick()
        #expect(t.count(pathSuffix: "/history") == 1)
    }

    @Test func primaryCountPagesThroughAllMessages() async throws {
        let t = StubTransport { r in
            let token = URLComponents(url: r.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "pageToken" }?.value
            if token == nil {
                return (jsonData(["messages": [["id": "a", "threadId": "t1"], ["id": "b", "threadId": "t2"]], "nextPageToken": "p"]), 200)
            }
            return (jsonData(["messages": [["id": "c", "threadId": "t2"], ["id": "d", "threadId": "t3"]]]), 200)
        }
        #expect(try await makeGmail(t).unreadCount(mode: .primary) == 3)
        let first = URLComponents(url: t.requests[0].url!, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(first.filter { $0.name == "labelIds" }.compactMap(\.value).sorted() == ["CATEGORY_PERSONAL", "INBOX", "UNREAD"])
    }

    @Test func inboxCountUsesTheLabelNotAList() async throws {
        let t = StubTransport { _ in (jsonData(["threadsUnread": 7]), 200) }
        #expect(try await makeGmail(t).unreadCount(mode: .inbox) == 7)
        #expect(t.requests.count == 1)
        #expect(t.requests[0].url!.path.hasSuffix("/labels/INBOX"))
    }

    @Test func qualifiesRequiresPersonalLabelOnlyInPrimaryMode() {
        let base = UnreadThread(id: "t", messageID: "m", from: "", subject: "", date: nil)
        let promoMeta = MessageMeta(thread: base, labelIds: ["INBOX", "UNREAD", "CATEGORY_PROMOTIONS"])
        let personalMeta = MessageMeta(thread: base, labelIds: ["INBOX", "UNREAD", "CATEGORY_PERSONAL"])
        #expect(promoMeta.qualifies(for: .inbox))
        #expect(!promoMeta.qualifies(for: .primary))
        #expect(personalMeta.qualifies(for: .primary))
    }
}
