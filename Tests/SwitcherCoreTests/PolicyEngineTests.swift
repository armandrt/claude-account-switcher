import Foundation
import Testing
@testable import SwitcherCore

@Suite("Policy engine")
struct PolicyEngineTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    /// perso: 6% weekly left, ~10 h to reset (0.6 %/h); pro: 80% with 3 days (1.11 %/h).
    @Test("the worked example picks pro")
    func workedExample() {
        let perso = PolicyAccount(name: "perso", order: 0, sessionPercent: 34, weeklyPercent: 94,
                                  weeklyResetsAt: Self.inHours(10))
        let pro = PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 20,
                                weeklyResetsAt: Self.inHours(72))
        #expect(abs(perso.urgency(now: Self.now) - 0.6) < 0.001)
        #expect(abs(pro.urgency(now: Self.now) - 1.111) < 0.001)

        let decision = PolicyEngine().evaluate(mode: .balance, accounts: [perso, pro],
                                               active: "perso", now: Self.now)
        #expect(decision.target == "pro")
        #expect(decision.reason.contains("1.11"))
    }

    @Test("25% hysteresis keeps the current account when the gain is small")
    func hysteresis() {
        let engine = PolicyEngine()
        let active = PolicyAccount(name: "a", sessionPercent: 0, weeklyPercent: 50,
                                   weeklyResetsAt: Self.inHours(10))       // 5.0 %/h
        let close = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 38,
                                  weeklyResetsAt: Self.inHours(10))        // 6.2 %/h, 24% better
        #expect(engine.evaluate(mode: .balance, accounts: [active, close],
                                active: "a", now: Self.now).target == nil)

        let clear = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 37,
                                  weeklyResetsAt: Self.inHours(10))        // 6.3 %/h, 26% better
        #expect(engine.evaluate(mode: .balance, accounts: [active, clear],
                                active: "a", now: Self.now).target == "b")
    }

    @Test("a switch less than 15 minutes ago is held back")
    func minimumInterval() {
        let engine = PolicyEngine()
        let active = PolicyAccount(name: "a", sessionPercent: 0, weeklyPercent: 90,
                                   weeklyResetsAt: Self.inHours(10))
        let better = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                   weeklyResetsAt: Self.inHours(10))

        let recent = engine.evaluate(mode: .balance, accounts: [active, better], active: "a",
                                     now: Self.now, lastSwitchAt: Self.now.addingTimeInterval(-600))
        #expect(recent.target == nil)
        #expect(recent.reason.contains("15 min ago"))

        let older = engine.evaluate(mode: .balance, accounts: [active, better], active: "a",
                                    now: Self.now, lastSwitchAt: Self.now.addingTimeInterval(-1200))
        #expect(older.target == "b")
    }

    @Test("a stuck account switches immediately, interval or not")
    func stuckIgnoresInterval() {
        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100, weeklyPercent: 90,
                                  weeklyResetsAt: Self.inHours(10))
        let free = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                 weeklyResetsAt: Self.inHours(10))
        for mode in [SwitchMode.failover, .balance] {
            let decision = engine.evaluate(mode: mode, accounts: [stuck, free], active: "a",
                                           now: Self.now, lastSwitchAt: Self.now.addingTimeInterval(-10))
            #expect(decision.target == "b")
            #expect(decision.reason.contains("session limit"))
        }
    }

    @Test("failover stays put while the active account can still run")
    func failoverStaysUntilBlocked() {
        let engine = PolicyEngine()
        let tired = PolicyAccount(name: "a", sessionPercent: 99, weeklyPercent: 99,
                                  weeklyResetsAt: Self.inHours(10))
        let fresh = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 0,
                                  weeklyResetsAt: Self.inHours(10))
        #expect(engine.evaluate(mode: .failover, accounts: [tired, fresh],
                                active: "a", now: Self.now).target == nil)

        let blockedModel = PolicyAccount(name: "a", sessionPercent: 20, weeklyPercent: 20,
                                         weeklyResetsAt: Self.inHours(10), blockedForModelInUse: true)
        let decision = engine.evaluate(mode: .failover, accounts: [blockedModel, fresh],
                                       active: "a", now: Self.now)
        #expect(decision.target == "b")
        #expect(decision.reason.contains("model in use"))
    }

    @Test("eligibility needs 5% session and 2% weekly, and working credentials")
    func eligibility() {
        let config = PolicyConfig()
        #expect(PolicyAccount(name: "ok", sessionPercent: 95, weeklyPercent: 98).isEligible(config))
        #expect(PolicyAccount(name: "thin session", sessionPercent: 96).isEligible(config) == false)
        #expect(PolicyAccount(name: "thin weekly", weeklyPercent: 99).isEligible(config) == false)
        #expect(PolicyAccount(name: "dead", isUsable: false).isEligible(config) == false)

        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100)
        let thin = PolicyAccount(name: "b", order: 1, sessionPercent: 99)
        let decision = engine.evaluate(mode: .failover, accounts: [stuck, thin],
                                       active: "a", now: Self.now)
        #expect(decision.target == nil)
        #expect(decision.reason.contains("no other account is eligible"))
    }

    @Test("manual mode never moves")
    func manualNeverMoves() {
        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100, weeklyPercent: 100)
        let free = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 0)
        #expect(engine.evaluate(mode: .manual, accounts: [stuck, free],
                                active: "a", now: Self.now).target == nil)
        #expect(SwitchMode.manual.sideNote == nil)
        #expect(SwitchMode.balance.sideNote?.contains("Terms of Service") == true)
    }

    @Test("with no active account, the best eligible one is chosen")
    func noActiveAccount() {
        let engine = PolicyEngine()
        let first = PolicyAccount(name: "a", order: 0, weeklyPercent: 50, weeklyResetsAt: Self.inHours(10))
        let second = PolicyAccount(name: "b", order: 1, weeklyPercent: 10, weeklyResetsAt: Self.inHours(10))
        for active in [nil, "gone"] {
            let decision = engine.evaluate(mode: .failover, accounts: [first, second],
                                           active: active, now: Self.now)
            #expect(decision.target == "b")
            #expect(decision.cause == "no active account")
        }
        let dead = PolicyAccount(name: "a", isUsable: false)
        #expect(engine.evaluate(mode: .failover, accounts: [dead], active: nil, now: Self.now).cause
                == "nowhere to go")
    }

    @Test("equal urgency falls back to the listed order")
    func tieBreak() {
        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100)
        let second = PolicyAccount(name: "b", order: 2, weeklyPercent: 50,
                                   weeklyResetsAt: Self.inHours(10))
        let first = PolicyAccount(name: "c", order: 1, weeklyPercent: 50,
                                  weeklyResetsAt: Self.inHours(10))
        #expect(engine.evaluate(mode: .failover, accounts: [stuck, second, first],
                                active: "a", now: Self.now).target == "c")
    }

    @Test("an unknown or past reset time is the weekly horizon, not maximum urgency")
    func missingResetTime() {
        // 60% left and nothing said about when it expires: 60 points over seven days.
        let unknown = PolicyAccount(name: "a", weeklyPercent: 40)
        #expect(abs(unknown.urgency(now: Self.now) - 60 / 168) < 0.0001)
        // A reset already behind us means a window that has just refilled, which is
        // the *least* urgent state there is. Counting the whole remainder instead
        // returned 60 %/h against real rates near 1, so the unknown won every time.
        let past = PolicyAccount(name: "b", weeklyPercent: 40, weeklyResetsAt: Self.inHours(-2))
        #expect(past.urgency(now: Self.now) == unknown.urgency(now: Self.now))
        let measured = PolicyAccount(name: "c", weeklyPercent: 20, weeklyResetsAt: Self.inHours(72))
        #expect(measured.urgency(now: Self.now) > unknown.urgency(now: Self.now))
        // A reset a second away cannot divide its way to infinity either.
        let expiring = PolicyAccount(name: "d", weeklyPercent: 50,
                                     weeklyResetsAt: Self.now.addingTimeInterval(1))
        #expect(expiring.urgency(now: Self.now) == 50 / PolicyAccount.minimumHorizonHours)
        #expect(expiring.urgency(now: Self.now).isFinite)
    }

    @Test("a percentage outside 0-100 cannot flatter an account that is out of quota")
    func remainingIsClamped() {
        // The endpoint has sent nonsense before; -5% used reads as 105% left.
        let flattered = PolicyAccount(name: "a", sessionPercent: -5, weeklyPercent: -5,
                                      weeklyResetsAt: Self.inHours(10))
        #expect(flattered.weeklyRemaining == 100)
        #expect(flattered.sessionRemaining == 100)
        let overrun = PolicyAccount(name: "b", sessionPercent: 140, weeklyPercent: 140)
        #expect(overrun.weeklyRemaining == 0)
        #expect(overrun.isEligible(PolicyConfig()) == false)
    }

    @Test("an account nobody has read never wins Balance and never invents a number")
    func unreadAccountsAndBalance() {
        let engine = PolicyEngine()
        let active = PolicyAccount(name: "a", order: 0, sessionPercent: 0, weeklyPercent: 50,
                                   weeklyResetsAt: Self.inHours(10))
        let unread = PolicyAccount(name: "b", order: 1)
        #expect(unread.hasWeeklyReading == false)
        // Its defaults (100% left, no reset) used to out-urge every measured account.
        let balance = engine.evaluate(mode: .balance, accounts: [active, unread],
                                      active: "a", now: Self.now)
        #expect(balance.target == nil)
        #expect(balance.cause == "no reading")

        // Failover may still fall back to it — being stuck is worse than being
        // unknown — but the sentence says so rather than printing "100% weekly left".
        let stuck = PolicyAccount(name: "a", order: 0, sessionPercent: 100)
        let failover = engine.evaluate(mode: .failover, accounts: [stuck, unread],
                                       active: "a", now: Self.now)
        #expect(failover.target == "b")
        #expect(failover.reason.contains("no weekly reading yet"))
        #expect(failover.reason.contains("100%") == false)
    }

    @Test("a measured account outranks an unread one whose defaults look better")
    func measuredBeatsUnread() {
        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100)
        let unread = PolicyAccount(name: "b", order: 1)
        // 3% left over eight days is 0.015 %/h, far below the unread default of 0.6,
        // and it is still the only one of the two anybody has measured.
        let measured = PolicyAccount(name: "c", order: 2, sessionPercent: 0, weeklyPercent: 97,
                                     weeklyResetsAt: Self.inHours(200))
        #expect(engine.evaluate(mode: .failover, accounts: [stuck, unread, measured],
                                active: "a", now: Self.now).target == "c")
    }

    @Test("Balance holds when the account in use has no reading to compare")
    func balanceNeedsBothSides() {
        let engine = PolicyEngine()
        let blind = PolicyAccount(name: "a", order: 0)
        let measured = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 20,
                                     weeklyResetsAt: Self.inHours(72))
        let decision = engine.evaluate(mode: .balance, accounts: [blind, measured],
                                       active: "a", now: Self.now)
        #expect(decision.target == nil)
        #expect(decision.cause == "no reading")
        // Unless the account in use has no claim on new work anyway.
        let thin = PolicyAccount(name: "a", order: 0, sessionPercent: 99)
        #expect(engine.evaluate(mode: .balance, accounts: [thin, measured],
                                active: "a", now: Self.now).target == "b")
    }

    @Test("one account, no accounts, and every account unusable")
    func degenerateCases() {
        let engine = PolicyEngine()
        let only = PolicyAccount(name: "a", sessionPercent: 10, weeklyPercent: 10,
                                 weeklyResetsAt: Self.inHours(10))
        #expect(engine.evaluate(mode: .balance, accounts: [only], active: "a",
                                now: Self.now).cause == "nowhere to go")
        #expect(engine.evaluate(mode: .failover, accounts: [], active: "a",
                                now: Self.now).cause == "no accounts")
        let dead = [PolicyAccount(name: "a", isUsable: false),
                    PolicyAccount(name: "b", order: 1, isUsable: false)]
        let nowhere = engine.evaluate(mode: .failover, accounts: dead, active: "a", now: Self.now)
        #expect(nowhere.target == nil)
        #expect(nowhere.cause == "nowhere to go")
        // The only account left is the one in use: a switch to it is not a switch.
        let alone = PolicyAccount(name: "a", sessionPercent: 100)
        #expect(engine.evaluate(mode: .failover, accounts: [alone], active: "a",
                                now: Self.now).target == nil)
    }

    @Test("a dead-even pair does not switch, and an ineligible active one has no claim")
    func hysteresisEdges() {
        let engine = PolicyEngine()
        let active = PolicyAccount(name: "a", sessionPercent: 0, weeklyPercent: 50,
                                   weeklyResetsAt: Self.inHours(10))
        let same = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 50,
                                 weeklyResetsAt: Self.inHours(10))
        #expect(engine.evaluate(mode: .balance, accounts: [active, same], active: "a",
                                now: Self.now).cause == "hysteresis")
        let thin = PolicyAccount(name: "a", sessionPercent: 99, weeklyPercent: 50,
                                 weeklyResetsAt: Self.inHours(10))
        #expect(engine.evaluate(mode: .balance, accounts: [thin, same], active: "a",
                                now: Self.now).target == "b")
    }

    @Test("a switch stamp from a clock that moved does not freeze Balance")
    func futureSwitchStamp() {
        let engine = PolicyEngine()
        let active = PolicyAccount(name: "a", sessionPercent: 0, weeklyPercent: 90,
                                   weeklyResetsAt: Self.inHours(10))
        let better = PolicyAccount(name: "b", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                   weeklyResetsAt: Self.inHours(10))
        // A minute ahead is the cool-off doing its job; a year ahead is a wrong clock.
        #expect(engine.evaluate(mode: .balance, accounts: [active, better], active: "a",
                                now: Self.now,
                                lastSwitchAt: Self.now.addingTimeInterval(60)).cause == "too soon")
        #expect(engine.evaluate(mode: .balance, accounts: [active, better], active: "a",
                                now: Self.now,
                                lastSwitchAt: Self.inHours(24 * 365)).target == "b")
    }
}

/// The log line and the de-duplication that keeps it readable when the same
/// decision is recomputed every pass.
@Suite("Switch log")
struct SwitchLogTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a decision becomes one log line")
    func decisionLine() {
        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "perso2", sessionPercent: 100, weeklyPercent: 50,
                                  weeklyResetsAt: Self.now.addingTimeInterval(36_000))
        let free = PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                 weeklyResetsAt: Self.now.addingTimeInterval(36_000))
        let decision = engine.evaluate(mode: .failover, accounts: [stuck, free],
                                       active: "perso2", now: Self.now)
        #expect(decision.cause == "session limit")

        var log = SwitchLog()
        let recorded = log.record(decision, from: "perso2", at: Self.now)
        #expect(recorded)
        #expect(log.entries.first?.text == "would switch perso2 → pro: session limit")
        #expect(log.entries.first?.kind == .wouldSwitch)
    }

    @Test("the same decision is not written down twice in a row")
    func deduplicates() {
        var log = SwitchLog()
        let decision = PolicyDecision.move(to: "pro", "because", cause: "weekly limit")
        let first = log.record(decision, from: "perso2", at: Self.now)
        let again = log.record(decision, from: "perso2", at: Self.now.addingTimeInterval(120))
        #expect(first)
        #expect(again == false)
        #expect(log.entries.count == 1)

        log.add(.switched, "switched perso2 → pro", at: Self.now.addingTimeInterval(180))
        let third = log.record(decision, from: "perso2", at: Self.now.addingTimeInterval(240))
        #expect(third)
        #expect(log.entries.count == 3)
    }

    @Test("a decision to stay is never logged, and manual decides nothing")
    func staysAreNotLogged() {
        var log = SwitchLog()
        let stayed = log.record(.stay("still running", cause: "still running"), from: "perso2")
        #expect(stayed == false)
        #expect(log.entries.isEmpty)

        let engine = PolicyEngine()
        let stuck = PolicyAccount(name: "a", sessionPercent: 100)
        let free = PolicyAccount(name: "b", order: 1)
        let manual = engine.evaluate(mode: .manual, accounts: [stuck, free], active: "a", now: Self.now)
        #expect(manual.cause == "manual")
        let recordedManual = log.record(manual, from: "a")
        #expect(recordedManual == false)
    }

    @Test("the log is capped so it cannot grow without end")
    func capped() {
        var log = SwitchLog(limit: 3)
        for index in 0..<10 {
            log.add(.note, "line \(index)", at: Self.now.addingTimeInterval(Double(index)))
        }
        #expect(log.entries.count == 3)
        #expect(log.entries.first?.text == "line 9")     // newest first
        #expect(log.entries.last?.text == "line 7")
    }

    @Test("every branch carries a cause short enough for one line")
    func causes() {
        let engine = PolicyEngine()
        let now = Self.now
        let stuck = PolicyAccount(name: "a", sessionPercent: 0, weeklyPercent: 100)
        let free = PolicyAccount(name: "b", order: 1, weeklyPercent: 10,
                                 weeklyResetsAt: now.addingTimeInterval(36_000))
        #expect(engine.evaluate(mode: .failover, accounts: [stuck, free],
                                active: "a", now: now).cause == "weekly limit")
        #expect(engine.evaluate(mode: .failover, accounts: [free], active: "b", now: now).cause
                == "still running")
        #expect(engine.evaluate(mode: .failover, accounts: [stuck], active: "a", now: now).cause
                == "nowhere to go")
        let dead = PolicyAccount(name: "a", isUsable: false)
        #expect(engine.evaluate(mode: .failover, accounts: [dead, free],
                                active: "a", now: now).cause == "credentials")
        let busy = PolicyAccount(name: "a", weeklyPercent: 90, weeklyResetsAt: now.addingTimeInterval(36_000))
        #expect(engine.evaluate(mode: .balance, accounts: [busy, free], active: "a", now: now).cause
                == "balance")
        #expect(engine.evaluate(mode: .balance, accounts: [busy, free], active: "a", now: now,
                                lastSwitchAt: now.addingTimeInterval(-60)).cause == "too soon")
    }
}
