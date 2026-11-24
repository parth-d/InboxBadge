import Foundation

public struct TickResult: Equatable, Sendable {
    public var snapshot: InboxSnapshot?
    public var newMail: [UnreadThread]

    public init(snapshot: InboxSnapshot?, newMail: [UnreadThread] = []) {
        self.snapshot = snapshot
        self.newMail = newMail
    }
}

public actor AccountPoller {
    private static let notifiedLimit = 500

    private let client: GmailClient
    private let listSize: Int
    private var historyId: String?
    private var cache: [String: MessageMeta] = [:]
    private var last: InboxSnapshot?
    private var notified: [String] = []

    public init(client: GmailClient, listSize: Int = 20) {
        self.client = client
        self.listSize = listSize
    }

    public func tick() async throws -> TickResult {
        guard let known = historyId else {
            coreLog.info("tick: no cursor, baseline")
            return TickResult(snapshot: try await resync())
        }
        switch try await client.history(since: known) {
        case .unchanged(let id):
            historyId = id
            return TickResult(snapshot: nil)
        case .changed(let id, let added):
            let snapshot = try await takeSnapshot()
            let fresh = await newMail(from: added)
            coreLog.info("tick changed added=\(added.count) fresh=\(fresh.count)")
            historyId = id
            return TickResult(snapshot: emit(snapshot), newMail: fresh)
        case .expired:
            coreLog.info("tick: history expired, resync without notifications")
            return TickResult(snapshot: try await resync())
        }
    }

    public func resync() async throws -> InboxSnapshot? {
        let profile = try await client.profile()
        let snapshot = try await takeSnapshot()
        historyId = profile.historyId
        return emit(snapshot)
    }

    private func emit(_ snapshot: InboxSnapshot) -> InboxSnapshot? {
        if snapshot == last { return nil }
        last = snapshot
        return snapshot
    }

    private func newMail(from added: [MessageRef]) async -> [UnreadThread] {
        let client = self.client
        var fresh: [UnreadThread] = []
        for ref in added where !notified.contains(ref.id) {
            let meta: MessageMeta?
            if let cached = cache[ref.id] { meta = cached } else { meta = try? await client.metadata(of: ref) }
            guard let meta, meta.isUnreadInbox else { continue }
            fresh.append(meta.thread)
            notified.append(ref.id)
        }
        if notified.count > Self.notifiedLimit { notified.removeFirst(notified.count - Self.notifiedLimit) }
        return fresh
    }

    private func takeSnapshot() async throws -> InboxSnapshot {
        async let count = client.inboxUnreadCount()
        let refs = try await client.unreadRefs(limit: listSize)
        let client = self.client
        let missing = refs.filter { cache[$0.id] == nil }
        var fetched: [String: MessageMeta] = [:]
        await withTaskGroup(of: MessageMeta?.self) { group in
            for ref in missing { group.addTask { try? await client.metadata(of: ref) } }
            for await meta in group { if let meta { fetched[meta.thread.messageID] = meta } }
        }
        let metas = refs.compactMap { cache[$0.id] ?? fetched[$0.id] }
        cache = Dictionary(metas.map { ($0.thread.messageID, $0) }, uniquingKeysWith: { a, _ in a })
        return InboxSnapshot(unreadCount: try await count, threads: metas.map(\.thread))
    }
}
