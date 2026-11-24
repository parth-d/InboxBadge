import Foundation
import InboxCore

public enum AccountStatus: Equatable, Sendable {
    case starting
    case ok
    case reauthRequired
    case error(String)
}

public struct AccountView: Identifiable, Equatable, Sendable {
    public let email: String
    public var label: String
    public var unread: Int
    public var threads: [UnreadThread]
    public var status: AccountStatus
    public var spam: SpamSummary?

    public var id: String { email }
    public var title: String { label.isEmpty ? email : label }
    public var subtitle: String? { label.isEmpty ? nil : email }

    public init(email: String, label: String = "", unread: Int = 0, threads: [UnreadThread] = [],
                status: AccountStatus = .starting, spam: SpamSummary? = nil) {
        self.email = email
        self.label = label
        self.unread = unread
        self.threads = threads
        self.status = status
        self.spam = spam
    }
}

public struct PopoverActions {
    public var openThread: (_ email: String, _ threadId: String) -> Void
    public var markRead: (_ email: String, _ threadId: String) -> Void
    public var trash: (_ email: String, _ threadId: String) -> Void
    public var markAllRead: (_ email: String) -> Void
    public var openInbox: (_ email: String) -> Void
    public var openSpam: (_ email: String) -> Void
    public var markSpamRead: (_ email: String) -> Void
    public var trashSpam: (_ email: String) -> Void
    public var checkNow: () -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void

    public init(openThread: @escaping (String, String) -> Void, markRead: @escaping (String, String) -> Void,
                trash: @escaping (String, String) -> Void, markAllRead: @escaping (String) -> Void,
                openInbox: @escaping (String) -> Void, openSpam: @escaping (String) -> Void,
                markSpamRead: @escaping (String) -> Void, trashSpam: @escaping (String) -> Void, checkNow: @escaping () -> Void,
                openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openThread = openThread
        self.markRead = markRead
        self.trash = trash
        self.markAllRead = markAllRead
        self.openInbox = openInbox
        self.openSpam = openSpam
        self.markSpamRead = markSpamRead
        self.trashSpam = trashSpam
        self.checkNow = checkNow
        self.openSettings = openSettings
        self.quit = quit
    }

    public static let none = PopoverActions(openThread: { _, _ in }, markRead: { _, _ in }, trash: { _, _ in },
                                            markAllRead: { _ in }, openInbox: { _ in }, openSpam: { _ in },
                                            markSpamRead: { _ in }, trashSpam: { _ in }, checkNow: {},
                                            openSettings: {}, quit: {})
}
