import AppKit
import SwiftUI
import InboxCore
import InboxUI

let now = Date(timeIntervalSince1970: 1_700_000_000)

func thread(_ n: Int, _ from: String, _ subject: String, ageSeconds: Double) -> UnreadThread {
    UnreadThread(id: "t\(n)", messageID: "m\(n)", from: from, subject: subject, date: now.addingTimeInterval(-ageSeconds))
}

let personal = AccountView(
    email: "alex@example.com", label: "Personal", unread: 3,
    threads: [thread(1, "Maya Chen <maya@example.org>", "Dinner on Friday? I booked the table at the new place", ageSeconds: 240),
              thread(2, "Bank Alerts <alerts@bank.example>", "Your statement is ready", ageSeconds: 5400),
              thread(3, "\"Okafor, Daniel\" <d@example.net>", "Re: Moving boxes", ageSeconds: 90000)],
    status: .ok)
let work = AccountView(
    email: "alex.rivera@company.example", label: "Work", unread: 12,
    threads: [thread(4, "Build Bot <ci@company.example>", "Pipeline failed on main (3 jobs)", ageSeconds: 600),
              thread(5, "Priya N <priya@company.example>", "Design review notes and the follow-ups we agreed", ageSeconds: 7200),
              thread(6, "Calendar <cal@company.example>", "Invitation: Weekly sync", ageSeconds: 14000),
              thread(7, "Support <help@vendor.example>", "Ticket #48213 updated", ageSeconds: 200000),
              thread(8, "Finance <fin@company.example>", "Expense report approved", ageSeconds: 600000)],
    status: .ok)
let expired = AccountView(email: "old.mail@example.com", label: "", unread: 0, threads: [], status: .reauthRequired)
let quiet = AccountView(email: "side@example.com", label: "Side projects", unread: 0, threads: [], status: .ok)

@MainActor func render(_ scheme: ColorScheme, accounts: [AccountView], to path: String) {
    let background: Color = scheme == .dark ? Color(white: 0.16) : Color(white: 0.96)
    let view = PopoverContent(accounts: accounts, actions: .none, now: now)
        .background(background)
        .environment(\.colorScheme, scheme)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
        print("render failed: \(path)"); return
    }
    try? png.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
_ = NSApplication.shared
MainActor.assumeIsolated {
    render(.light, accounts: [personal, work, expired, quiet], to: "\(outDir)/popover-light.png")
    render(.dark, accounts: [personal, work, expired, quiet], to: "\(outDir)/popover-dark.png")
    render(.light, accounts: [], to: "\(outDir)/popover-empty.png")
}
