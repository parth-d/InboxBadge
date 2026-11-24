# InboxBadge privacy policy

Last updated: 2026-11-24

InboxBadge is a macOS menu-bar app that runs entirely on your own Mac. The developer does not operate any server that receives your data.

## What InboxBadge accesses

When you sign in with Google, InboxBadge asks for one permission: `https://www.googleapis.com/auth/gmail.modify`. It uses it to:

- read your Gmail address;
- read the number of unread threads in your Inbox and, for the newest unread messages, the sender, subject, date, message and thread identifiers and labels;
- when you click the buttons, remove the UNREAD label from a thread (mark as read) or move a thread to Trash.

It does not read message bodies or attachments, send mail, or permanently delete anything.

## Where data is stored

- Your Google refresh token, and the OAuth client ID and secret you supplied, are stored in the macOS Keychain on your Mac, readable only by InboxBadge, on this device only.
- Sender, subject and counts are held in memory while the app runs. They are not written to disk by InboxBadge. macOS itself may keep the text of a notification in Notification Center.
- The app's log contains counts and status messages, never mail content or addresses.

## Where data is sent

Only between your Mac and Google's APIs (`gmail.googleapis.com`, `oauth2.googleapis.com`, `accounts.google.com`). Nothing is sent to the developer or to any third party. The developer cannot see your accounts, mail or usage.

## Google API Services User Data Policy

InboxBadge's use and transfer to any other app of information received from Google APIs adheres to the [Google API Services User Data Policy](https://developers.google.com/terms/api-services-user-data-policy), including the Limited Use requirements. Data from Gmail is used only to provide the unread counts, lists, notifications and actions described here. It is not used for advertising, not sold, not shared, and no human reads it.

## Your choices

- Remove an account in InboxBadge's Settings: InboxBadge asks Google to revoke its token and deletes the Keychain entry.
- You can also revoke access at any time in your Google Account under Security → Third-party apps with account access.
- Deleting the app and its Keychain items removes everything it stored.

## Changes and contact

Changes to this policy are published in the project's repository, which shows their history. Questions or issues: [github.com/parth-d/InboxBadge/issues](https://github.com/parth-d/InboxBadge/issues).
