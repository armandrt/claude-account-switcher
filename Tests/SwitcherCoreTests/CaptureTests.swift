import Foundation
import Testing
@testable import SwitcherCore

/// "Capture the current login as…", against the test prefix and a temporary directory.
@Suite("Capture")
struct CaptureTests {
    static func world(activeName: String? = "perso2", items: [String: Data]? = nil) throws -> TempWorld {
        try TempWorld(activeName: activeName, items: items ?? [
            TempWorld.prefix + "pro": SlotStoreTests.truncatedPayload,
            TempWorld.live: SwitcherTests.liveItem(access: "pro-live-access"),
        ])
    }

    @Test("a dry run names the login it would store and writes nothing")
    func dryRun() throws {
        let world = try Self.world()
        defer { world.cleanUp() }

        let plan = try world.switcher.capture(into: "pro", dryRun: true)
        #expect(plan.performed == false)
        #expect(plan.name == "pro")
        #expect(plan.service == "CAS Test Login: pro")
        #expect(plan.liveEmail == "live@example.com")
        #expect(plan.slotExists)
        #expect(plan.headline == "store the login for live@example.com as \"pro\"")
        #expect(plan.replacingEmail == nil)
        #expect(plan.warnings.contains { $0.contains("unreadable or corrupt") })
        #expect(plan.warnings.contains { $0.contains("records \"pro\" as the active login") })

        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] == SlotStoreTests.truncatedPayload)
        #expect(world.marker() == "perso2")
    }

    @Test("capturing replaces a corrupt slot with a slot that parses")
    func replacesCorruptSlot() throws {
        let world = try Self.world()
        defer { world.cleanUp() }

        let plan = try world.switcher.capture(into: "pro", dryRun: false)
        #expect(plan.performed)

        let stored = try #require(world.keychain.box.items[TempWorld.prefix + "pro"])
        let payload = try CredentialPayload.parse(stored)
        #expect(payload.credentials.accessToken == "pro-live-access")
        #expect(payload.credentials.refreshToken == "rotated-pro-live-access")
        #expect(payload.account?.emailAddress == "live@example.com")
        #expect(payload.account?.accountUuid == "0000-live")
        #expect(stored.count == plan.byteCount)

        let root = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        #expect(root.keys.sorted() == ["credentials", "oauthAccount"])

        #expect(world.marker() == "pro")
        #expect(world.keychain.box.writes.map(\.service) == [TempWorld.prefix + "pro"])
        #expect(try world.configJSON()["oauthAccount"] is [String: Any])
    }

    @Test("capturing over a different account says whose login it is replacing")
    func warnsWhenReplacingAnotherAccount() throws {
        let world = try Self.world(items: [
            TempWorld.prefix + "pro": SwitcherTests.slot(access: "pro", email: "pro@example.com"),
            TempWorld.live: SwitcherTests.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }

        let plan = try world.switcher.capture(into: "pro", dryRun: true)
        #expect(plan.replacingEmail == "pro@example.com")
        #expect(plan.warnings.contains {
            $0.contains("currently holds pro@example.com") && $0.contains("live@example.com")
        })
    }

    @Test("a slot that exists but cannot be read is not replaced blind")
    func refusesToReplaceAnUnreadableSlot() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.failures[TempWorld.prefix + "pro"] = .interactionRequired(TempWorld.prefix + "pro")

        #expect(throws: (any Error).self) { try world.switcher.capture(into: "pro", dryRun: true) }
        #expect(throws: (any Error).self) { try world.switcher.capture(into: "pro", dryRun: false) }
        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.marker() == "perso2")
    }

    @Test("a new name makes a new slot, which is how an account is added")
    func addsANewSlot() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let plan = try world.switcher.capture(into: "work-2", dryRun: false)
        #expect(plan.slotExists == false)
        #expect(world.keychain.box.items["CAS Test Login: work-2"] != nil)
        #expect(world.marker() == "work-2")
    }

    @Test("a name claude-acct would not accept is refused")
    func badName() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        #expect(throws: SwitchError.badName("pro slot")) {
            try world.switcher.capture(into: "pro slot", dryRun: true)
        }
        #expect(throws: SwitchError.badName("")) {
            try world.switcher.capture(into: "", dryRun: true)
        }
    }

    @Test("no readable live login means there is nothing to capture")
    func noLiveLogin() throws {
        let world = try Self.world(items: [:])
        defer { world.cleanUp() }
        #expect(throws: (any Error).self) { try world.switcher.capture(into: "pro", dryRun: true) }
        #expect(world.keychain.box.writes.isEmpty)
    }

    @Test("a capture waits for the switch lock like a switch does")
    func takesTheLock() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let held = try FileLock(url: world.directory.appendingPathComponent("switch.lock"))
        #expect(held.tryLock())
        #expect(throws: (any Error).self) { try world.switcher.capture(into: "pro", dryRun: false) }
        held.unlock()
        #expect(try world.switcher.capture(into: "pro", dryRun: false).performed)
    }

    @Test("a keychain that stores a short item is caught before the marker moves")
    func truncatedWriteIsCaught() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.truncateWrites.insert(TempWorld.prefix + "pro")
        #expect(throws: (any Error).self) { try world.switcher.capture(into: "pro", dryRun: false) }
        #expect(world.marker() == "perso2")
    }
}
