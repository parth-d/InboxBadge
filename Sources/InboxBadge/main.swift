import AppKit

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let model = AppModel()
    let delegate = AppDelegate(model: model)
    app.delegate = delegate
    app.run()
}
