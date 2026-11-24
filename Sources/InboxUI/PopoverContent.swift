import SwiftUI
import InboxCore

public struct PopoverContent: View {
    private let accounts: [AccountView]
    private let actions: PopoverActions
    private let now: Date

    public init(accounts: [AccountView], actions: PopoverActions, now: Date = Date()) {
        self.accounts = accounts
        self.actions = actions
        self.now = now
    }

    public var body: some View {
        VStack(spacing: 10) {
            if accounts.isEmpty {
                VStack(spacing: 4) {
                    Image(systemName: "envelope.badge").font(.system(size: 22)).foregroundStyle(.secondary)
                    Text("No accounts yet").font(.system(size: 13, weight: .semibold))
                    Text("Add one in Settings.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
            } else {
                ForEach(accounts) { AccountCard(account: $0, actions: actions, now: now) }
            }
            FooterBar(actions: actions)
        }
        .padding(12)
        .frame(width: 380)
    }
}

private struct AccountCard: View {
    let account: AccountView
    let actions: PopoverActions
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            banner
            if account.status == .ok || account.status == .starting {
                if account.threads.isEmpty && account.unread == 0 {
                    Divider()
                    Text("All caught up")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
            ForEach(account.threads) { thread in
                Divider()
                ThreadRow(thread: thread, email: account.email, actions: actions, now: now)
            }
            if account.unread > account.threads.count && !account.threads.isEmpty {
                Divider()
                Button { actions.openInbox(account.email) } label: {
                    Text("\(account.unread - account.threads.count) more in Gmail")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if let spam = account.spam {
                Divider()
                SpamRow(spam: spam, email: account.email, actions: actions)
            }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button { actions.openInbox(account.email) } label: {
                VStack(alignment: .leading, spacing: 1) {
                    Text(account.title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
                    if let subtitle = account.subtitle {
                        Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open inbox in browser")
            Text("\(account.unread)")
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(account.unread > 0 ? Color.accentColor : Color.primary.opacity(0.12)))
                .foregroundStyle(account.unread > 0 ? Color.white : Color.secondary)
            Button { actions.markAllRead(account.email) } label: {
                Label("Mark all read", systemImage: "checkmark.circle")
                    .font(.system(size: 11)).labelStyle(.titleAndIcon)
            }
            .buttonStyle(.borderless)
            .disabled(account.unread == 0)
            .help("Mark every unread message in this inbox as read")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }

    @ViewBuilder private var banner: some View {
        switch account.status {
        case .reauthRequired:
            statusLine("Sign in again in Settings", symbol: "exclamationmark.triangle.fill", color: .orange)
        case .error(let message):
            statusLine(message, symbol: "wifi.exclamationmark", color: .secondary)
        case .starting, .ok:
            EmptyView()
        }
    }

    private func statusLine(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 11))
            Text(text).font(.system(size: 12))
            Spacer(minLength: 0)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 12).padding(.bottom, 8)
    }
}

private struct SpamRow: View {
    let spam: SpamSummary
    let email: String
    let actions: PopoverActions

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "xmark.bin").font(.system(size: 12)).foregroundStyle(.secondary).frame(width: 16)
            Text("Spam").font(.system(size: 12, weight: .medium))
            Text(spam.unread > 0 ? "\(spam.unread) unread" : (spam.total > 0 ? "\(spam.total) total" : "empty"))
                .font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer(minLength: 6)
            IconButton(symbol: "envelope.open", help: "Mark all spam as read") { actions.markSpamRead(email) }
                .disabled(spam.unread == 0)
            IconButton(symbol: "trash", help: "Move all spam to Trash") { actions.trashSpam(email) }
                .disabled(spam.total == 0)
            IconButton(symbol: "arrow.up.right.square", help: "Open the spam folder") { actions.openSpam(email) }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 5)
    }
}

private struct ThreadRow: View {
    let thread: UnreadThread
    let email: String
    let actions: PopoverActions
    let now: Date

    var body: some View {
        HStack(spacing: 6) {
            Button { actions.openThread(email, thread.id) } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(SenderName.display(thread.from))
                            .font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Spacer(minLength: 6)
                        if let date = thread.date {
                            Text(AgeFormat.short(date, now: now)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    Text(thread.subject).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            HStack(spacing: 0) {
                IconButton(symbol: "envelope.open", help: "Mark as read") { actions.markRead(email, thread.id) }
                IconButton(symbol: "trash", help: "Delete") { actions.trash(email, thread.id) }
            }
        }
        .padding(.leading, 12).padding(.trailing, 6).padding(.vertical, 7)
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).font(.system(size: 12)).frame(width: 26, height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

private struct FooterBar: View {
    let actions: PopoverActions

    var body: some View {
        HStack(spacing: 14) {
            Button { actions.checkNow() } label: { Label("Check now", systemImage: "arrow.clockwise") }
            Spacer()
            Button { actions.openSettings() } label: { Image(systemName: "gearshape") }.help("Settings")
            Button { actions.quit() } label: { Image(systemName: "power") }.help("Quit InboxBadge")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}
