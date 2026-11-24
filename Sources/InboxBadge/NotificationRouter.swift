import AppKit
import UserNotifications
import InboxCore

@MainActor
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    private static let category = "MAIL"
    private static let markRead = "MARK_READ"
    private static let delete = "DELETE"

    var onMarkRead: ((_ email: String, _ threadId: String) -> Void)?
    var onDelete: ((_ email: String, _ threadId: String) -> Void)?
    var onReauth: (() -> Void)?

    private let center = UNUserNotificationCenter.current()

    func start() {
        center.delegate = self
        let read = UNNotificationAction(identifier: Self.markRead, title: "Mark as read", options: [])
        let delete = UNNotificationAction(identifier: Self.delete, title: "Delete", options: [.destructive])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [read, delete], intentIdentifiers: [], options: []),
        ])
        center.requestAuthorization(options: [.alert]) { granted, error in
            log.info("notification authorization granted=\(granted) error=\(error.map { String(describing: $0) } ?? "none", privacy: .public)")
        }
    }

    func post(_ notification: MailNotification) {
        let content = UNMutableNotificationContent()
        content.title = notification.title
        content.body = notification.body
        var info = ["email": notification.email, "url": notification.url.absoluteString]
        switch notification.kind {
        case .message(let threadId):
            content.categoryIdentifier = Self.category
            info["threadId"] = threadId
            info["kind"] = "message"
        case .summary: info["kind"] = "summary"
        case .reauth: info["kind"] = "reauth"
        }
        content.userInfo = info
        center.add(UNNotificationRequest(identifier: notification.identifier, content: content, trigger: nil)) { error in
            if let error { log.error("notification post failed: \(error.localizedDescription, privacy: .public)") }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        let action = response.actionIdentifier
        await MainActor.run { handle(action: action, info: info) }
    }

    private func handle(action: String, info: [String: String]) {
        guard let email = info["email"] else { return }
        switch action {
        case Self.markRead:
            if let thread = info["threadId"] { onMarkRead?(email, thread) }
        case Self.delete:
            if let thread = info["threadId"] { onDelete?(email, thread) }
        case UNNotificationDefaultActionIdentifier:
            if info["kind"] == "reauth" { onReauth?() }
            else if let url = info["url"].flatMap(URL.init(string:)) { NSWorkspace.shared.open(url) }
        default: break
        }
    }
}
