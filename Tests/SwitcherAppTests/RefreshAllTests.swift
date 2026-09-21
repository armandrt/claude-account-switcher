import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// "Refresh all", the opt-in renewal and the sweep the panel starts when it
/// opens.  Every request here is a stub; the shared allowance is the thing
/// being protected, so what is *not* asked for matters as much as what is.
@Suite("Refresh all")
@MainActor
struct RefreshAllTests {
    /// perso2 is live and was read moments ago, pro's token has expired, old is
    /// fine but has not been read for two hours.
    static func world(now: Date = Date()) throws -> AppWorld {
        let items: [String: Data] = [
            AppWorld.prefix + "perso2": AppWorld.slot(access: "stale-perso2",
                                                      email: "live@example.com"),
            AppWorld.prefix + "pro": AppWorld.slot(access: "pro-access", email: "pro@example.com",
                                                   expiresIn: -60),
            AppWorld.prefix + "old": AppWorld.slot(access: "old-access", email: "old@example.com"),
            AppWorld.liveService: AppWorld.liveItem(access: "live-access"),
        ]
        return try AppWorld(items: items, cache: [
            "perso2": snapshot(fetchedAt: now.addingTimeInterval(-10)),
            "pro": snapshot(fetchedAt: now.addingTimeInterval(-3600)),
            "old": snapshot(fetchedAt: now.addingTimeInterval(-7200)),
        ])
    }

    @Test("stalest first, renew then read, and a fresh account is left alone")
    func orderAndSkips() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armUsage()
        world.armRefresh()
        await world.model.reloadSlots()

        world.model.refreshAll()
        let task = world.model.sweepTask
        #expect(task != nil)
        await task?.value

        let report = try #require(world.model.sweepReport)
        #expect(report.outcomes.map(\.name) == ["old", "pro", "perso2"])
        #expect(report.outcomes[0].result == .alreadyFine)
        #expect(report.outcomes[1].result == .renewed)
        #expect(report.outcomes[2].result
                == .skipped("its numbers are less than 2 minutes old"))
        #expect(report.stopped == nil)
        // Two readings and one renewal: the fresh account cost nothing.
        #expect(AppStub.calls(for: world.usageURL).count == 2)
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        #expect(world.storedAccessToken("pro") == "renewed-access")
        #expect(world.model.sweepProgress.isEmpty)
        await world.expectNothingStuck()
    }

    @Test("the first 429 ends the sweep and the rest are never asked")
    func stopsOnRateLimit() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armRateLimited()
        world.armRefresh()
        await world.model.reloadSlots()

        world.model.refreshAll()
        await world.model.sweepTask?.value

        let report = try #require(world.model.sweepReport)
        #expect(report.stopped?.contains("rate limited") == true)
        #expect(report.outcomes[1].result == .notReached)
        #expect(report.outcomes[2].result == .notReached)
        #expect(report.headline.hasPrefix("stopped:"))
        #expect(AppStub.calls(for: world.usageURL).count == 1)
        #expect(AppStub.calls(for: world.refreshTokenURL).isEmpty)
        #expect(world.model.budget.waitTime(now: Date()) > 0)
        await world.expectNothingStuck()
    }

    @Test("Stop ends it with nothing asked, and says so in the report")
    func stopButton() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armUsage()
        world.armRefresh()
        await world.model.reloadSlots()

        world.model.refreshAll()
        let task = world.model.sweepTask
        world.model.stopRefreshAll()
        #expect(world.model.sweepLine == "stopping after this account…")
        await task?.value

        let report = try #require(world.model.sweepReport)
        #expect(report.stopped == "you stopped it")
        #expect(report.outcomes.allSatisfy { $0.result == .notReached })
        #expect(AppStub.calls(for: world.usageURL).isEmpty)
        #expect(AppStub.calls(for: world.refreshTokenURL).isEmpty)
        await world.expectNothingStuck()
    }

    @Test("Stop with no sweep running leaves the footer alone")
    func stopWithNothingRunning() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armUsage()
        world.armRefresh()
        await world.model.reloadSlots()

        world.model.refreshAll()
        await world.model.sweepTask?.value
        // The Stop button is still on screen for the frame after the sweep ends.
        world.model.stopRefreshAll()
        #expect(world.model.sweepLine == nil)
        await world.expectNothingStuck()
    }

    @Test("a sweep refuses to start while anything else holds the model")
    func sweepRefusesWhenBusy() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.busySlot = "pro"
        world.model.refreshAll()
        #expect(world.model.sweepTask == nil)
        #expect(world.model.actionError == "another action is still running")
        world.model.busySlot = nil
    }

    // MARK: - Automatic renewal

    @Test("an expired slot is renewed without being asked, and only one per interval")
    func autoRenewOncePerInterval() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armRefresh()
        await world.model.reloadSlots()

        await world.model.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        #expect(world.storedAccessToken("pro") == "renewed-access")
        #expect(world.model.lastAutoRenewAt != nil)
        #expect(world.model.busySlot == nil)

        await world.model.reloadSlots()
        await world.model.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1, "the interval has not passed")
    }

    @Test("relaunching is not a way to rotate another refresh token")
    func autoRenewClockSurvivesRelaunch() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armRefresh()
        await world.model.reloadSlots()
        await world.model.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)

        let relaunched = world.relaunch()
        relaunched.budget = RateLimitBudget(base: 60, cap: 120, jitterFraction: 0, minimumSpacing: 0)
        #expect(relaunched.lastAutoRenewAt != nil)
        await relaunched.reloadSlots()
        await relaunched.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        relaunched.stop()
    }

    @Test("a renewal that fails still uses up its turn")
    func failedRenewalCostsItsTurn() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        AppStub.arm(json: #"{"error":"invalid_grant"}"#, status: 400, for: world.refreshTokenURL)
        await world.model.reloadSlots()

        await world.model.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        #expect(world.model.lastAutoRenewAt != nil)
        #expect(world.model.busySlot == nil)
        #expect(world.logText().contains("automatic renewal failed for pro"))

        await world.model.autoRenewIfDue()
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
    }

    // MARK: - Opening the panel

    @Test("opening the panel sweeps once per interval, not once per opening")
    func panelOpenSweepsAtMostOnce() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armUsage()
        // The renewal fails, so the account stays dark and the interval is the
        // only thing that can hold the second opening back.
        AppStub.arm(json: #"{"error":"invalid_grant"}"#, status: 400, for: world.refreshTokenURL)
        await world.model.reloadSlots()

        world.model.refreshAllIfAnythingWentDark()
        let task = world.model.sweepTask
        #expect(task != nil)
        await task?.value
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        #expect(world.model.lastOpenSweepAt != nil)

        world.model.refreshAllIfAnythingWentDark()
        #expect(world.model.sweepTask == nil)
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)

        // And a relaunch is not a fresh licence to rotate either.
        let relaunched = world.relaunch()
        await relaunched.reloadSlots()
        relaunched.refreshAllIfAnythingWentDark()
        #expect(relaunched.sweepTask == nil)
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1)
        relaunched.stop()
    }

    @Test("with nothing dark, opening the panel asks for nothing")
    func panelOpenWithNothingDark() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.armUsage()
        world.armRefresh()
        await world.model.reloadSlots()

        world.model.refreshAllIfAnythingWentDark()
        #expect(world.model.sweepTask == nil)
        #expect(world.model.lastOpenSweepAt == nil)
        #expect(AppStub.calls(for: world.refreshTokenURL).isEmpty)
        #expect(AppStub.calls(for: world.usageURL).isEmpty)
    }

    @Test("a sign-in on screen keeps the panel-open sweep away")
    func panelOpenWaitsForTheSignIn() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.model.beginAddAccount()

        world.model.refreshAllIfAnythingWentDark()
        #expect(world.model.sweepTask == nil)
        #expect(world.model.lastOpenSweepAt == nil)
        world.model.cancelLogin()
    }
}
