import Foundation

public actor AccountPoller {
    private let client: GmailClient
    private let listSize: Int
    private var historyId: String?
    private var cache: [String: UnreadThread] = [:]
    private var last: InboxSnapshot?

    public init(client: GmailClient, listSize: Int = 20) {
        self.client = client
        self.listSize = listSize
    }

    public func tick() async throws -> InboxSnapshot? {
        guard let known = historyId else { return try await resync() }
        switch try await client.history(since: known) {
        case .unchanged(let id):
            historyId = id
            return nil
        case .changed(let id):
            let snapshot = try await takeSnapshot()
            historyId = id
            return emit(snapshot)
        case .expired:
            return try await resync()
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

    private func takeSnapshot() async throws -> InboxSnapshot {
        async let count = client.inboxUnreadCount()
        let refs = try await client.unreadRefs(limit: listSize)
        let client = self.client
        let missing = refs.filter { cache[$0.id] == nil }
        var fetched: [String: UnreadThread] = [:]
        await withTaskGroup(of: UnreadThread?.self) { group in
            for ref in missing { group.addTask { try? await client.metadata(of: ref) } }
            for await thread in group { if let thread { fetched[thread.messageID] = thread } }
        }
        let threads = refs.compactMap { cache[$0.id] ?? fetched[$0.id] }
        cache = Dictionary(threads.map { ($0.messageID, $0) }, uniquingKeysWith: { a, _ in a })
        return InboxSnapshot(unreadCount: try await count, threads: threads)
    }
}
