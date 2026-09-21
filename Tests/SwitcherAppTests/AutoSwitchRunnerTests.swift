import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// The gate between a policy decision and a credential rewrite.  Everything
/// here is about the switches that must NOT happen: the app rewriting logins on
/// its own is the worst thing it can get wrong.
@Suite("Automatic switching in the app")
@MainActor
struct AutoSwitchRunnerTests {
    static let accounts = [
        PolicyAccount(name: "perso2", order: 0, sessionPercent: 100, weeklyPercent: 50),
        PolicyAccount(name: "pro", order: 1, sessionPercent: 10, weeklyPercent: 20),
    ]
    static let decision = PolicyDecision.move(to: "pro", "perso2 hit its session limit",
                                              cause: "session limit")

    /// Arms a world in `mode` and waits out the refresh the mode change starts,
    /// so nothing lands on the assertions afterwards.
    static func armed(_ mode: SwitchMode, items: [String: Data]? = nil) async throws -> AppWorld {
        let world = try AppWorld(items: items)
        world.armUsage()
        await world.model.reloadSlots()
        world.model.mode = mode
        if mode != .manual {
            _ = await settle { world.model.policyStatus != nil }
        }
        return world
    }

    @Test("Manual switches nothing, whatever the policy says")
    func manualRefuses() async throws {
        let world = try await Self.armed(.manual)
        defer { world.cleanUp() }

        world.model.act(on: Self.decision, accounts: Self.accounts)
        #expect(world.model.policyStatus == nil)
        #expect(world.model.switchingTo == nil)
        #expect(world.marker() == "perso2")
        #expect(world.keychain.writeCount == 0)
    }

    @Test("an action or a sweep in flight holds the switch back and says which")
    func busyRefuses() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }

        world.model.busySlot = "pro"
        world.model.act(on: Self.decision, accounts: Self.accounts)
        #expect(world.model.policyStatus?.isHolding == true)
        #expect(world.model.policyStatus?.detail?.contains("another action is running") == true)
        #expect(world.model.switchingTo == nil)
        world.model.busySlot = nil

        world.model.sweepTask = Task {}
        world.model.act(on: Self.decision, accounts: Self.accounts)
        #expect(world.model.policyStatus?.detail?.contains("Refresh all is running") == true)
        world.model.sweepTask = nil
        #expect(world.keychain.writeCount == 0)
    }

    @Test("a panel waiting for an answer holds it back too")
    func confirmingRefuses() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }

        world.model.beginAddAccount()
        world.model.act(on: Self.decision, accounts: Self.accounts)
        #expect(world.model.policyStatus?.detail?.contains("a panel is waiting for an answer") == true)
        #expect(world.model.switchingTo == nil)
        world.model.cancelLogin()
    }

    /// An active account that can still work: nothing is on fire, so the cool-off
    /// is the whole point — it damps flapping between two healthy accounts.
    static let healthyAccounts = [
        PolicyAccount(name: "perso2", order: 0, sessionPercent: 40, weeklyPercent: 60),
        PolicyAccount(name: "pro", order: 1, sessionPercent: 10, weeklyPercent: 20),
    ]

    @Test("inside the cool-off it waits, and says how long")
    func coolOffRefuses() async throws {
        let world = try await Self.armed(.balance)
        defer { world.cleanUp() }

        let now = Date()
        world.model.lastSwitchAt = now.addingTimeInterval(-60)
        world.model.act(on: PolicyDecision.move(to: "pro", "pro has more room", cause: "balance"),
                        accounts: Self.healthyAccounts, now: now)
        #expect(world.model.policyStatus?.isHolding == true)
        #expect(world.model.policyStatus?.detail?.contains("another switch is allowed in") == true)
        #expect(world.model.switchingTo == nil)
        #expect(world.keychain.writeCount == 0)
    }

    /// An account that cannot continue does not wait out a cool-off: a session
    /// limit lasts hours, so waiting buys nothing and costs a refusing CLI.
    /// The other brakes — the hourly cap, busy, the failure latch — still apply.
    @Test("a stuck account switches even inside the cool-off")
    func coolOffLiftedWhenStuck() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }

        let now = Date()
        world.model.lastSwitchAt = now.addingTimeInterval(-60)
        world.model.act(on: Self.decision, accounts: Self.accounts, now: now)
        #expect(world.model.switchingTo == "pro")
        #expect(world.model.policyStatus?.isHolding != true)
    }

    @Test("past the hourly cap it stops until the hour rolls")
    func cappedRefuses() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }

        let now = Date()
        for minutes in [5, 10, 20, 30] {
            world.model.autoState.recordSwitch(at: now.addingTimeInterval(-60 * Double(minutes)))
        }
        world.model.act(on: Self.decision, accounts: Self.accounts, now: now)
        #expect(world.model.policyStatus?.detail?.contains("4 automatic switches in the last hour") == true)
        #expect(world.model.switchingTo == nil)
        #expect(world.keychain.writeCount == 0)
    }

    @Test("an account that cannot take over is not switched to")
    func unusableTargetRefuses() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }

        let stuck = [Self.accounts[0],
                     PolicyAccount(name: "pro", order: 1, sessionPercent: 100, weeklyPercent: 100)]
        world.model.act(on: Self.decision, accounts: stuck)
        #expect(world.model.policyStatus?.detail?.contains("pro cannot take over right now") == true)
        #expect(world.model.switchingTo == nil)
        #expect(world.keychain.writeCount == 0)
    }

    @Test("with nothing in the way it switches, once, and counts it against the cap")
    func actsWhenNothingHoldsItBack() async throws {
        let world = try await Self.armed(.failover)
        defer { world.cleanUp() }
        let now = Date()

        world.model.act(on: Self.decision, accounts: Self.accounts, now: now)
        #expect(world.model.policyStatus?.detail == "switching to pro — perso2 hit its session limit")
        #expect(world.model.switchingTo == "pro")
        #expect(world.model.autoState.count(now: now) == 1)
        #expect(await settle { world.model.busySlot == nil })

        #expect(world.marker() == "pro")
        // The footer says "switched …" until the next pass replaces it with
        // "staying …"; either way an armed mode that acted is not holding.
        #expect(world.model.policyStatus?.isHolding == false)
        #expect(world.logText().contains("switched perso2 → pro"))
        #expect(world.model.autoState.consecutiveFailures == 0)
        #expect(world.model.lastSwitchAt != nil)
        #expect(world.logText().contains("perso2 hit its session limit"))
        await world.expectNothingStuck()
    }

    @Test("two failed switches in a row put the mode back to Manual")
    func twoFailuresDisarm() async throws {
        var items = AppWorld.defaultItems()
        items[AppWorld.prefix + "pro"] = Data("{\"credentials\":".utf8)
        let world = try await Self.armed(.failover, items: items)
        defer { world.cleanUp() }

        world.model.automaticSwitch(to: "pro", reason: "perso2 hit its session limit")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.mode == .failover)
        #expect(world.model.autoState.consecutiveFailures == 1)
        #expect(world.model.autoState.isStopped == false)
        #expect(world.model.policyStatus?.detail == "last switch failed — one more stops it")
        #expect(world.model.switchingTo == nil)

        world.model.automaticSwitch(to: "pro", reason: "perso2 hit its session limit")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.mode == .manual)
        #expect(world.model.autoState.isStopped)
        #expect(world.model.policyStatus == nil)
        #expect(world.logText().contains("two in a row, back to Manual"))
        #expect(world.marker() == "perso2")
        await world.expectNothingStuck()

        // Once it has stopped, the gate refuses even a perfect decision.
        world.model.isDisarming = true
        world.model.mode = .failover
        world.model.isDisarming = false
        world.model.act(on: Self.decision, accounts: Self.accounts)
        #expect(world.model.policyStatus?.detail == "automatic switching is off after failed switches")
        #expect(world.model.switchingTo == nil)

        // Choosing the mode again is deliberate, so it re-arms.
        world.model.mode = .manual
        world.model.mode = .failover
        #expect(world.model.autoState.isStopped == false)
    }

    @Test("the mode picker's side note is the only warning, and Manual has none")
    func modeChangesAreLogged() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.armUsage()
        await world.model.reloadSlots()

        world.model.mode = .balance
        #expect(world.logText().contains("Balance armed — the app may switch accounts on its own"))
        world.model.mode = .manual
        #expect(world.logText().contains("automatic switching off"))
        _ = await settle { world.model.policyStatus == nil }
    }
}
