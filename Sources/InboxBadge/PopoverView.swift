import SwiftUI
import InboxCore

struct PopoverView: View {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if model.accounts.isEmpty {
                Text("No accounts yet.").foregroundStyle(.secondary)
            }
            ForEach(model.accounts) { account in
                AccountSection(account: account)
            }
            Divider()
            HStack {
                Button("Check now") { Task { await model.checkNow() } }
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(12)
        .frame(width: 360)
    }
}

private struct AccountSection: View {
    let account: AccountView

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("\(account.email) · \(account.unread)").font(.headline)
                Spacer()
                Button("Open inbox") { NSWorkspace.shared.open(GmailLinks.inbox(email: account.email)) }
                    .buttonStyle(.link)
            }
            switch account.status {
            case .reauthRequired:
                Text("⚠ Sign in again (Settings)").foregroundStyle(.orange)
            case .error(let message):
                Text("⚠ \(message)").foregroundStyle(.secondary)
            case .starting, .ok:
                EmptyView()
            }
            ForEach(account.threads) { thread in
                Button {
                    NSWorkspace.shared.open(GmailLinks.thread(email: account.email, threadId: thread.id))
                } label: {
                    ThreadRow(thread: thread)
                }
                .buttonStyle(.plain)
            }
            if account.unread > account.threads.count {
                Text("\(account.unread - account.threads.count) more in Gmail…").font(.caption).foregroundStyle(.secondary)
            }
            if account.unread == 0 && account.status == .ok {
                Text("Nothing unread").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct ThreadRow: View {
    let thread: UnreadThread

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(SenderName.display(thread.from)).fontWeight(.semibold).lineLimit(1)
                Spacer()
                if let date = thread.date {
                    Text(date, format: .relative(presentation: .numeric, unitsStyle: .abbreviated))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text(thread.subject).font(.callout).foregroundStyle(.secondary).lineLimit(1)
        }
        .contentShape(Rectangle())
    }
}
