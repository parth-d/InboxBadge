import AppKit
import SwiftUI
import InboxCore
import InboxUI

struct PopoverView: View {
    let model: AppModel

    var body: some View {
        PopoverContent(accounts: model.accounts, actions: PopoverActions(
            openThread: { email, thread in NSWorkspace.shared.open(GmailLinks.thread(email: email, threadId: thread)) },
            markRead: { model.markRead(email: $0, threadId: $1) },
            trash: { model.trash(email: $0, threadId: $1) },
            markAllRead: { model.markAllRead(email: $0) },
            openInbox: { NSWorkspace.shared.open(GmailLinks.inbox(email: $0)) },
            checkNow: { Task { await model.checkNow() } },
            openSettings: { model.openSettings() },
            quit: { NSApp.terminate(nil) }))
    }
}
