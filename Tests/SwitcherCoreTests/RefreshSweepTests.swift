import Foundation
import Testing
@testable import SwitcherCore

/// What "Refresh all" decides not to do matters more than what it does: every
/// request spends the shared allowance. Checked here with no network or keychain.
@Suite("Refresh sweep")
struct RefreshSweepTests {
    static func credentials(expiresIn: TimeInterval = 3600, refreshIn: TimeInterval = 86_400,
                            scopes: [String] = ["user:profile", "user:inference"],
                            now: Date = Date()) -> OAuthCredentials {
        OAuthCredentials(
            accessToken: "a", refreshToken: "r",
            expiresAt: now.addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000,
            refreshTokenExpiresAt: now.addingTimeInterval(refreshIn).timeIntervalSince1970 * 1000,
            scopes: scopes)
    }

    static func slot(_ name: String, active: Bool = false, health: CredentialHealth = .ok,
                     credentials: OAuthCredentials? = credentials()) -> Slot {
        Slot(name: name, isActive: active, health: health, credentials: credentials)
    }

    /// The live login's token is Claude Code's to renew, never ours.
    @Test("the live login is never renewed by us")
    func activeIsNeverRenewed() {
        let slots = [
            Self.slot("pro"),
            Self.slot("perso2", active: true, health: .expired,
                      credentials: Self.credentials(expiresIn: -60)),
        ]
        let steps = SweepPlanner.plan(slots: slots)
        #expect(steps.count == 2)
        #expect(steps.first { $0.name == "perso2" }?.action
                == .skip("it is the live login, and Claude Code renews that one"))
        #expect(steps.first { $0.name == "pro" }?.action == .read)
    }

    @Test("an expired inactive slot is renewed, then read")
    func expiredIsRenewed() {
        let expired = Self.credentials(expiresIn: -60)
        let step = SweepPlanner.plan(slots: [Self.slot("perso", health: .expired,
                                                       credentials: expired)])[0]
        #expect(step.action == .renew)
        #expect(step.action.requests == 2)
    }

    @Test("nothing that cannot be fixed by a renewal is renewed")
    func refusals() {
        let corrupt = SweepPlanner.action(for: Self.slot("pro", health: .corrupt("truncated"),
                                                         credentials: nil))
        let dead = SweepPlanner.action(for: Self.slot("old", health: .needsRelogin))
        let unreadable = SweepPlanner.action(for: Self.slot("locked", health: .unreadable("denied"),
                                                            credentials: nil))
        for action in [corrupt, dead, unreadable] {
            #expect(action.isSkip)
            #expect(action.requests == 0)
        }
        // Three different problems with three different fixes, each named.
        #expect("\(corrupt)".contains("corrupt"))
        #expect("\(dead)".contains("refresh token is dead"))
        #expect("\(unreadable)".contains("keychain item"))
    }

    @Test("a token with no user:profile scope is left alone, expired or not")
    func scopeless() {
        let inference = Self.credentials(scopes: ["user:inference"])
        #expect(SweepPlanner.action(for: Self.slot("token", credentials: inference)).isSkip)
        let expired = Self.credentials(expiresIn: -60, scopes: ["user:inference"])
        let action = SweepPlanner.action(for: Self.slot("token", health: .expired, credentials: expired))
        #expect(action.isSkip)
        #expect(action != SweepAction.renew)
    }

    @Test("the plan counts the requests it will make")
    func requestCount() {
        let slots = [
            Self.slot("perso2", active: true),
            Self.slot("perso", health: .expired, credentials: Self.credentials(expiresIn: -60)),
            Self.slot("pro", health: .corrupt("truncated"), credentials: nil),
        ]
        let steps = SweepPlanner.plan(slots: slots)
        #expect(steps.reduce(0) { $0 + $1.action.requests } == 3)
    }

    @Test("the report answers all three questions, and names what is still broken")
    func report() {
        let report = SweepReport(outcomes: [
            SweepOutcome(name: "perso2", result: .alreadyFine),
            SweepOutcome(name: "perso", result: .renewed),
            SweepOutcome(name: "pro", result: .skipped("the stored login is corrupt")),
        ])
        #expect(report.renewed == ["perso"])
        #expect(report.alreadyFine == ["perso2"])
        #expect(report.headline == "1 renewed · 1 already fine · 1 left as it was")
        #expect(report.lines == ["pro — the stored login is corrupt"])
    }

    @Test("a rotation that could not be stored is not filed as a plain failure")
    func unstoredIsLoud() {
        let report = SweepReport(outcomes: [
            SweepOutcome(name: "perso", result: .renewedNotStored(
                "renewed, but the keychain would not take the new tokens — use Retry save")),
        ])
        // Counts as renewed, because a token was spent, and as a problem, because
        // the only copy is in memory.
        #expect(report.renewed == ["perso"])
        #expect(report.lines.count == 1)
        #expect(report.lines[0].contains("Retry save"))
    }

    @Test("a sweep that stopped says so, and says what it never reached")
    func stopped() {
        let report = SweepReport(outcomes: [
            SweepOutcome(name: "perso2", result: .alreadyFine),
            SweepOutcome(name: "perso", result: .failed("rate limited (429)")),
            SweepOutcome(name: "pro", result: .notReached),
        ], stopped: "rate limited (429)")
        #expect(report.headline.hasPrefix("stopped: rate limited (429)"))
        #expect(report.lines.contains("pro — the sweep stopped before reaching it"))
    }
}

@Suite("Automatic renewal")
struct AutoRenewTests {
    @Test("off the clock, nothing is due")
    func interval() {
        let now = Date()
        let expired = RefreshSweepTests.slot(
            "perso", health: .expired,
            credentials: RefreshSweepTests.credentials(expiresIn: -60, now: now))
        #expect(AutoRenew.due(slots: [expired], lastRenewAt: nil, now: now) == "perso")
        #expect(AutoRenew.due(slots: [expired],
                              lastRenewAt: now.addingTimeInterval(-60), now: now) == nil)
        #expect(AutoRenew.due(slots: [expired],
                              lastRenewAt: now.addingTimeInterval(-1801), now: now) == "perso")
    }

    @Test("the stalest token goes first, and only ever one")
    func stalestFirst() {
        let now = Date()
        let recent = RefreshSweepTests.slot(
            "recent", health: .expired,
            credentials: RefreshSweepTests.credentials(expiresIn: -60, now: now))
        let ancient = RefreshSweepTests.slot(
            "ancient", health: .expired,
            credentials: RefreshSweepTests.credentials(expiresIn: -90_000, now: now))
        #expect(AutoRenew.due(slots: [recent, ancient], lastRenewAt: nil, now: now) == "ancient")
    }

    @Test("it never touches the live login, a corrupt slot or a dead refresh token")
    func neverTheseOnes() {
        let now = Date()
        let live = RefreshSweepTests.slot(
            "perso2", active: true, health: .expired,
            credentials: RefreshSweepTests.credentials(expiresIn: -60, now: now))
        let corrupt = RefreshSweepTests.slot("pro", health: .corrupt("truncated"), credentials: nil)
        let dead = RefreshSweepTests.slot("old", health: .needsRelogin)
        let healthy = RefreshSweepTests.slot("fine")
        #expect(AutoRenew.due(slots: [live, corrupt, dead, healthy],
                              lastRenewAt: nil, now: now) == nil)
    }
}

/// A reading is only worth re-reading once its windows can have moved.
@Suite("Reset-aware readings")
struct ResetAwareTests {
    static func snapshot(sessionPercent: Double, sessionResets: Date,
                         weeklyPercent: Double, weeklyResets: Date) -> UsageSnapshot {
        UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: sessionPercent, severity: .critical,
                       resetsAt: sessionResets),
            UsageLimit(kind: .weeklyAll, percent: weeklyPercent, severity: .warning,
                       resetsAt: weeklyResets),
        ], fetchedAt: Date(timeIntervalSince1970: 1_000_000))
    }

    @Test("a window whose reset has passed reads as full again")
    func windowRollsOver() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = Self.snapshot(sessionPercent: 92, sessionResets: now.addingTimeInterval(-60),
                                     weeklyPercent: 40, weeklyResets: now.addingTimeInterval(3600))
        let rolled = snapshot.asOf(now)

        // The session window rolled over: empty, calm, and no stale countdown.
        #expect(rolled.sessionPercent == 0)
        #expect(rolled.limit(.session)?.severity == .normal)
        #expect(rolled.limit(.session)?.resetsAt == nil)
        // The weekly one has not, so it is untouched.
        #expect(rolled.weeklyPercent == 40)
        #expect(rolled.limit(.weeklyAll)?.severity == .warning)
    }

    @Test("before the reset nothing is invented")
    func beforeResetUnchanged() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = Self.snapshot(sessionPercent: 92, sessionResets: now.addingTimeInterval(60),
                                     weeklyPercent: 40, weeklyResets: now.addingTimeInterval(3600))
        #expect(snapshot.asOf(now) == snapshot)
    }

    @Test("a legacy window rolls over too")
    func legacyRollsOver() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = UsageSnapshot(
            limits: [],
            fiveHour: LegacyWindow(utilization: 80, resetsAt: now.addingTimeInterval(-1)),
            sevenDay: LegacyWindow(utilization: 30, resetsAt: now.addingTimeInterval(600)))
        let rolled = snapshot.asOf(now)
        #expect(rolled.sessionPercent == 0)
        #expect(rolled.weeklyPercent == 30)
    }

    @Test("a rollover from days ago is unknown, not a full tank")
    func staleRolloverIsUnknown() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = Self.snapshot(
            sessionPercent: 92, sessionResets: now.addingTimeInterval(-3 * 86_400),
            weeklyPercent: 96, weeklyResets: now.addingTimeInterval(-UsageLimit.rolloverGrace - 1))
        let rolled = snapshot.asOf(now)
        // Both windows did roll over. But three days of work we never saw could have
        // gone into the new ones, and "0% used" is the answer that sends the policy
        // — and the owner's credentials — straight at them.
        #expect(rolled.sessionPercent == nil)
        #expect(rolled.weeklyPercent == nil)
        #expect(rolled.limit(.session)?.severity == .unknown)
        #expect(rolled.tightest == nil)
        #expect(rolled.isBlocked == false)
        // The age of the reading is still the age of the reading.
        #expect(rolled.fetchedAt == snapshot.fetchedAt)

        // Just inside the grace the arithmetic is still worth something.
        let fresh = Self.snapshot(
            sessionPercent: 92, sessionResets: now.addingTimeInterval(-UsageLimit.rolloverGrace + 1),
            weeklyPercent: 40, weeklyResets: now.addingTimeInterval(3600))
        #expect(fresh.asOf(now).sessionPercent == 0)
        // Rolling a rolled reading changes nothing.
        #expect(fresh.asOf(now).asOf(now) == fresh.asOf(now))
    }

    @Test("a legacy window stale past its reset is unknown too")
    func staleLegacyRollover() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let snapshot = UsageSnapshot(
            limits: [],
            fiveHour: LegacyWindow(utilization: 80, resetsAt: now.addingTimeInterval(-86_400)),
            sevenDay: LegacyWindow(utilization: 30, resetsAt: now.addingTimeInterval(600)))
        let rolled = snapshot.asOf(now)
        #expect(rolled.sessionPercent == nil)
        #expect(rolled.weeklyPercent == 30)
    }

    @Test("a reading that rolled over days ago cannot make an account look fresh")
    func staleRolloverReachesThePolicy() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        // Four days old, from a slot the app has not been able to read since.
        let stale = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 100, severity: .critical,
                       resetsAt: now.addingTimeInterval(-3 * 86_400)),
            UsageLimit(kind: .weeklyAll, percent: 99, severity: .critical,
                       resetsAt: now.addingTimeInterval(-2 * 86_400)),
        ], fetchedAt: now.addingTimeInterval(-4 * 86_400)).asOf(now)

        let active = PolicyAccount(name: "a", order: 0, sessionPercent: 20, weeklyPercent: 20,
                                   weeklyResetsAt: now.addingTimeInterval(36_000))
        let stalest = PolicyAccount(name: "b", order: 1,
                                    sessionPercent: stale.sessionPercent,
                                    weeklyPercent: stale.weeklyPercent,
                                    weeklyResetsAt: stale.weeklyResetsAt)
        // Rolled to 0% with no reset time, this account used to answer "100% left,
        // expiring never" — the highest urgency on the list — and take the switch.
        let decision = PolicyEngine().evaluate(mode: .balance, accounts: [active, stalest],
                                               active: "a", now: now)
        #expect(decision.target == nil)
        #expect(decision.cause == "no reading")
    }
}

/// The sweep must not spend a request, or a 30 s wait, on a number already on screen.
@Suite("Sweep freshness")
struct SweepFreshnessTests {
    static func slot(_ name: String, active: Bool) -> Slot {
        RefreshSweepTests.slot(name, active: active)
    }

    @Test("an account read moments ago is skipped, however healthy")
    func freshIsSkipped() {
        let now = Date()
        let action = SweepPlanner.action(for: Self.slot("perso2", active: true),
                                         readAt: now.addingTimeInterval(-30), now: now)
        #expect(action.isSkip)
        #expect(action.requests == 0)
    }

    @Test("a stale account is still read")
    func staleIsRead() {
        let now = Date()
        #expect(SweepPlanner.action(for: Self.slot("perso2", active: true),
                                    readAt: now.addingTimeInterval(-3600), now: now) == .read)
        #expect(SweepPlanner.action(for: Self.slot("pro", active: false),
                                    readAt: nil, now: now) == .read)
    }

    @Test("the stalest account goes first")
    func stalestFirst() {
        let now = Date()
        let slots = [Self.slot("perso2", active: true), Self.slot("perso", active: false),
                     Self.slot("pro", active: false)]
        let steps = SweepPlanner.plan(slots: slots, readAt: [
            "perso2": now.addingTimeInterval(-10),
            "perso": now.addingTimeInterval(-7200),
            "pro": now.addingTimeInterval(-600),
        ], now: now)
        #expect(steps.map(\.name) == ["perso", "pro", "perso2"])
        #expect(steps.last?.action.isSkip == true)
    }

    @Test("accounts read equally long ago keep the order they were listed in")
    func tiesKeepTheListedOrder() {
        let now = Date()
        // Enough of them to leave the sort's stable small-array path: with a 429
        // ending the sweep at any step, which account goes first is the outcome.
        let names = (0..<40).map { "slot-\($0)" }
        let slots = names.map { RefreshSweepTests.slot($0) }
        #expect(SweepPlanner.plan(slots: slots, now: now).map(\.name) == names)

        let sameMoment = now.addingTimeInterval(-7200)
        let readAt = Dictionary(uniqueKeysWithValues: names.map { ($0, sameMoment) })
        #expect(SweepPlanner.plan(slots: slots, readAt: readAt, now: now).map(\.name) == names)
    }

    @Test("two slots under one name are one step, not two requests")
    func duplicateNames() {
        // A rename that failed after its copy leaves the keychain holding both.
        let slots = [RefreshSweepTests.slot("perso"), RefreshSweepTests.slot("perso"),
                     RefreshSweepTests.slot("pro")]
        let steps = SweepPlanner.plan(slots: slots)
        #expect(steps.map(\.name) == ["perso", "pro"])
        #expect(steps.reduce(0) { $0 + $1.action.requests } == 2)
    }

    @Test("an auto-renewal stamp from the future does not switch the feature off")
    func futureRenewStamp() {
        let now = Date()
        let expired = RefreshSweepTests.slot(
            "perso", health: .expired,
            credentials: RefreshSweepTests.credentials(expiresIn: -60, now: now))
        // A minute ahead is the half-hour clock doing its job.
        #expect(AutoRenew.due(slots: [expired], lastRenewAt: now.addingTimeInterval(60),
                              now: now) == nil)
        // A year ahead is a clock that has since been put right, and an opt-in that
        // can never come due again is a feature silently switched off.
        #expect(AutoRenew.due(slots: [expired], lastRenewAt: now.addingTimeInterval(365 * 86_400),
                              now: now) == "perso")
    }
}
