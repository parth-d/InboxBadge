import Foundation
import Testing
@testable import InboxCore

struct NotificationPlanTests {
    private func thread(_ n: Int) -> UnreadThread {
        UnreadThread(id: "t\(n)", messageID: "m\(n)", from: "Sender \(n) <s\(n)@x.com>", subject: "Subject \(n)", date: nil)
    }

    @Test func noMailMeansNoNotifications() {
        #expect(NotificationPlan.newMail([], email: "me@x.com").isEmpty)
    }

    @Test func fewMessagesNotifyIndividuallyWithThreadLink() {
        let plan = NotificationPlan.newMail([thread(1), thread(2), thread(3)], email: "me@x.com")
        #expect(plan.count == 3)
        #expect(plan[0].title == "Sender 1")
        #expect(plan[0].body == "Subject 1")
        #expect(plan[0].kind == .message(threadId: "t1"))
        #expect(plan[0].url == GmailLinks.thread(email: "me@x.com", threadId: "t1"))
        #expect(Set(plan.map(\.identifier)).count == 3)
    }

    @Test func moreThanThreeCoalesceIntoOneSummary() {
        let plan = NotificationPlan.newMail((1...4).map(thread), email: "me@x.com")
        #expect(plan.count == 1)
        #expect(plan[0].kind == .summary)
        #expect(plan[0].title == "4 new messages")
        #expect(plan[0].body == "me@x.com")
        #expect(plan[0].url == GmailLinks.inbox(email: "me@x.com"))
    }

    @Test func reauthNotificationNamesTheAccount() {
        let n = NotificationPlan.reauth(email: "me@x.com")
        #expect(n.kind == .reauth)
        #expect(n.body.contains("me@x.com"))
        #expect(n.identifier == "reauth.me@x.com")
    }
}
