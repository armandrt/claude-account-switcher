import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// The per-row actions: Renew, Retry save, and what the model holds while they
/// run.  Every one of these sets `busySlot`, so every one of them is a way to
/// wedge the panel if an outcome forgets to clear it.
@Suite("AppModel actions")
@MainActor
struct AppModelActionsTests {
    static func world() throws -> AppWorld {
        let items: [String: Data] = [
            AppWorld.prefix + "perso2": AppWorld.slot(access: "stale-perso2",
                                                      email: "live@example.com"),
            AppWorld.prefix + "pro": AppWorld.slot(access: "pro-access", email: "pro@example.com",
                                                   expiresIn: -60),
            AppWorld.liveService: AppWorld.liveItem(access: "live-access"),
        ]
        return try AppWorld(items: items)
    }

    @Test("Renew rotates the tokens and hands the model back")
    func renewSucceeds() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armRefresh()
        world.armUsage()
        await world.model.reloadSlots()

        world.model.refreshCredentials(for: "pro")
        #expect(world.model.busySlot == "pro")
        #expect(await settle { world.model.busySlot == nil })

        #expect(world.storedAccessToken("pro") == "renewed-access")
        #expect(world.model.actionError == nil)
        #expect(world.model.unstoredSlots.isEmpty)
        #expect(world.logText().contains("refreshed pro"))
        await world.expectNothingStuck()
    }

    @Test("the live login is Claude Code's to renew, and the app says so")
    func renewRefusesTheLiveSlot() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.refreshCredentials(for: "perso2")
        #expect(world.model.actionError?.contains("Claude Code refreshes that one") == true)
        #expect(world.model.busySlot == nil)
        #expect(AppStub.calls(for: world.refreshTokenURL).isEmpty)
    }

    @Test("a renewal that fails says why and leaves nothing held")
    func renewFails() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        AppStub.arm(json: #"{"error":"invalid_grant"}"#, status: 400, for: world.refreshTokenURL)
        await world.model.reloadSlots()

        world.model.refreshCredentials(for: "pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("needs re-login") == true)
        #expect(world.logText().contains("refresh failed for pro"))
        #expect(world.storedAccessToken("pro") == "pro-access", "the slot is as it was")
        await world.expectNothingStuck()
    }

    @Test("rotated tokens the keychain refuses are held, and Retry save stores them")
    func retrySaveStoresWhatIsHeld() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armRefresh()
        world.keychain.box.writeFailures[AppWorld.prefix + "pro"] = .refused("not this build")
        await world.model.reloadSlots()

        world.model.refreshCredentials(for: "pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("refreshed but could not store") == true)
        #expect(world.model.unstoredSlots.contains("pro"), "the only working copy is in memory")
        #expect(world.storedAccessToken("pro") == "pro-access")

        // The keychain behaves again; no second rotation is asked for.
        world.keychain.box.writeFailures.removeValue(forKey: AppWorld.prefix + "pro")
        world.model.retryStoringTokens(for: "pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.unstoredSlots.isEmpty)
        #expect(world.storedAccessToken("pro") == "renewed-access")
        #expect(AppStub.calls(for: world.refreshTokenURL).count == 1, "no second rotation")
        #expect(world.logText().contains("stored the rotated tokens for pro"))
        await world.expectNothingStuck()
    }

    @Test("a pass takes no reading of its own while a sweep holds the allowance")
    func refreshStandsAsideForASweep() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.armUsage()
        await world.model.reloadSlots()

        world.model.sweepTask = Task {}
        await world.model.refresh()
        #expect(AppStub.calls(for: world.usageURL).isEmpty)
        world.model.sweepTask = nil

        await world.model.refresh()
        #expect(AppStub.calls(for: world.usageURL).count == 1)
    }

    @Test("a capture asks first, and the dry run writes nothing")
    func captureShowsItsPlanFirst() async throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.requestCapture(as: "not a name")
        #expect(world.model.actionError?.contains("not a usable slot name") == true)
        #expect(world.model.pendingCapture == nil)

        world.model.requestCapture(as: "spare")
        #expect(await settle { world.model.pendingCapture != nil })
        #expect(world.model.pendingCapture?.name == "spare")
        #expect(world.keychain.item(AppWorld.prefix + "spare") == nil)

        world.model.confirmCapture()
        #expect(await settle { world.model.pendingCapture == nil })
        #expect(world.storedAccessToken("spare") == "live-access")
        #expect(world.logText().contains("captured the current login as spare"))
        await world.expectNothingStuck()
    }
}
