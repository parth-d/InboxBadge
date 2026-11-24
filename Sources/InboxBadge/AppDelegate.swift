import AppKit
import Observation
import SwiftUI
import InboxUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    init(model: AppModel) {
        self.model = model
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        item.button?.imagePosition = .imageLeading
        statusItem = item
        let host = NSHostingController(rootView: PopoverView(model: model))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
        popover.behavior = .transient
        track()
    }

    private func track() {
        withObservationTracking {
            refreshIcon()
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func refreshIcon() {
        let unread = model.totalUnread
        let needsSignIn = model.accounts.contains { $0.status == .reauthRequired }
        statusItem?.button?.title = unread > 0 ? " \(unread)" : ""
        statusItem?.button?.image = MenuBarIcon.image(dot: needsSignIn ? .systemOrange : (unread > 0 ? .systemRed : nil))
        statusItem?.button?.setAccessibilityLabel(unread > 0 ? "InboxBadge, \(unread) unread" : "InboxBadge")
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            model.popoverWillOpen()
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

enum MenuBarIcon {
    static func image(dot: NSColor?) -> NSImage? {
        let configuration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)
        guard let base = NSImage(systemSymbolName: "envelope", accessibilityDescription: "InboxBadge")?
            .withSymbolConfiguration(configuration) else { return nil }
        guard let dot else {
            base.isTemplate = true
            return base
        }
        let size = NSSize(width: base.size.width + 3, height: base.size.height + 3)
        let image = NSImage(size: size, flipped: false) { rect in
            base.draw(in: NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height))
            NSColor.labelColor.setFill()
            NSRect(x: 0, y: 0, width: base.size.width, height: base.size.height).fill(using: .sourceIn)
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.maxX - 7, y: rect.maxY - 7, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
