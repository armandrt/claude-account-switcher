import Foundation
import Testing
@testable import SwitcherCore

/// The rules between a decision and a real switch: who may act, how often, and
/// what stops it for good.
@Suite("Automatic switching")
struct AutoSwitchTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    let gate = AutoSwitchGate()

    /// perso2 is out of session; pro has three days of weekly quota left.
    static var accounts: [PolicyAccount] {
        [PolicyAccount(name: "perso2", order: 0, sessionPercent: 100, weeklyPercent: 71,
                       weeklyResetsAt: inHours(10)),
         PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 20,
                       weeklyResetsAt: inHours(72))]
    }

    func verdict(mode: SwitchMode = .failover,
                 accounts: [PolicyAccount] = AutoSwitchTests.accounts,
                 active: String? = "perso2",
                 conditions: AutoSwitchConditions = AutoSwitchConditions(),
                 state: AutoSwitchState = AutoSwitchState(),
                 now: Date = AutoSwitchTests.now,
                 lastSwitchAt: Date? = nil) -> AutoSwitchGate.Verdict {
        let decision = PolicyEngine().evaluate(mode: mode, accounts: accounts, active: active,
                                               now: now, lastSwitchAt: lastSwitchAt)
        return gate.verdict(for: decision, mode: mode, accounts: accounts, active: active,
                            conditions: conditions, state: state, now: now,
                            lastSwitchAt: lastSwitchAt)
    }

    func held(_ verdict: AutoSwitchGate.Verdict) -> String? {
        if case .hold(let refusal) = verdict { return refusal.text }
        return nil
    }

    @Test("a blocked active account switches, in Failover and in Balance")
    func actsWhenBlocked() {
        for mode in [SwitchMode.failover, .balance] {
            #expect(verdict(mode: mode).target == "pro")
        }
    }

    @Test("Manual never acts, whatever the numbers say")
    func manualNeverActs() {
        #expect(verdict(mode: .manual).target == nil)
        #expect(held(verdict(mode: .manual))?.contains("Manual") == true)
        // Even handed a decision from another mode, the gate refuses in Manual.
        let decision = PolicyDecision.move(to: "pro", "pro is fresher", cause: "session limit")
        let forced = gate.verdict(for: decision, mode: .manual, accounts: Self.accounts,
                                  active: "perso2", conditions: AutoSwitchConditions(),
                                  state: AutoSwitchState(), now: Self.now, lastSwitchAt: nil)
        #expect(forced.target == nil)
    }

    @Test("nothing happens while the app is busy")
    func busyHolds() {
        let cases: [(AutoSwitchConditions, String)] = [
            (AutoSwitchConditions(isSweeping: true), "Refresh all"),
            (AutoSwitchConditions(isBusy: true), "another action"),
            (AutoSwitchConditions(isConfirming: true), "panel"),
        ]
        for (conditions, word) in cases {
            let result = verdict(conditions: conditions)
            #expect(result.target == nil)
            #expect(held(result)?.contains(word) == true)
        }
        #expect(verdict(conditions: AutoSwitchConditions()).target == "pro")
    }

    /// Accounts that can all still run: nothing here is blocked.
    static var running: [PolicyAccount] {
        [PolicyAccount(name: "perso2", order: 0, sessionPercent: 20, weeklyPercent: 94,
                       weeklyResetsAt: inHours(10)),
         PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 20,
                       weeklyResetsAt: inHours(72))]
    }

    @Test("the cool-off holds an ordinary switch and lifts for an account that cannot continue")
    func coolOff() {
        // PLAN §4.3 is explicit: at most once every 15 min, "unless the current
        // account can't continue". perso2 is out of session quota, and a session
        // window lasts hours — waiting the cool-off out buys nothing but fifteen
        // minutes of a Claude Code that refuses work. The gate used to apply the
        // cool-off here anyway, which cancelled the policy's own exception.
        #expect(verdict(lastSwitchAt: Self.now.addingTimeInterval(-5 * 60)).target == "pro")
        #expect(verdict(mode: .balance,
                        lastSwitchAt: Self.now.addingTimeInterval(-5 * 60)).target == "pro")

        // An account that can still run waits its fifteen minutes out. The decision
        // is handed in directly: the engine would refuse this one on its own.
        let decision = PolicyDecision.move(to: "pro", "pro is fresher", cause: "balance")
        let recent = gate.verdict(for: decision, mode: .balance, accounts: Self.running,
                                  active: "perso2", conditions: AutoSwitchConditions(),
                                  state: AutoSwitchState(), now: Self.now,
                                  lastSwitchAt: Self.now.addingTimeInterval(-5 * 60))
        #expect(recent.target == nil)
        #expect(held(recent)?.contains("allowed in 10 min") == true)

        // And once it is out, it goes.
        #expect(verdict(mode: .balance, accounts: Self.running,
                        lastSwitchAt: Self.now.addingTimeInterval(-16 * 60)).target == "pro")
    }

    @Test("lifting the cool-off lifts nothing else")
    func blockedStillObeysTheRest() {
        let recent = Self.now.addingTimeInterval(-60)
        var capped = AutoSwitchState()
        for minutes in [50.0, 40, 30, 20] {
            capped.recordSwitch(at: Self.now.addingTimeInterval(-minutes * 60))
        }
        #expect(verdict(state: capped, lastSwitchAt: recent).target == nil)
        #expect(verdict(conditions: AutoSwitchConditions(isBusy: true),
                        lastSwitchAt: recent).target == nil)
        var stopped = AutoSwitchState()
        stopped.recordFailure()
        stopped.recordFailure()
        #expect(verdict(state: stopped, lastSwitchAt: recent).target == nil)
        // The target is still re-checked, blocked active account or not.
        let decision = PolicyDecision.move(to: "pro", "pro takes over", cause: "session limit")
        let spent = gate.verdict(for: decision, mode: .failover,
                                 accounts: [Self.accounts[0],
                                            PolicyAccount(name: "pro", order: 1, sessionPercent: 0,
                                                          weeklyPercent: 100)],
                                 active: "perso2", conditions: AutoSwitchConditions(),
                                 state: AutoSwitchState(), now: Self.now, lastSwitchAt: recent)
        #expect(spent.target == nil)
    }

    @Test("a switch stamp from a clock that moved does not turn switching off")
    func futureSwitchStamp() {
        let decision = PolicyDecision.move(to: "pro", "pro is fresher", cause: "balance")
        func check(_ lastSwitchAt: Date) -> AutoSwitchGate.Verdict {
            gate.verdict(for: decision, mode: .balance, accounts: Self.running, active: "perso2",
                         conditions: AutoSwitchConditions(), state: AutoSwitchState(),
                         now: Self.now, lastSwitchAt: lastSwitchAt)
        }
        // A minute ahead is the cool-off; a year ahead is a wrong clock, and holding
        // for it would leave automatic switching off until the clock caught up.
        #expect(check(Self.now.addingTimeInterval(60)).target == nil)
        #expect(check(Self.now.addingTimeInterval(365 * 86_400)).target == "pro")
    }

    @Test("an active account that is not on the list keeps the cool-off")
    func unknownActiveKeepsTheCoolOff() {
        // "active" naming a slot that has gone is not evidence that work is blocked,
        // and the engine's answer here is a switch: without the check it would be a
        // credential rewrite every pass.
        let decision = PolicyDecision.move(to: "pro", "no active account", cause: "no active account")
        let stale = gate.verdict(for: decision, mode: .failover, accounts: [Self.accounts[1]],
                                 active: "gone", conditions: AutoSwitchConditions(),
                                 state: AutoSwitchState(), now: Self.now,
                                 lastSwitchAt: Self.now.addingTimeInterval(-60))
        #expect(stale.target == nil)
        #expect(held(stale)?.contains("allowed in") == true)
        // With no active account at all there is no work to protect.
        let none = gate.verdict(for: decision, mode: .failover, accounts: [Self.accounts[1]],
                                active: nil, conditions: AutoSwitchConditions(),
                                state: AutoSwitchState(), now: Self.now,
                                lastSwitchAt: Self.now.addingTimeInterval(-60))
        #expect(none.target == "pro")
    }

    @Test("four automatic switches an hour is the cap")
    func hourlyCap() {
        var state = AutoSwitchState()
        for minutes in [50.0, 40, 30, 20] {
            state.recordSwitch(at: Self.now.addingTimeInterval(-minutes * 60))
        }
        #expect(state.count(now: Self.now) == 4)
        let capped = verdict(state: state)
        #expect(capped.target == nil)
        #expect(held(capped)?.contains("cap") == true)

        // The oldest falls out of the window and the fifth is allowed.
        let later = Self.now.addingTimeInterval(11 * 60)
        #expect(state.count(now: later) == 3)
        #expect(verdict(state: state, now: later).target == "pro")
    }

    @Test("the cap looks back an hour, not at every switch since launch")
    func capWindowPrunes() {
        var state = AutoSwitchState()
        state.recordSwitch(at: Self.now.addingTimeInterval(-7200))
        state.recordSwitch(at: Self.now)
        #expect(state.switches.count == 1)
        #expect(state.count(now: Self.now) == 1)
    }

    @Test("two failed switches in a row stop it; a success clears the count")
    func twoFailuresStop() {
        var state = AutoSwitchState()
        let one = state.recordFailure()
        #expect(one == false)
        #expect(state.isStopped == false)
        state.recordSuccess()
        #expect(state.consecutiveFailures == 0)

        let again = state.recordFailure()
        let second = state.recordFailure()
        // It stops once, not on every failure after it.
        let third = state.recordFailure()
        #expect(again == false)
        #expect(second)
        #expect(third == false)
        #expect(state.isStopped)

        let stopped = verdict(state: state)
        #expect(stopped.target == nil)
        #expect(held(stopped)?.contains("off after failed switches") == true)

        state.rearm()
        #expect(state.isStopped == false)
        #expect(verdict(state: state).target == "pro")
    }

    @Test("the target is checked again: healthy, switchable, and not out of quota itself")
    func targetIsCheckedAgain() {
        let decision = PolicyDecision.move(to: "pro", "pro takes over", cause: "session limit")
        func check(_ pro: PolicyAccount) -> AutoSwitchGate.Verdict {
            gate.verdict(for: decision, mode: .failover,
                         accounts: [Self.accounts[0], pro], active: "perso2",
                         conditions: AutoSwitchConditions(), state: AutoSwitchState(),
                         now: Self.now, lastSwitchAt: nil)
        }
        #expect(check(Self.accounts[1]).target == "pro")
        #expect(check(PolicyAccount(name: "pro", order: 1, isUsable: false)).target == nil)
        #expect(check(PolicyAccount(name: "pro", order: 1, sessionPercent: 0,
                                    weeklyPercent: 100)).target == nil)
        #expect(check(PolicyAccount(name: "pro", order: 1, sessionPercent: 96,
                                    weeklyPercent: 10)).target == nil)
        #expect(held(check(PolicyAccount(name: "pro", order: 1, isUsable: false)))?
            .contains("pro cannot take over") == true)
        // A target that is not in the list at all is refused too.
        let missing = gate.verdict(for: decision, mode: .failover, accounts: [Self.accounts[0]],
                                   active: "perso2", conditions: AutoSwitchConditions(),
                                   state: AutoSwitchState(), now: Self.now, lastSwitchAt: nil)
        #expect(missing.target == nil)
    }

    @Test("an account that can still run is left alone")
    func stayingActsOnNothing() {
        let running = [PolicyAccount(name: "perso2", order: 0, sessionPercent: 20, weeklyPercent: 30,
                                     weeklyResetsAt: Self.inHours(10)),
                       PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 20,
                                     weeklyResetsAt: Self.inHours(72))]
        let result = verdict(accounts: running)
        #expect(result.target == nil)
        #expect(held(result)?.contains("nothing to switch to") == true)
    }

    @Test("Balance acts on the water-filling rule, Failover does not")
    func balanceFollowsUrgency() {
        let perso = PolicyAccount(name: "perso", order: 0, sessionPercent: 34, weeklyPercent: 94,
                                  weeklyResetsAt: Self.inHours(10))
        let pro = PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 20,
                                weeklyResetsAt: Self.inHours(72))
        #expect(verdict(mode: .balance, accounts: [perso, pro], active: "perso").target == "pro")
        #expect(verdict(mode: .failover, accounts: [perso, pro], active: "perso").target == nil)
    }

    @Test("what held it back is written down with the decision")
    func heldReasonIsLogged() {
        var log = SwitchLog()
        let decision = PolicyDecision.move(to: "pro", "pro takes over", cause: "session limit")
        let refusal = AutoSwitchGate.Refusal.capped(4)
        let written = log.record(decision, from: "perso2", held: refusal.text, at: Self.now)
        // Still one line per repeated decision, held reason included.
        let repeated = log.record(decision, from: "perso2", held: refusal.text,
                                  at: Self.now.addingTimeInterval(120))
        #expect(written)
        #expect(repeated == false)
        #expect(log.entries.first?.text
                == "would switch perso2 → pro: session limit — 4 automatic switches in the last hour is the cap")
    }
}
