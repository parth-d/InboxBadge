# InboxBadge

A small, battery-light macOS menu-bar app that shows your unread Gmail count for several accounts, lists the unread threads, notifies you about new mail, and lets you mark threads read or move them to Trash. It replaces browser-extension notifiers: it needs no browser to be running.

- Per-account unread count and the newest unread threads in the popover; click one to open it in your default browser, in the right account.
- Native notifications for new mail with **Mark as read** and **Delete** buttons (more than three new messages in one check become one summary).
- **Mark as read**, **Delete** (to Trash, recoverable in Gmail for 30 days) and **Mark all as read** from the popover.
- Several accounts (personal and Google Workspace), each with its own sign-in, a label you choose, and an order you set.
- Open at login, check interval (30 s to 10 min), notifications on or off, an optional notification sound (any macOS system sound).
- Apple frameworks only, no third-party dependencies. MIT licensed.

InboxBadge talks to the Gmail API directly from your Mac. It has no server, no analytics and no account of its own; see [the privacy policy](docs/privacy.md).

## How it saves battery

One small `history.list` request per account per check (a poll), not a continuous connection. Timers are coalesced with 20% tolerance, the interval stretches 5x while the displays sleep and 2x in Low Power Mode, a check runs at once on wake and when the network returns, failures back off to 15 minutes, and the UI only redraws when a count or list changes. `tools/energy-check.sh` measures the CPU time over a window.

## Requirements

- macOS 14 or later, Apple silicon or Intel.
- Command Line Tools (`xcode-select --install`) with Swift 6. Xcode is not needed.
- A Google Cloud project with the Gmail API enabled (below). It is free; no billing account is needed.

## Google Cloud setup (once)

Gmail's API needs an OAuth client that you create yourself, so your mail never goes through anyone else's app registration.

1. In the [Google Cloud console](https://console.cloud.google.com) create a project, enable the **Gmail API**, and do **not** link a billing account.
2. Open **Google Auth Platform**: set the audience to **External**, add the scope `https://www.googleapis.com/auth/gmail.modify` (read, mark read, move to Trash; it cannot permanently delete), and while the app is in **Testing** add every Gmail and Workspace address you want to use as a **test user**.
3. Create an OAuth client of type **Desktop app** and download its JSON file.
4. In InboxBadge open **Settings → Add account…**, choose that JSON file and approve access in the browser. Google shows "Google hasn't verified this app" for personal projects; choose **Advanced → Go to InboxBadge**.

Testing status expires every sign-in after 7 days. To stop that, publish the project to **In production** (Google Auth Platform → Audience). An unverified production app is limited to 100 users, which is plenty for personal use; it needs a homepage and a privacy-policy URL (see `docs/`). A Google Workspace admin may block third-party apps; then that account cannot be added.

## Build and install

```sh
make test              # unit tests
make app               # release build, InboxBadge.app, signed
make install           # copies it to ~/Applications and relaunches it
make run               # open it
make logs              # the app's log lines (counts and status, never mail content)
```

Signing: `make app` uses a self-signed identity if one exists, otherwise an ad-hoc signature. With an ad-hoc signature every rebuild changes the app's identity and macOS Keychain refuses the previous build's saved sign-in, so run `make signing-identity` once (it creates a dedicated keychain at `~/Library/Keychains/inboxbadge-signing.keychain-db`, nothing in your login keychain). Command Line Tools ship Swift Testing without its macro plugin on the default path; the Makefile passes the plugin path for you.

## Troubleshooting

- **No notifications**: System Settings → Notifications → InboxBadge → Allow. macOS asks only once.
- **Keychain asks for your password after you rebuild**: choose Always Allow. macOS ties the permission to the exact build, so each rebuild asks once (one item holds all accounts). A downloaded or unchanged build asks once.
- **"Sign in again"**: the refresh token is gone (password change, access revoked, or the 7-day Testing expiry). Remove the account in Settings and add it again.
- **Settings → Open at login is greyed or flips back**: approve it under System Settings → General → Login Items.
- **Count differs from Gmail's sidebar**: the count is the Inbox label's unread thread count, the same figure Gmail shows; Spam and Trash are not included.

## Layout

`Sources/InboxCore` all logic (OAuth, Gmail client, poller, energy policy, notification plan, Keychain store), unit tested; `Sources/InboxUI` the popover view; `Sources/InboxPreview` renders the popover to PNG files for design work (`swift run InboxPreview <dir>`; buttons and menus appear as placeholder glyphs there); `Sources/InboxBadge` the app shell (menu-bar item, Settings, notifications); `tools/` the OAuth probe, mutation check, signing and energy scripts; `docs/` the web pages Google's consent screen links to.

`tools/mutation-check.sh` applies each seeded fault in `tools/mutants.txt` to a throwaway copy and requires the named test to fail.

## License

MIT, see `LICENSE`.
