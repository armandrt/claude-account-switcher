import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// Whose turn the one reading per pass goes to.  An account that never gets a
/// turn shows nothing at all, which is the bug this rule exists to stop.
@Suite("Poll schedule")
struct PollScheduleTests {
    static func row(_ name: String, active: Bool = false, readAt: Date? = nil,
                    health: CredentialHealth = .ok,
                    scopes: [String] = ["user:profile", "user:inference"],
                    sessionPercent: Double? = nil) -> AccountRow {
        let credentials = OAuthCredentials(accessToken: "a", refreshToken: "r", scopes: scopes)
        var row = AccountRow(slot: Slot(name: name, isActive: active, health: health,
                                        credentials: credentials))
        row.lastAttemptAt = readAt
        if let sessionPercent {
            row.usage = UsageSnapshot(limits: [UsageLimit(kind: .session, percent: sessionPercent)])
        }
        return row
    }

    @Test("an account is never read at all until it has been read once")
    func neverReadWinsOutright() {
        let now = Date()
        let rows = [Self.row("perso2", active: true, readAt: now.addingTimeInterval(-10)),
                    Self.row("pro")]
        #expect(PollSchedule.next(from: rows, now: now)?.name == "pro")
    }

    @Test("the inactive account overtakes the active one once it is further behind")
    func overduenessIsARatio() {
        let now = Date()
        // Both are due; the inactive one is 3% past its interval, the active 8%.
        let activeWins = [Self.row("perso2", active: true, readAt: now.addingTimeInterval(-130)),
                          Self.row("pro", readAt: now.addingTimeInterval(-620))]
        #expect(PollSchedule.next(from: activeWins, now: now)?.name == "perso2")

        let inactiveWins = [Self.row("perso2", active: true, readAt: now.addingTimeInterval(-121)),
                            Self.row("pro", readAt: now.addingTimeInterval(-900))]
        #expect(PollSchedule.next(from: inactiveWins, now: now)?.name == "pro")
    }

    @Test("nothing is picked before its own interval is up")
    func nothingIsPickedEarly() {
        let now = Date()
        let rows = [Self.row("perso2", active: true, readAt: now.addingTimeInterval(-30)),
                    Self.row("pro", readAt: now.addingTimeInterval(-100))]
        #expect(PollSchedule.next(from: rows, now: now) == nil)
    }

    @Test("an hour of the real loop reads every account, not just the active one")
    func noAccountStarves() {
        let start = Date()
        var rows = [Self.row("perso2", active: true), Self.row("pro"), Self.row("old")]
        var reads: [String: Int] = [:]
        var now = start

        while now.timeIntervalSince(start) < 3600 {
            if let picked = PollSchedule.next(from: rows, now: now) {
                reads[picked.name, default: 0] += 1
                if let index = rows.firstIndex(where: { $0.name == picked.name }) {
                    rows[index].lastAttemptAt = now
                }
            }
            now = now.addingTimeInterval(PollSchedule.delay(for: rows, now: now, budgetWait: 0))
        }

        // The active account is on the two-minute cadence; the other two are on
        // ten minutes and must each get their share of the hour.
        #expect(reads["perso2", default: 0] >= 20)
        #expect(reads["pro", default: 0] >= 5)
        #expect(reads["old", default: 0] >= 5)
    }

    @Test("an account that keeps failing cannot starve the others")
    func failuresDoNotStarve() {
        let start = Date()
        // "pro" is judged by its last attempt, so its failures cost it its turn
        // and nothing more.
        var rows = [Self.row("perso2", active: true), Self.row("pro")]
        var reads: [String: Int] = [:]
        var now = start
        while now.timeIntervalSince(start) < 1800 {
            if let picked = PollSchedule.next(from: rows, now: now) {
                reads[picked.name, default: 0] += 1
                if let index = rows.firstIndex(where: { $0.name == picked.name }) {
                    rows[index].lastAttemptAt = now   // an attempt, not a success
                }
            }
            now = now.addingTimeInterval(PollSchedule.delay(for: rows, now: now, budgetWait: 0))
        }
        #expect(reads["perso2", default: 0] >= 10)
        #expect(reads["pro", default: 0] >= 2)
    }

    @Test("an account that has nearly run out is read four times as often")
    func lowAccountsAreReadSooner() {
        let busy = Self.row("perso2", active: true, sessionPercent: 95)
        let calm = Self.row("perso2", active: true, sessionPercent: 20)
        #expect(PollSchedule.interval(for: busy) == PollSchedule.activeWhenLow)
        #expect(PollSchedule.interval(for: calm) == PollSchedule.active)
        #expect(PollSchedule.interval(for: Self.row("pro")) == PollSchedule.inactive)
    }

    @Test("a slot with no usable token is never asked about")
    func unreadableSlotsAreSkipped() {
        let now = Date()
        let rows = [Self.row("expired", health: .expired),
                    Self.row("corrupt", health: .corrupt("truncated")),
                    Self.row("inference-only", scopes: ["user:inference"])]
        #expect(PollSchedule.next(from: rows, now: now) == nil)
        for row in rows { #expect(PollSchedule.canReadUsage(row.slot) == false) }
    }

    @Test("the wait is never shorter than 10 s, never longer than 2 min, and never early")
    func delayIsBounded() {
        let now = Date()
        let rows = [Self.row("perso2", active: true, readAt: now)]
        #expect(PollSchedule.delay(for: rows, now: now, budgetWait: 0) == 120)
        #expect(PollSchedule.delay(for: rows, now: now, budgetWait: 900) == 120)
        #expect(PollSchedule.delay(for: [], now: now, budgetWait: 0) == 120)

        let nearlyDue = [Self.row("perso2", active: true, readAt: now.addingTimeInterval(-119))]
        #expect(PollSchedule.delay(for: nearlyDue, now: now, budgetWait: 0) == 10)
    }
}

/// The one allowance the whole app shares, and what a relaunch knows about it.
@Suite("Rate limit budget in the app")
@MainActor
struct BudgetTests {
    @Test("a 429 is remembered across a relaunch")
    func rateLimitSurvivesRelaunch() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.armRateLimited()
        await world.model.reloadSlots()

        await world.model.pollAccount(named: "pro")
        #expect(world.preferences.values[AppModel.budgetStateKey] != nil)
        #expect(world.model.budget.strikes == 1)
        #expect(world.model.rows.first { $0.name == "pro" }?.problem?.contains("rate limited") == true)

        let relaunched = world.relaunch()
        #expect(relaunched.budget.strikes == 1)
        #expect(relaunched.budget.waitTime(now: Date()) > 0)
        #expect(relaunched.budget.allows(Date()) == false)
        relaunched.stop()
    }

    @Test("with no saved allowance the newest cached reading stands in for one")
    func freshProcessDoesNotFireStraightAway() async throws {
        let world = try AppWorld(cache: ["pro": snapshot(fetchedAt: Date())])
        defer { world.cleanUp() }
        #expect(world.preferences.values[AppModel.budgetStateKey] == nil)

        let relaunched = world.relaunch()
        #expect(relaunched.budget.allows(Date()) == false, "30 s floor, counted from the last reading")
        relaunched.stop()
    }

    @Test("every request that goes out is written down, so a relaunch keeps the spacing")
    func requestsAreSaved() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.armUsage()
        await world.model.reloadSlots()

        await world.model.pollAccount(named: "pro")
        #expect(AppStub.calls(for: world.usageURL).count == 1)
        #expect(world.preferences.values[AppModel.budgetStateKey] != nil)
        #expect(world.model.rows.first { $0.name == "pro" }?.isLive == true)
        #expect(world.model.rows.first { $0.name == "pro" }?.lastAttemptAt != nil)

        let relaunched = world.relaunch()
        #expect(relaunched.budget.allows(Date()) == false)
        relaunched.stop()
    }

    @Test("a reading that failed still counts as an attempt")
    func failedReadingsCountAsAttempts() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        AppStub.arm(json: "boom", status: 500, for: world.usageURL)
        await world.model.reloadSlots()

        await world.model.pollAccount(named: "pro")
        let row = try #require(world.model.rows.first { $0.name == "pro" })
        #expect(row.lastAttemptAt != nil)
        #expect(row.isLive == false)
        #expect(row.problem != nil)
    }
}

/// A reset the reading predates makes everything on screen an assumption.
@Suite("Poll schedule after a reset")
struct PostResetScheduleTests {
    static func rowWithReset(_ name: String, active: Bool, fetchedAt: Date, resetsAt: Date,
                             attemptedAt: Date? = nil) -> AccountRow {
        var row = PollScheduleTests.row(name, active: active, readAt: attemptedAt ?? fetchedAt)
        row.usage = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 40, resetsAt: resetsAt),
            UsageLimit(kind: .weeklyAll, percent: 10, resetsAt: resetsAt.addingTimeInterval(86_400)),
        ], fetchedAt: fetchedAt)
        row.fetchedAt = fetchedAt
        return row
    }

    @Test("a window that reset since the reading jumps the queue")
    func resetJumpsTheQueue() {
        let now = Date()
        // Read 30 s ago — nowhere near due — but its session reset 5 s ago.
        let reset = Self.rowWithReset("pro", active: true, fetchedAt: now.addingTimeInterval(-30),
                                      resetsAt: now.addingTimeInterval(-5))
        // The other account is properly overdue.
        let overdue = PollScheduleTests.row("perso", readAt: now.addingTimeInterval(-1200))
        #expect(reset.awaitsPostResetReading(now: now))
        #expect(PollSchedule.next(from: [overdue, reset], now: now)?.name == "pro")
        #expect(PollSchedule.delay(for: [overdue, reset], now: now, budgetWait: 0) == 10)
    }

    @Test("one attempt since the reset is enough — it is not asked again on those grounds")
    func onlyOnceAfterReset() {
        let now = Date()
        let tried = Self.rowWithReset("pro", active: true, fetchedAt: now.addingTimeInterval(-60),
                                      resetsAt: now.addingTimeInterval(-30),
                                      attemptedAt: now.addingTimeInterval(-10))
        #expect(PollSchedule.next(from: [tried], now: now) == nil)
    }

    @Test("the loop wakes for the next reset instead of sleeping through it")
    func wakesForReset() {
        let now = Date()
        let soon = Self.rowWithReset("pro", active: true, fetchedAt: now,
                                     resetsAt: now.addingTimeInterval(45))
        // Its own interval says 120 s; the reset says 45 s. It wakes for the reset.
        #expect(PollSchedule.delay(for: [soon], now: now, budgetWait: 0) == 47)
    }

    @Test("a reading taken after the reset is not an estimate")
    func readAfterResetIsFact() {
        let now = Date()
        let fresh = Self.rowWithReset("pro", active: true, fetchedAt: now.addingTimeInterval(-5),
                                      resetsAt: now.addingTimeInterval(-60))
        #expect(fresh.awaitsPostResetReading(now: now) == false)
    }
}
