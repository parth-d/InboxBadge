import Foundation

public protocol PollEnvironment: Sendable {
    var displaysAsleep: Bool { get }
    var lowPower: Bool { get }
}

public struct EnergyPolicy: Equatable, Sendable {
    public static let minimumInterval: TimeInterval = 15
    public static let toleranceFraction = 0.2

    public var baseInterval: TimeInterval
    public var maxBackoff: TimeInterval

    public init(baseInterval: TimeInterval = 60, maxBackoff: TimeInterval = 900) {
        self.baseInterval = baseInterval
        self.maxBackoff = maxBackoff
    }

    public func interval(displaysAsleep: Bool, lowPower: Bool, failures: Int) -> TimeInterval {
        var t = max(baseInterval, Self.minimumInterval)
        if displaysAsleep { t *= 5 }
        if lowPower { t *= 2 }
        if failures > 0 {
            t = min(t * pow(2, Double(min(failures, 10))), max(maxBackoff, t))
        }
        return t
    }

    public func tolerance(for interval: TimeInterval) -> TimeInterval {
        interval * Self.toleranceFraction
    }
}

public actor PollLoop {
    public typealias Sleeper = @Sendable (_ seconds: TimeInterval, _ tolerance: TimeInterval) async -> Void

    public static let systemSleeper: Sleeper = { seconds, tolerance in
        try? await Task.sleep(for: .seconds(seconds), tolerance: .seconds(tolerance))
    }

    private var policy: EnergyPolicy
    private let environment: PollEnvironment
    private let tick: @Sendable () async throws -> Void
    private let sleeper: Sleeper
    private var task: Task<Void, Never>?
    private var sleeping: Task<Void, Never>?
    private var pokePending = false
    private var failures = 0

    public init(policy: EnergyPolicy, environment: PollEnvironment, sleeper: @escaping Sleeper = PollLoop.systemSleeper,
                tick: @escaping @Sendable () async throws -> Void) {
        self.policy = policy
        self.environment = environment
        self.sleeper = sleeper
        self.tick = tick
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await self.run() }
    }

    public func stop() {
        task?.cancel()
        sleeping?.cancel()
        task = nil
    }

    public func setPolicy(_ newPolicy: EnergyPolicy) {
        guard newPolicy != policy else { return }
        policy = newPolicy
        poke()
    }

    public func poke() {
        if let sleeping { sleeping.cancel() } else { pokePending = true }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                try await tick()
                failures = 0
            } catch InboxError.reauthRequired {
                task = nil
                return
            } catch {
                failures += 1
            }
            if pokePending { pokePending = false; continue }
            let interval = policy.interval(displaysAsleep: environment.displaysAsleep,
                                           lowPower: environment.lowPower, failures: failures)
            let tolerance = policy.tolerance(for: interval)
            let sleeper = self.sleeper
            let nap = Task { await sleeper(interval, tolerance) }
            sleeping = nap
            await nap.value
            sleeping = nil
        }
    }
}
