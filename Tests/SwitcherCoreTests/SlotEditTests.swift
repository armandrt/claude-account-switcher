import Foundation
import Testing
@testable import SwitcherCore

/// Renaming and removing a slot, against an in-memory keychain in a temporary directory.
@Suite("Slot edits")
struct SlotEditTests {
    static func world(activeName: String? = "perso2") throws -> TempWorld {
        try TempWorld(activeName: activeName, items: [
            TempWorld.prefix + "perso2": SwitcherTests.slot(access: "stale-perso2",
                                                            email: "live@example.com"),
            TempWorld.prefix + "pro": SwitcherTests.slot(access: "pro-access",
                                                         email: "pro@example.com"),
            TempWorld.live: SwitcherTests.liveItem(access: "live-access"),
        ])
    }

    @Test("a rename writes the new item and only then deletes the old")
    func renameOrder() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try #require(world.keychain.box.items[TempWorld.prefix + "pro"])

        let result = try world.switcher.rename("pro", to: "pro-eu")
        #expect(result.from == "pro")
        #expect(result.to == "pro-eu")
        #expect(result.byteCount == before.count)
        #expect(result.movedMarker == false)
        #expect(result.oldItemLeftBehind == false)

        #expect(world.keychain.box.operations == ["write:\(TempWorld.prefix)pro-eu",
                                                  "delete:\(TempWorld.prefix)pro"])
        #expect(world.keychain.box.items[TempWorld.prefix + "pro-eu"] == before)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] == nil)
        // Nothing but that one account moved.
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.items[TempWorld.live] == SwitcherTests.liveItem(access: "live-access"))
        #expect(world.keychain.box.items[TempWorld.prefix + "perso2"] != nil)
        #expect(world.backups().isEmpty)
    }

    @Test("renaming the active account moves the marker with it")
    func renameActive() throws {
        let world = try Self.world()
        defer { world.cleanUp() }

        let result = try world.switcher.rename("perso2", to: "perso-main")
        #expect(result.movedMarker)
        #expect(world.marker() == "perso-main")
        #expect(world.switcher.activeSlotName() == "perso-main")
        #expect(world.keychain.box.items[TempWorld.prefix + "perso-main"] != nil)
        #expect(world.keychain.box.items[TempWorld.prefix + "perso2"] == nil)
    }

    @Test("a name that is taken, invalid or unchanged is refused before anything is written")
    func renameRefusals() throws {
        let world = try Self.world()
        defer { world.cleanUp() }

        #expect(throws: SlotEditError.nameTaken("perso2", email: "live@example.com")) {
            try world.switcher.rename("pro", to: "perso2")
        }
        #expect(throws: SlotEditError.badName("pro eu")) {
            try world.switcher.rename("pro", to: "pro eu")
        }
        #expect(throws: SlotEditError.badName("")) {
            try world.switcher.rename("pro", to: "")
        }
        #expect(throws: SlotEditError.unchanged("pro")) {
            try world.switcher.rename("pro", to: "pro")
        }
        #expect(throws: SlotEditError.noSuchSlot("ghost")) {
            try world.switcher.rename("ghost", to: "spare")
        }
        #expect(world.keychain.box.operations.isEmpty)
        #expect(world.keychain.box.items.count == 3)
    }

    @Test("a copy that does not read back is deleted again and the old slot is untouched")
    func renameVerifyFailure() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try #require(world.keychain.box.items[TempWorld.prefix + "pro"])
        world.keychain.box.truncateWrites.insert(TempWorld.prefix + "pro-eu")

        do {
            try world.switcher.rename("pro", to: "pro-eu")
            Issue.record("the rename should have failed")
        } catch let error as SlotEditError {
            guard case .verifyFailed(let name, let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "pro-eu")
            #expect(why.contains("bytes"))
        }
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] == before)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro-eu"] == nil)
        #expect(world.keychain.box.operations.contains("delete:\(TempWorld.prefix)pro") == false)
    }

    @Test("a keychain that refuses the new item changes nothing")
    func renameWriteFailure() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.writeFailures[TempWorld.prefix + "pro-eu"] =
            .status(-25293, TempWorld.prefix + "pro-eu")

        #expect(throws: (any Error).self) { try world.switcher.rename("pro", to: "pro-eu") }
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] != nil)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro-eu"] == nil)
        #expect(world.keychain.box.operations.isEmpty)
    }

    @Test("a marker that cannot be moved undoes the copy and leaves the old name in place")
    func renameMarkerFailure() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        // Two locks on the marker, because one of them might be lifted by the directory
        // being re-created: no new file in the directory, and no rename over the marker.
        FileManager.default.createFile(
            atPath: world.directory.appendingPathComponent("switch.lock").path, contents: nil)
        try FileManager.default.setAttributes([.immutable: true],
                                              ofItemAtPath: world.markerURL.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: world.directory.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                   ofItemAtPath: world.directory.path)
            try? FileManager.default.setAttributes([.immutable: false],
                                                   ofItemAtPath: world.markerURL.path)
        }

        do {
            try world.switcher.rename("perso2", to: "perso-main")
            Issue.record("the rename should have failed")
        } catch let error as SlotEditError {
            guard case .markerFailed(let name, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "perso-main")
            #expect(error.description.contains("untouched"))
        }
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.items[TempWorld.prefix + "perso2"] != nil)
        #expect(world.keychain.box.items[TempWorld.prefix + "perso-main"] == nil)
    }

    @Test("a delete that fails leaves a duplicate, not a lost account")
    func renameDeleteFailure() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.deleteFailures[TempWorld.prefix + "pro"] =
            .status(-25300, TempWorld.prefix + "pro")

        let result = try world.switcher.rename("pro", to: "pro-eu")
        #expect(result.oldItemLeftBehind)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro-eu"] != nil)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] != nil)
    }

    @Test("a removal deletes one item and nothing else")
    func removeOne() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        let result = try world.switcher.remove("pro")
        #expect(result.name == "pro")
        #expect(result.email == "pro@example.com")
        #expect(result.byteCount > 0)
        #expect(world.keychain.box.operations == ["delete:\(TempWorld.prefix)pro"])
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] == nil)
        #expect(world.keychain.box.items[TempWorld.prefix + "perso2"] != nil)
        #expect(world.keychain.box.items[TempWorld.live] != nil)
        #expect(world.marker() == "perso2")
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.backups().isEmpty)
    }

    @Test("the active login is never removed, by the marker or by the email it holds")
    func removeRefusesLive() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        #expect(throws: SlotEditError.holdsLiveLogin("perso2", why: "it is the active login")) {
            try world.switcher.remove("perso2")
        }

        // A marker that names another slot does not make this one removable: it still
        // holds the account .claude.json says is live.
        let stale = try TempWorld(activeName: "pro", items: [
            TempWorld.prefix + "perso2": SwitcherTests.slot(access: "stale-perso2",
                                                            email: "live@example.com"),
            TempWorld.prefix + "pro": SwitcherTests.slot(access: "pro-access",
                                                         email: "pro@example.com"),
            TempWorld.live: SwitcherTests.liveItem(access: "live-access"),
        ])
        defer { stale.cleanUp() }
        do {
            try stale.switcher.remove("perso2")
            Issue.record("the removal should have been refused")
        } catch let error as SlotEditError {
            guard case .holdsLiveLogin(let name, let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "perso2")
            #expect(why.contains("live@example.com"))
        }
        #expect(stale.keychain.box.operations.isEmpty)
        #expect(world.keychain.box.operations.isEmpty)
    }

    @Test("a corrupt slot can still be removed, a missing one cannot")
    func removeCorrupt() throws {
        let world = try TempWorld(activeName: "perso2", items: [
            TempWorld.prefix + "perso2": SwitcherTests.slot(access: "stale-perso2",
                                                            email: "live@example.com"),
            TempWorld.prefix + "pro": SlotStoreTests.truncatedPayload,
            TempWorld.live: SwitcherTests.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }

        let result = try world.switcher.remove("pro")
        #expect(result.email == nil)
        #expect(result.byteCount == SlotStoreTests.truncatedPayload.count)
        #expect(world.keychain.box.items[TempWorld.prefix + "pro"] == nil)

        #expect(throws: SlotEditError.noSuchSlot("pro")) { try world.switcher.remove("pro") }
        #expect(throws: SlotEditError.badName("pro slot")) { try world.switcher.remove("pro slot") }
    }

    @Test("a name that would resolve to the live item is refused outright")
    func neverTheLiveItem() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-slot-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try TempWorld.config().write(to: directory.appendingPathComponent(".claude.json"))

        // A prefix one word short of the live service: "Live" would name it.
        let keychain = FakeKeychain()
        keychain.box.items["CAS Test Live"] = SwitcherTests.liveItem(access: "live-access")
        let switcher = Switcher(
            reader: keychain, writer: keychain, loginPrefix: "CAS Test ",
            liveService: "CAS Test Live",
            paths: Switcher.Paths(config: directory.appendingPathComponent(".claude.json"),
                                  activeLogin: directory.appendingPathComponent("active-login"),
                                  lock: directory.appendingPathComponent("switch.lock")))

        #expect(throws: SlotEditError.protectedService("CAS Test Live")) {
            try switcher.remove("Live")
        }
        #expect(throws: SlotEditError.protectedService("CAS Test Live")) {
            try switcher.rename("Live", to: "spare")
        }
        #expect(throws: SlotEditError.protectedService("CAS Test Live")) {
            try switcher.rename("spare", to: "Live")
        }
        #expect(keychain.box.operations.isEmpty)
        #expect(keychain.box.items["CAS Test Live"] != nil)
    }
}

/// The dragged order: what the list shows and what the policy breaks ties by.
@Suite("Account order")
struct SlotOrderTests {
    @Test("stored positions come first, anything new sorts last in the order it arrived")
    func sorting() {
        let order = SlotOrder(["pro", "perso"])
        #expect(order.sorted(["perso", "pro"]) == ["pro", "perso"])
        // Alphabetical from the keychain; "new" and "zed" have no stored place.
        #expect(order.sorted(["new", "perso", "pro", "zed"]) == ["pro", "perso", "new", "zed"])
        // A stored name that is gone today changes nothing for the rest.
        #expect(SlotOrder(["gone", "pro", "perso"]).sorted(["perso", "pro"]) == ["pro", "perso"])
        #expect(SlotOrder().sorted(["b", "a"]) == ["b", "a"])
        // One name twice would be two positions; the first wins.
        #expect(SlotOrder(["a", "b", "a"]).names == ["a", "b"])
    }

    @Test("a drag puts the account in the row it was dropped on")
    func moving() {
        let list = ["a", "b", "c", "d"]
        #expect(SlotOrder.moving("d", onto: "a", in: list) == ["d", "a", "b", "c"])
        #expect(SlotOrder.moving("a", onto: "c", in: list) == ["b", "c", "a", "d"])
        #expect(SlotOrder.moving("a", onto: "d", in: list) == ["b", "c", "d", "a"])
        #expect(SlotOrder.moving("b", onto: "a", in: list) == ["b", "a", "c", "d"])
        #expect(SlotOrder.moving("a", onto: "a", in: list) == list)
        #expect(SlotOrder.moving("ghost", onto: "a", in: list) == list)
        #expect(SlotOrder.moving("a", onto: "ghost", in: list) == list)
    }

    @Test("a rename keeps the account's place, a removal takes it out")
    func renamedAndRemoved() {
        let order = SlotOrder(["pro", "perso", "spare"])
        #expect(order.renamed("perso", to: "perso-main").names == ["pro", "perso-main", "spare"])
        #expect(order.renamed("ghost", to: "new").names == order.names)
        #expect(order.without("pro").names == ["perso", "spare"])
        #expect(order.without("ghost").names == order.names)
    }

    /// The app lists accounts in this order and hands the policy each row's index, so
    /// dragging one up is what decides a tie.
    @Test("the stored order is the policy's tie-breaker")
    func feedsThePolicy() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let reset = now.addingTimeInterval(10 * 3600)
        func accounts(_ order: SlotOrder) -> [PolicyAccount] {
            var out = [PolicyAccount(name: "live", sessionPercent: 100)]
            // Two accounts with identical quota: nothing but the order separates them.
            out += order.sorted(["alpha", "beta"]).enumerated().map { index, name in
                PolicyAccount(name: name, order: index, sessionPercent: 0,
                              weeklyPercent: 50, weeklyResetsAt: reset)
            }
            return out
        }
        let engine = PolicyEngine()
        #expect(engine.evaluate(mode: .failover, accounts: accounts(SlotOrder()),
                                active: "live", now: now).target == "alpha")
        let dragged = SlotOrder(SlotOrder.moving("beta", onto: "alpha", in: ["alpha", "beta"]))
        #expect(engine.evaluate(mode: .failover, accounts: accounts(dragged),
                                active: "live", now: now).target == "beta")
    }
}
