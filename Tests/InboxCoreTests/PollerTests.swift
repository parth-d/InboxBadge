import Foundation
import Testing
@testable import InboxCore

struct PollerTests {
    private func rig(_ messages: [FakeMailbox.Msg], listSize: Int = 20) -> (FakeMailbox, StubTransport, AccountPoller) {
        let box = FakeMailbox()
        box.messages = messages
        let t = StubTransport { box.handle($0) }
        return (box, t, AccountPoller(client: makeGmail(t), listSize: listSize))
    }

    private let two = [FakeMailbox.Msg(id: "m2", thread: "t2", from: "B <b@x>", subject: "Two"),
                       FakeMailbox.Msg(id: "m1", thread: "t1", from: "A <a@x>", subject: "One")]

    @Test func firstTickBaselinesWithSnapshotAndNoHistoryCall() async throws {
        let (_, t, poller) = rig(two)
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.unreadCount == 2)
        #expect(snap.threads.map(\.id) == ["t2", "t1"])
        #expect(snap.threads[0].subject == "Two")
        #expect(t.count(pathSuffix: "/history") == 0)
        #expect(t.count(pathSuffix: "/profile") == 1)
    }

    @Test func quietTickIsOneHistoryCallAndNothingElse() async throws {
        let (_, t, poller) = rig(two)
        _ = try await poller.tick()
        let before = t.requests.count
        #expect(try await poller.tick().snapshot == nil)
        #expect(t.requests.count == before + 1)
        #expect(t.count(pathSuffix: "/history") == 1)
    }

    @Test func changeRefreshesSnapshotAndFetchesOnlyNewMessages() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(.init(id: "m3", thread: "t3", from: "C <c@x>", subject: "Three"), at: 0)
        box.historyChanged = true
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.unreadCount == 3)
        #expect(snap.threads.map(\.id) == ["t3", "t2", "t1"])
        #expect(t.count(pathSuffix: "/messages/m1") == 1)
        #expect(t.count(pathSuffix: "/messages/m3") == 1)
    }

    @Test func historyCursorAdvancesOnQuietAndChangedTicks() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.historyId = 150
        _ = try await poller.tick()
        box.historyId = 160
        box.historyChanged = true
        _ = try await poller.tick()
        box.historyChanged = false
        _ = try await poller.tick()
        let starts = t.requests.filter { $0.url!.path.hasSuffix("/history") }.map {
            URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "startHistoryId" }!.value!
        }
        #expect(starts == ["100", "150", "160"])
    }

    @Test func changeThatLeavesSnapshotEqualEmitsNothing() async throws {
        let (box, _, poller) = rig(two)
        _ = try await poller.tick()
        box.historyChanged = true
        #expect(try await poller.tick().snapshot == nil)
    }

    @Test func expiredHistoryTriggersSilentResync() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.historyStatus = 404
        box.messages.removeFirst()
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.unreadCount == 1)
        #expect(t.count(pathSuffix: "/profile") == 2)
    }

    @Test func messageThatVanishesBetweenListAndGetIsSkipped() async throws {
        let (box, _, poller) = rig(two)
        box.failMetadata = ["m2"]
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.threads.map(\.id) == ["t1"])
    }

    @Test func resyncAfterReadMessageDropsItFromCache() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.removeFirst()
        box.historyChanged = true
        let snap = try #require(try await poller.tick().snapshot)
        #expect(snap.threads.map(\.id) == ["t1"])
        box.messages.insert(two[0], at: 0)
        _ = try await poller.tick()
        #expect(t.count(pathSuffix: "/messages/m2") == 2)
    }

    private func mail(_ id: String, thread: String, labels: Set<String> = ["INBOX", "UNREAD"]) -> FakeMailbox.Msg {
        .init(id: id, thread: thread, from: "S <s@x>", subject: "Subj \(id)", labels: labels)
    }

    @Test func newMailOnlyForAddedMessagesThatAreUnreadInbox() async throws {
        let (box, _, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(contentsOf: [mail("m3", thread: "t3"), mail("m4", thread: "t4", labels: ["SENT"]),
                                         mail("m5", thread: "t5", labels: ["INBOX"])], at: 0)
        box.added = ["m3", "m4", "m5"]
        box.historyChanged = true
        let result = try await poller.tick()
        #expect(result.newMail.map(\.messageID) == ["m3"])
        #expect(result.newMail.first?.subject == "Subj m3")
    }

    @Test func baselineNeverNotifies() async throws {
        let (_, _, poller) = rig(two)
        let result = try await poller.tick()
        #expect(result.snapshot != nil)
        #expect(result.newMail.isEmpty)
    }

    @Test func resyncAfterExpiredHistoryNeverNotifies() async throws {
        let (box, _, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(mail("m3", thread: "t3"), at: 0)
        box.added = ["m3"]
        box.historyChanged = true
        box.historyStatus = 404
        let result = try await poller.tick()
        #expect(result.snapshot?.unreadCount == 3)
        #expect(result.newMail.isEmpty)
    }

    @Test func sameAddedMessageIsNotNotifiedTwice() async throws {
        let (box, _, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(mail("m3", thread: "t3"), at: 0)
        box.added = ["m3"]
        box.historyChanged = true
        #expect(try await poller.tick().newMail.count == 1)
        #expect(try await poller.tick().newMail.isEmpty)
    }

    @Test func addedMessageBeyondTheListedWindowIsStillNotified() async throws {
        let (box, _, poller) = rig([mail("m9", thread: "t9")], listSize: 1)
        _ = try await poller.tick()
        box.messages.append(mail("m2", thread: "t2"))
        box.added = ["m2"]
        box.historyChanged = true
        let result = try await poller.tick()
        #expect(result.snapshot?.threads.map(\.id) == ["t9"])
        #expect(result.newMail.map(\.messageID) == ["m2"])
    }

    @Test func addedMessagesAcrossHistoryPagesAreAllSeen() async throws {
        let (box, _, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(contentsOf: [mail("m3", thread: "t3"), mail("m4", thread: "t4"), mail("m5", thread: "t5")], at: 0)
        box.added = ["m3", "m4", "m5"]
        box.historyPageSize = 1
        box.historyChanged = true
        #expect(try await poller.tick().newMail.map(\.messageID) == ["m3", "m4", "m5"])
    }
}
