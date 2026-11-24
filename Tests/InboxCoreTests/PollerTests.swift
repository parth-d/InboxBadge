import Foundation
import Testing
@testable import InboxCore

struct PollerTests {
    private func rig(_ messages: [FakeMailbox.Msg]) -> (FakeMailbox, StubTransport, AccountPoller) {
        let box = FakeMailbox()
        box.messages = messages
        let t = StubTransport { box.handle($0) }
        return (box, t, AccountPoller(client: makeGmail(t)))
    }

    private let two = [FakeMailbox.Msg(id: "m2", thread: "t2", from: "B <b@x>", subject: "Two"),
                       FakeMailbox.Msg(id: "m1", thread: "t1", from: "A <a@x>", subject: "One")]

    @Test func firstTickBaselinesWithSnapshotAndNoHistoryCall() async throws {
        let (_, t, poller) = rig(two)
        let snap = try #require(try await poller.tick())
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
        #expect(try await poller.tick() == nil)
        #expect(t.requests.count == before + 1)
        #expect(t.count(pathSuffix: "/history") == 1)
    }

    @Test func changeRefreshesSnapshotAndFetchesOnlyNewMessages() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.insert(.init(id: "m3", thread: "t3", from: "C <c@x>", subject: "Three"), at: 0)
        box.historyChanged = true
        let snap = try #require(try await poller.tick())
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
        #expect(try await poller.tick() == nil)
    }

    @Test func expiredHistoryTriggersSilentResync() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.historyStatus = 404
        box.messages.removeFirst()
        let snap = try #require(try await poller.tick())
        #expect(snap.unreadCount == 1)
        #expect(t.count(pathSuffix: "/profile") == 2)
    }

    @Test func messageThatVanishesBetweenListAndGetIsSkipped() async throws {
        let (box, _, poller) = rig(two)
        box.failMetadata = ["m2"]
        let snap = try #require(try await poller.tick())
        #expect(snap.threads.map(\.id) == ["t1"])
    }

    @Test func resyncAfterReadMessageDropsItFromCache() async throws {
        let (box, t, poller) = rig(two)
        _ = try await poller.tick()
        box.messages.removeFirst()
        box.historyChanged = true
        let snap = try #require(try await poller.tick())
        #expect(snap.threads.map(\.id) == ["t1"])
        box.messages.insert(two[0], at: 0)
        _ = try await poller.tick()
        #expect(t.count(pathSuffix: "/messages/m2") == 2)
    }
}
