import AppKit
import Network
import InboxCore

final class SystemEnvironment: PollEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var asleep = false
    private var networkUp = true
    private let monitor = NWPathMonitor()
    private var observers: [NSObjectProtocol] = []
    var onWake: (@Sendable () -> Void)?

    var displaysAsleep: Bool { lock.withLock { asleep } }
    var lowPower: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    init() {
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.asleep = true }
        })
        observers.append(center.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.lock.withLock { self?.asleep = false }
            self?.onWake?()
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.onWake?()
        })
        monitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let up = path.status == .satisfied
            let recovered = self.lock.withLock { () -> Bool in
                defer { self.networkUp = up }
                return up && !self.networkUp
            }
            if recovered { self.onWake?() }
        }
        monitor.start(queue: DispatchQueue(label: "io.github.parth-d.InboxBadge.path"))
    }
}
