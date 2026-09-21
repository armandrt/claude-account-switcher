import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// The state machine behind a click on a row: the switch, every way it can
/// fail, and Undo.  Nothing here touches the real keychain or the network.
@Suite("AppModel switching")
@MainActor
struct AppModelSwitchTests {
    @Test("a switch moves the live login, the config and the marker, and offers Undo")
    func switchSucceeds() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(world.model.busySlot == "pro")
        #expect(world.model.switchingTo == "pro")
        #expect(await settle { world.model.busySlot == nil })

        #expect(world.marker() == "pro")
        #expect(world.configEmail() == "pro@example.com")
        #expect(world.liveAccessToken() == "pro-access")
        // The live credentials were saved into the slot being left, first.
        #expect(world.storedAccessToken("perso2") == "live-access")
        #expect(world.backups().count == 1)
        #expect(world.model.undo == UndoOffer(from: "perso2", to: "pro"))
        #expect(world.model.actionError == nil)
        #expect(world.logText().contains("switched perso2 → pro"))
        await world.expectNothingStuck()
    }

    @Test("Undo is the reverse switch, and a second click has nothing left to take back")
    func undoOnceAndOnlyOnce() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.model.switchTo("pro")
        #expect(await settle { world.model.undo != nil })

        world.model.undoSwitch()
        // Double-clicked: the offer was consumed by the first click.
        world.model.undoSwitch()
        #expect(world.model.undo == nil)
        #expect(await settle { world.model.busySlot == nil })

        #expect(world.marker() == "perso2")
        #expect(world.configEmail() == "live@example.com")
        #expect(world.liveAccessToken() == "live-access")
        let switchedBack = world.model.log.entries.filter { $0.text.contains("switched pro → perso2") }
        #expect(switchedBack.count == 1)
        await world.expectNothingStuck()
    }

    @Test("Undo clicked while something else runs goes through as soon as the road is clear")
    func undoWhileBusy() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.model.switchTo("pro")
        #expect(await settle { world.model.undo != nil && world.model.busySlot == nil })

        // Undo is a switch: it is acknowledged at once and never told to wait.
        world.model.busySlot = "pro"
        world.model.undoSwitch()
        #expect(world.model.switchingTo == "perso2")
        #expect(world.model.actionError == nil)
        #expect(world.marker() == "pro", "nothing moves while the other action runs")

        world.model.busySlot = nil
        #expect(await settle { world.marker() == "perso2" })
        #expect(await settle { world.model.busySlot == nil && world.model.switchingTo == nil })
        await world.expectNothingStuck()
    }

    @Test("once the window has lapsed Undo does nothing at all")
    func undoAfterTheWindow() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.model.undoWindow = 0.05
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.undo != nil })
        #expect(await settle { world.model.undo == nil })

        world.model.undoSwitch()
        #expect(world.model.switchingTo == nil)
        #expect(world.model.busySlot == nil)
        #expect(world.marker() == "pro")
    }

    /// Switching is what the app is for, so a click is never answered with "wait":
    /// the row says so at once and the switch goes as soon as the road is clear.
    @Test("a switch clicked while another action runs waits its turn instead of being refused")
    func switchWaitsForABusyRow() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.busySlot = "perso2"
        world.model.switchTo("pro")
        #expect(world.model.switchingTo == "pro", "the click is acknowledged at once")
        #expect(world.model.actionError == nil, "and nobody is told to wait")
        #expect(world.marker() == "perso2", "nothing is written while the other action runs")

        // The other action finishes; the switch goes on its own.
        world.model.busySlot = nil
        #expect(await settle { world.marker() == "pro" })
        #expect(await settle { world.model.busySlot == nil && world.model.switchingTo == nil })
        #expect(world.liveAccessToken() == "pro-access")
        await world.expectNothingStuck()
    }

    @Test("a switch clicked during Refresh all stops the sweep and goes through")
    func switchPreemptsASweep() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.armUsage()
        await world.model.reloadSlots()
        // A floor long enough that the sweep is certainly still waiting when the click lands.
        world.model.budget = RateLimitBudget(base: 60, cap: 120, jitterFraction: 0, minimumSpacing: 30)
        world.model.budget.recordRequest(at: Date())

        world.model.refreshAll()
        #expect(world.model.sweepTask != nil)
        world.model.switchTo("pro")
        #expect(world.model.switchingTo == "pro")

        #expect(await settle { world.marker() == "pro" })
        #expect(await settle { world.model.sweepTask == nil && world.model.busySlot == nil })
        #expect(world.liveAccessToken() == "pro-access")
        #expect(world.model.actionError == nil)
        await world.expectNothingStuck()
    }

    // MARK: - One failure per step

    @Test("step 2: a name with no slot behind it fails before anything is written")
    func failsWithNoSuchSlot() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.switchTo("nothing-here")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError == "no slot named \"nothing-here\"")
        #expect(world.keychain.writeCount == 0)
        #expect(world.marker() == "perso2")
        #expect(world.configEmail() == "live@example.com")
        #expect(world.backups().isEmpty)
        #expect(world.model.undo == nil)
        await world.expectNothingStuck()
    }

    @Test("step 2: a corrupt target slot is refused, and the live login is untouched")
    func failsOnCorruptTarget() async throws {
        var items = AppWorld.defaultItems()
        items[AppWorld.prefix + "pro"] = Data("{\"credentials\": truncated".utf8)
        let world = try AppWorld(items: items)
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("slot \"pro\" cannot be loaded") == true)
        #expect(world.keychain.writeCount == 0)
        #expect(world.liveAccessToken() == "live-access")
        await world.expectNothingStuck()
    }

    @Test("step 3: unreadable live credentials stop the switch before the write-back")
    func failsOnUnreadableLive() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.keychain.box.readFailures[AppWorld.liveService] = .refused("the keychain said no")
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("cannot read the live credentials") == true)
        #expect(world.keychain.writeCount == 0)
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
        await world.expectNothingStuck()
    }

    @Test("step 4: a refused write-back stops everything else")
    func failsOnWriteBack() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.keychain.box.writeFailures[AppWorld.prefix + "perso2"] = .refused("no write for you")
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("could not save the live credentials back") == true)
        #expect(world.model.actionError?.contains("nothing was switched") == true)
        #expect(world.liveAccessToken() == "live-access")
        #expect(world.configEmail() == "live@example.com")
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
        await world.expectNothingStuck()
    }

    @Test("step 5: a backup that cannot be written stops the switch after the write-back")
    func failsOnBackup() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        // The dry run creates the lock file; the switch itself can then run in a
        // directory nothing new can be created in.
        world.model.requestSwitch(to: "pro")
        #expect(await settle { world.model.pendingSwitch != nil })
        world.model.cancelSwitch()
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                              ofItemAtPath: world.homeURL.path)

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("cannot write the backup") == true)
        #expect(world.backups().isEmpty)
        #expect(world.configEmail() == "live@example.com")
        #expect(world.marker() == "perso2")
        #expect(world.liveAccessToken() == "live-access")
        // Step 4 is the one step that did happen, which is the documented order.
        #expect(world.storedAccessToken("perso2") == "live-access")
        await world.expectNothingStuck()
    }

    @Test("step 7: a refused live keychain write puts .claude.json back")
    func failsOnLiveWrite() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        world.keychain.box.writeFailures[AppWorld.liveService] = .refused("not this build")
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("the live keychain item was not written") == true)
        #expect(world.model.actionError?.contains(".claude.json was put back") == true)
        #expect(world.configEmail() == "live@example.com")
        #expect(world.marker() == "perso2")
        #expect(world.liveAccessToken() == "live-access")
        #expect(world.backups().count == 1)
        #expect(world.model.undo == nil)
        await world.expectNothingStuck()
    }

    @Test("step 8: a marker that cannot be written undoes the switch")
    func failsOnMarker() async throws {
        let world = try AppWorld(active: nil)
        defer { world.cleanUp() }
        // A directory where the marker goes: readable as nothing, writable never.
        try FileManager.default.createDirectory(at: world.markerURL, withIntermediateDirectories: true)
        await world.model.reloadSlots()

        world.model.switchTo("pro")
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("the active-login marker was not written") == true)
        #expect(world.model.actionError?.contains("the switch was undone") == true)
        #expect(world.configEmail() == "live@example.com")
        #expect(world.liveAccessToken() == "live-access")
        #expect(world.model.undo == nil)
        await world.expectNothingStuck()
    }

    // MARK: - The ⌥ path

    @Test("a dry run writes nothing and is refused once the world has moved")
    func dryRunThenChanged() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.switchTo("pro", showPlan: true)
        #expect(await settle { world.model.pendingSwitch != nil })
        #expect(world.model.pendingSwitch?.to.name == "pro")
        #expect(world.model.pendingSwitch?.performed == false)
        #expect(world.keychain.writeCount == 0)
        #expect(world.marker() == "perso2")

        // Someone signed in to that slot while the plan was on screen.
        world.keychain.box.items[AppWorld.prefix + "pro"] =
            AppWorld.slot(access: "pro-access", email: "someone-else@example.com")
        world.model.confirmSwitch()
        #expect(await settle { world.model.busySlot == nil })
        #expect(world.model.actionError?.contains("the accounts moved since that was shown") == true)
        #expect(world.marker() == "perso2")
        #expect(world.keychain.writeCount == 0)
    }

    @Test("a slot that changed health stops explaining itself the old way")
    func healthChangeRefreshesTheExplanation() async throws {
        var items = AppWorld.defaultItems()
        items[AppWorld.prefix + "pro"] = AppWorld.slot(access: "pro-access", email: "pro@example.com",
                                                       expiresIn: -60)
        let world = try AppWorld(items: items)
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        #expect(world.model.rows.first { $0.name == "pro" }?.problem == "access token expired")

        world.keychain.box.items[AppWorld.prefix + "pro"] =
            AppWorld.slot(access: "renewed", email: "pro@example.com")
        await world.model.reloadSlots()
        #expect(world.model.rows.first { $0.name == "pro" }?.problem == nil)

        world.keychain.box.items[AppWorld.prefix + "pro"] = Data("nonsense".utf8)
        await world.model.reloadSlots()
        #expect(world.model.rows.first { $0.name == "pro" }?.problem?.hasPrefix("corrupt slot:") == true)
    }
}
