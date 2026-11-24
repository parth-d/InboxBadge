import Foundation

public struct MailNotification: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case message(threadId: String)
        case summary
        case reauth
    }

    public let identifier: String
    public let title: String
    public let body: String
    public let kind: Kind
    public let email: String
    public let url: URL
}

public enum NotificationPlan {
    public static let maxIndividual = 3

    public static func newMail(_ mail: [UnreadThread], email: String) -> [MailNotification] {
        guard !mail.isEmpty else { return [] }
        if mail.count > maxIndividual {
            return [MailNotification(identifier: "summary.\(email).\(mail[0].messageID)",
                                     title: "\(mail.count) new messages", body: email,
                                     kind: .summary, email: email, url: GmailLinks.inbox(email: email))]
        }
        return mail.map {
            MailNotification(identifier: "mail.\($0.messageID)", title: SenderName.display($0.from), body: $0.subject,
                             kind: .message(threadId: $0.id), email: email,
                             url: GmailLinks.thread(email: email, threadId: $0.id))
        }
    }

    public static func reauth(email: String) -> MailNotification {
        MailNotification(identifier: "reauth.\(email)", title: "Sign in again",
                         body: "InboxBadge lost access to \(email)", kind: .reauth, email: email,
                         url: GmailLinks.inbox(email: email))
    }
}
