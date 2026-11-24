import Foundation
import Testing
@testable import InboxCore

struct EnergyTests {
    private let policy = EnergyPolicy()

    @Test func baselineIntervalIsSixtySeconds() {
        #expect(policy.interval(displaysAsleep: false, lowPower: false, failures: 0) == 60)
    }

    @Test func displaysAsleepStretchesFiveFold() {
        #expect(policy.interval(displaysAsleep: true, lowPower: false, failures: 0) == 300)
    }

    @Test func lowPowerDoubles() {
        #expect(policy.interval(displaysAsleep: false, lowPower: true, failures: 0) == 120)
        #expect(policy.interval(displaysAsleep: true, lowPower: true, failures: 0) == 600)
    }

    @Test func backoffDoublesPerFailureAndCaps() {
        #expect(policy.interval(displaysAsleep: false, lowPower: false, failures: 1) == 120)
        #expect(policy.interval(displaysAsleep: false, lowPower: false, failures: 3) == 480)
        #expect(policy.interval(displaysAsleep: false, lowPower: false, failures: 5) == 900)
        #expect(policy.interval(displaysAsleep: false, lowPower: false, failures: 50) == 900)
    }

    @Test func backoffNeverShortensAnAlreadyLongInterval() {
        #expect(EnergyPolicy(baseInterval: 120).interval(displaysAsleep: true, lowPower: true, failures: 3) == 1200)
        #expect(policy.interval(displaysAsleep: true, lowPower: true, failures: 3) == 900)
    }

    @Test func intervalNeverBelowMinimum() {
        #expect(EnergyPolicy(baseInterval: 5).interval(displaysAsleep: false, lowPower: false, failures: 0) == 30)
    }

    @Test func toleranceIsAtLeastFifteenPercent() {
        for interval in [30.0, 60, 300, 900] { #expect(policy.tolerance(for: interval) >= interval * 0.15) }
    }
}

struct PollLoopTests {
    private func rig(env: FakeEnvironment = FakeEnvironment(), tick: @escaping @Sendable (Int) async throws -> Void)
        -> (PollLoop, Tally, Tally) {
        let ticks = Tally(), sleeps = Tally()
        let loop = PollLoop(policy: EnergyPolicy(), environment: env,
                            sleeper: { seconds, tolerance in
                                sleeps.record(seconds)
                                sleeps.record(tolerance)
                                sleeps.hit()
                                try? await Task.sleep(for: .seconds(3600))
                            },
                            tick: { ticks.hit(); try await tick(ticks.count) })
        return (loop, ticks, sleeps)
    }

    @Test func ticksOnStartThenSleepsWithTolerance() async {
        let (loop, ticks, sleeps) = rig { _ in }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        #expect(ticks.count == 1)
        #expect(sleeps.recorded == [60, 12])
        await loop.stop()
    }

    @Test func pokeWakesTheSleepImmediately() async {
        let (loop, ticks, sleeps) = rig { _ in }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        await loop.poke()
        #expect(await waitUntil { ticks.count == 2 && sleeps.count == 2 })
        await loop.stop()
    }

    @Test func pokeDuringATickIsNotLost() async {
        let holder = LoopHolder()
        let (loop, ticks, sleeps) = rig { n in if n == 1 { await holder.loop?.poke() } }
        holder.loop = loop
        await loop.start()
        #expect(await waitUntil { ticks.count == 2 && sleeps.count == 1 })
        await loop.stop()
    }

    @Test func failuresBackOffAndSuccessResets() async {
        let (loop, ticks, sleeps) = rig { n in if n <= 2 { throw URLError(.notConnectedToInternet) } }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        #expect(sleeps.recorded[0] == 120)
        await loop.poke()
        #expect(await waitUntil { sleeps.count == 2 })
        #expect(sleeps.recorded[2] == 240)
        await loop.poke()
        #expect(await waitUntil { sleeps.count == 3 })
        #expect(sleeps.recorded[4] == 60)
        #expect(ticks.count == 3)
        await loop.stop()
    }

    @Test func changingThePolicyAppliesToTheNextSleep() async {
        let (loop, ticks, sleeps) = rig { _ in }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        await loop.setPolicy(EnergyPolicy(baseInterval: 300))
        #expect(await waitUntil { sleeps.count == 2 })
        #expect(sleeps.recorded[2] == 300)
        #expect(ticks.count == 2)
        await loop.setPolicy(EnergyPolicy(baseInterval: 300))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ticks.count == 2)
        await loop.stop()
    }

    @Test func displaysAsleepUsesLongerInterval() async {
        let env = FakeEnvironment()
        env.displaysAsleep = true
        let (loop, _, sleeps) = rig(env: env) { _ in }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        #expect(sleeps.recorded[0] == 300)
        await loop.stop()
    }

    @Test func reauthRequiredEndsTheLoop() async {
        let (loop, ticks, sleeps) = rig { _ in throw InboxError.reauthRequired }
        await loop.start()
        #expect(await waitUntil { ticks.count == 1 })
        await loop.poke()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ticks.count == 1)
        #expect(sleeps.count == 0)
    }

    @Test func stopHaltsTicking() async {
        let (loop, ticks, sleeps) = rig { _ in }
        await loop.start()
        #expect(await waitUntil { sleeps.count == 1 })
        await loop.stop()
        await loop.poke()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(ticks.count == 1)
    }
}

final class LoopHolder: @unchecked Sendable { var loop: PollLoop? }
