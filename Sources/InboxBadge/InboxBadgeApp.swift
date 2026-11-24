import SwiftUI

@main
struct InboxBadgeApp: App {
    private let model = AppModel()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(model: model)
        } label: {
            Image(systemName: "envelope")
            if model.totalUnread > 0 { Text("\(model.totalUnread)") }
        }
        .menuBarExtraStyle(.window)

        Window("InboxBadge Settings", id: "settings") {
            SettingsView(model: model)
        }
        .windowResizability(.contentSize)
    }
}
