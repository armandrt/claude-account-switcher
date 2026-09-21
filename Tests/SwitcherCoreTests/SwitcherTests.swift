import Foundation
import Testing
@testable import SwitcherCore

/// The swap, end to end, inside a temporary directory against an in-memory keychain.
@Suite("Switcher")
struct SwitcherTests {
    static func slot(access: String, email: String, refreshExpires: Double = 5_000_000_000_000) -> Data {
        Data("""
        {"credentials":{"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"refresh-\(access)",
          "expiresAt":4000000000000,"refreshTokenExpiresAt":\(refreshExpires),
          "scopes":["user:profile","user:inference"],"subscriptionType":"max"},
          "mcpOAuth":{"atlassian|abc":{"token":"keep-me"}}},
         "oauthAccount":{"emailAddress":"\(email)","organizationRateLimitTier":"default_claude_max_20x",
          "accountUuid":"0000-\(access)"}}
        """.utf8)
    }

    static func liveItem(access: String) -> Data {
        Data("""
        {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"rotated-\(access)",
          "expiresAt":4000000000000,"refreshTokenExpiresAt":5000000000000,
          "scopes":["user:profile"],"subscriptionType":"max"}}
        """.utf8)
    }

    static func world(activeName: String? = "perso2", config: Data? = nil,
                      backupsKept: Int = 10) throws -> TempWorld {
        try TempWorld(activeName: activeName, items: [
            TempWorld.prefix + "perso2": slot(access: "stale-perso2", email: "live@example.com"),
            TempWorld.prefix + "pro": slot(access: "pro-access", email: "pro@example.com"),
            TempWorld.live: liveItem(access: "live-access"),
        ], config: config, backupsKept: backupsKept)
    }

    @Test("a dry run says exactly what it would do and writes nothing")
    func dryRun() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        let plan = try world.switcher.switchTo("pro", dryRun: true)
        #expect(plan.performed == false)
        #expect(plan.from?.name == "perso2")
        #expect(plan.from?.email == "live@example.com")
        #expect(plan.to.name == "pro")
        #expect(plan.to.email == "pro@example.com")
        #expect(plan.to.planTier == "default_claude_max_20x")
        #expect(plan.headline == "perso2 (live@example.com) → pro (pro@example.com)")

        let titles = plan.steps.map(\.title)
        #expect(titles == ["save the live credentials back into \"perso2\"",
                           "back up .claude.json",
                           "set oauthAccount in .claude.json",
                           "write the live keychain item",
                           "record the active login"])
        #expect(plan.steps.filter(\.done).isEmpty)

        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.keychain.box.items[TempWorld.live] == Self.liveItem(access: "live-access"))
    }

    @Test("a real switch writes back first, moves one key, and records the new login")
    func realSwitch() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try String(contentsOf: world.configURL, encoding: .utf8)

        let plan = try world.switcher.switchTo("pro", dryRun: false)
        #expect(plan.performed)
        #expect(plan.steps.filter { !$0.done }.isEmpty)

        let savedBack = try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.prefix + "perso2"]))
        #expect(savedBack.credentials.accessToken == "live-access")
        #expect(savedBack.credentials.refreshToken == "rotated-live-access")
        #expect(savedBack.account?.emailAddress == "live@example.com")

        let json = try world.configJSON()
        let account = try #require(json["oauthAccount"] as? [String: Any])
        #expect(account["emailAddress"] as? String == "pro@example.com")
        #expect(json.count == 5)
        #expect(json["numStartups"] as? Int == 8)
        #expect(json["installMethod"] as? String == "native")

        // Only the oauthAccount span is rewritten; the other keys keep their spelling and spacing.
        let after = try String(contentsOf: world.configURL, encoding: .utf8)
        #expect(after.contains("  \"numStartups\": 8,\n"))
        #expect(after.contains("\"autoCompactWindowsCache\": 0.5"))
        #expect(after.contains("\"command\": \"/usr/bin/env\""))
        #expect(before.contains("live@example.com"))
        #expect(after.contains("live@example.com") == false)

        let liveNow = try #require(world.keychain.box.items[TempWorld.live])
        #expect(try CredentialPayload.parse(liveNow, liveShape: true).credentials.accessToken == "pro-access")
        let liveRoot = try #require(try JSONSerialization.jsonObject(with: liveNow) as? [String: Any])
        #expect(liveRoot["mcpOAuth"] != nil)
        #expect(world.keychain.box.writes.first { $0.service == TempWorld.live }?.label == "")

        #expect(world.marker() == "pro")
        #expect(world.backups().count == 1)
        #expect(plan.backupURL?.lastPathComponent.hasPrefix(".claude.json.bak.") == true)
        let backup = try String(contentsOf: try #require(plan.backupURL), encoding: .utf8)
        #expect(backup == before)
    }

    @Test("the lock stops a second switch instead of interleaving with it")
    func lockIsHeld() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let lockURL = world.directory.appendingPathComponent("switch.lock")
        let held = try FileLock(url: lockURL)
        #expect(held.tryLock())
        defer { held.unlock() }

        #expect(throws: SwitchError.busy("another switch holds switch.lock")) {
            try world.switcher.switchTo("pro", dryRun: false)
        }
        #expect(throws: (any Error).self) { try world.switcher.switchTo("pro", dryRun: true) }
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.writes.isEmpty)

        held.unlock()
        #expect(try world.switcher.switchTo("pro", dryRun: false).performed)
    }

    @Test("a truncated slot fails before anything is written")
    func corruptSlot() throws {
        let world = try TempWorld(activeName: "perso2", items: [
            TempWorld.prefix + "pro": SlotStoreTests.truncatedPayload,
            TempWorld.live: Self.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        #expect(throws: (any Error).self) { try world.switcher.switchTo("pro", dryRun: true) }
        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("a corrupt slot must not switch")
        } catch let error as SwitchError {
            guard case .slotUnusable(let name, let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "pro")
            #expect(why.contains("truncated"))
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
        #expect(world.keychain.box.writes.isEmpty)
    }

    @Test("a slot with no account of its own never blanks .claude.json's")
    func slotWithoutAnAccount() throws {
        let nameless = Data("""
        {"credentials":{"claudeAiOauth":{"accessToken":"nameless-access","refreshToken":"r",
          "expiresAt":4000000000000,"refreshTokenExpiresAt":5000000000000,
          "scopes":["user:profile"]}},"oauthAccount":{}}
        """.utf8)
        let world = try TempWorld(activeName: "perso2", items: [
            TempWorld.prefix + "perso2": Self.slot(access: "stale", email: "live@example.com"),
            TempWorld.prefix + "blank": nameless,
            TempWorld.live: Self.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        // The slot's oauthAccount is spliced in verbatim, so `{}` would leave Claude
        // Code with no account at all.
        do {
            try world.switcher.switchTo("blank", dryRun: false)
            Issue.record("a slot with no account must not switch")
        } catch let error as SwitchError {
            guard case .slotUnusable(let name, let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "blank")
            #expect(why.contains("oauthAccount"))
        }
        #expect(throws: (any Error).self) { try world.switcher.switchTo("blank", dryRun: true) }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.backups().isEmpty)

        // With nothing to lose in .claude.json, the same slot is allowed through.
        let empty = try TempWorld(
            activeName: nil,
            items: [TempWorld.prefix + "blank": nameless,
                    TempWorld.live: Self.liveItem(access: "live-access")],
            config: Data(#"{"numStartups":1}"#.utf8))
        defer { empty.cleanUp() }
        #expect(try empty.switcher.switchTo("blank", dryRun: false).performed)
    }

    @Test("an unknown slot and a bad name are refused by name alone")
    func refusals() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        #expect(throws: SwitchError.noSuchSlot("nope")) {
            try world.switcher.switchTo("nope", dryRun: true)
        }
        #expect(throws: SwitchError.badName("../../etc/passwd")) {
            try world.switcher.switchTo("../../etc/passwd", dryRun: true)
        }
        #expect(Switcher.isValidName("perso2"))
        #expect(Switcher.isValidName("a.b-c_d"))
        #expect(Switcher.isValidName("") == false)
        #expect(Switcher.isValidName("Claude Code Login: x") == false)
    }

    @Test("a .claude.json that will not parse is never written over")
    func invalidConfig() throws {
        let world = try Self.world(config: Data(#"{"numStartups": 8, "oauthAccount": {"#.utf8))
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        #expect(throws: (any Error).self) { try world.switcher.switchTo("pro", dryRun: false) }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.backups().isEmpty)
    }

    @Test("a live keychain write that fails puts .claude.json back")
    func keychainFailureRollsBack() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)
        world.keychain.box.writeFailures[TempWorld.live] = .status(-25293, TempWorld.live)

        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .keychainFailed(_, let rolledBack) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(rolledBack)
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        // The write-back happened and is harmless: the credentials it saved are still live.
        #expect(world.keychain.box.items[TempWorld.prefix + "perso2"] != nil)
        #expect(world.backups().count == 1)
    }

    @Test("a live write that lands as something else is caught and the live item put back")
    func truncatedWriteIsCaught() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)
        world.keychain.box.truncateWritesOnce.insert(TempWorld.live)

        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .keychainFailed(let why, let rolledBack) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(why.contains("came back as"))
            #expect(rolledBack)
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.items[TempWorld.live] == Self.liveItem(access: "live-access"))
    }

    @Test("a live item that cannot be put back is reported as not rolled back")
    func truncatedWriteThatWillNotRestore() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.truncateWrites.insert(TempWorld.live)

        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .keychainFailed(_, let rolledBack) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(rolledBack == false)
            #expect(error.description.contains("may not have been put back"))
        }
        #expect(world.marker() == "perso2")
    }

    @Test("a write-back that fails stops the switch before anything else moves")
    func writeBackFailureAborts() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)
        world.keychain.box.writeFailures[TempWorld.prefix + "perso2"] =
            .refused(TempWorld.prefix + "perso2")

        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .writeBackFailed(let name, _) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "perso2")
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
        #expect(try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.live]),
            liveShape: true).credentials.accessToken == "live-access")
    }

    @Test("a write-back the keychain mangles is reported as a write-back failure")
    func writeBackVerificationFailure() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)
        world.keychain.box.truncateWrites.insert(TempWorld.prefix + "perso2")

        do {
            try world.switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .writeBackFailed(let name, let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(name == "perso2")
            #expect(why.contains("came back as"))
            #expect(error.description.contains("nothing was switched"))
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "perso2")
        #expect(world.backups().isEmpty)
    }

    @Test("live credentials that cannot be read stop the switch rather than stranding them")
    func unreadableLiveCredentials() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        world.keychain.box.failures[TempWorld.live] = .interactionRequired(TempWorld.live)

        #expect(throws: (any Error).self) { try world.switcher.switchTo("pro", dryRun: true) }
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.writes.isEmpty)
    }

    @Test("a marker that cannot be written undoes the switch")
    func markerFailureRollsBack() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)
        // A readable marker in a directory that will not accept a write.
        let locked = world.directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let marker = locked.appendingPathComponent("active-login")
        try Data("perso2\n".utf8).write(to: marker)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700],
                                                       ofItemAtPath: locked.path) }
        let switcher = Switcher(
            reader: world.keychain, writer: world.keychain,
            loginPrefix: TempWorld.prefix, liveService: TempWorld.live,
            paths: Switcher.Paths(config: world.configURL, activeLogin: marker,
                                  lock: world.directory.appendingPathComponent("switch.lock")))

        do {
            try switcher.switchTo("pro", dryRun: false)
            Issue.record("the switch should have failed")
        } catch let error as SwitchError {
            guard case .markerFailed(_, let rolledBack) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(rolledBack)
        }
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(try String(contentsOf: marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "perso2")
        #expect(world.keychain.box.items[TempWorld.live] == Self.liveItem(access: "live-access"))
    }

    @Test("backups are pruned to the last ten")
    func prunesBackups() throws {
        let world = try Self.world(backupsKept: 3)
        defer { world.cleanUp() }
        for index in 1...5 {
            try Data("old".utf8).write(to: world.directory
                .appendingPathComponent(".claude.json.bak.2026090\(index)000000"))
        }
        let plan = try world.switcher.switchTo("pro", dryRun: false)
        #expect(plan.prunedBackups == 3)
        let kept = world.backups()
        #expect(kept.count == 3)
        #expect(kept.contains(".claude.json.bak.20260904000000"))
        #expect(kept.contains(".claude.json.bak.20260901000000") == false)

        let next = try world.switcher.switchTo("perso2", dryRun: true)
        #expect(next.steps.last?.title == "prune old backups")
    }

    @Test("a plan that no longer matches the world is refused at confirmation")
    func staleConfirmation() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let plan = try world.switcher.switchTo("pro", dryRun: true)

        // A `claude-acct login pro` in a terminal moved the marker AND the live account.
        try Data("pro\n".utf8).write(to: world.markerURL)
        try TempWorld.config(email: "pro@example.com").write(to: world.configURL)
        #expect(throws: SwitchError.changed("pro (pro@example.com) → pro (pro@example.com)")) {
            try world.switcher.switchTo("pro", dryRun: false, confirming: plan)
        }
        #expect(try world.switcher.switchTo("pro", dryRun: false).performed)
    }

    @Test("a confirmed plan is refused when the target slot now holds another account")
    func confirmationChecksTheAccount() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let plan = try world.switcher.switchTo("pro", dryRun: true)

        world.keychain.box.items[TempWorld.prefix + "pro"] = Self.slot(access: "other", email: "other@example.com")
        #expect(throws: SwitchError.changed("perso2 (live@example.com) → pro (other@example.com)")) {
            try world.switcher.switchTo("pro", dryRun: false, confirming: plan)
        }
        #expect(world.keychain.box.writes.isEmpty)
        #expect(world.marker() == "perso2")
    }

    @Test("no recorded active login is a warning, not a refusal")
    func noActiveLogin() throws {
        let world = try Self.world(activeName: nil)
        defer { world.cleanUp() }
        let plan = try world.switcher.switchTo("pro", dryRun: true)
        #expect(plan.from == nil)
        #expect(plan.warnings.contains { $0.contains("not saved anywhere first") })
        #expect(plan.steps.first?.title == "back up .claude.json")

        #expect(try world.switcher.switchTo("pro", dryRun: false).performed)
        #expect(world.marker() == "pro")
    }

    /// The live item holds a rotated refresh token the slot does not; loading the slot over
    /// it would kill that account.  A same-account switch refreshes the slot and stops.
    @Test("switching to the account already live refreshes its snapshot and touches nothing else")
    func sameAccount() throws {
        let world = try Self.world()
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        let plan = try world.switcher.switchTo("perso2", dryRun: true)
        #expect(plan.isNoOp)
        #expect(plan.warnings.contains { $0.contains("already the active login") })
        #expect(plan.steps.map(\.title) == ["save the live credentials back into \"perso2\""])

        let done = try world.switcher.switchTo("perso2", dryRun: false)
        #expect(done.performed)
        let saved = try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.prefix + "perso2"]))
        #expect(saved.credentials.accessToken == "live-access")
        #expect(saved.credentials.refreshToken == "rotated-live-access")
        #expect(world.keychain.box.items[TempWorld.live] == Self.liveItem(access: "live-access"))
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.backups().isEmpty)
        #expect(world.marker() == "perso2")
    }

    @Test("a slot whose refresh token has died still switches, with a warning")
    func deadRefreshTokenWarns() throws {
        let world = try TempWorld(activeName: "perso2", items: [
            TempWorld.prefix + "perso2": Self.slot(access: "s", email: "live@example.com"),
            TempWorld.prefix + "old": Self.slot(access: "o", email: "old@example.com",
                                                refreshExpires: 1_000),
            TempWorld.live: Self.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }
        let plan = try world.switcher.switchTo("old", dryRun: true)
        #expect(plan.warnings.contains { $0.contains("refresh token is past its expiry") })
    }

    /// `/login` moved the live login to live@example.com but the marker still says "pro".
    /// The write-back must go to the slot that really holds the live account.
    @Test("a stale marker saves the live login back into the slot that really holds it")
    func staleMarkerHeals() throws {
        let world = try Self.world(activeName: "pro")
        defer { world.cleanUp() }

        let plan = try world.switcher.switchTo("pro", dryRun: false)
        #expect(plan.performed)
        #expect(plan.from?.name == "perso2")
        #expect(plan.warnings.contains { $0.contains("the marker said \"pro\"") })

        let savedBack = try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.prefix + "perso2"]))
        #expect(savedBack.credentials.accessToken == "live-access")
        #expect(savedBack.account?.emailAddress == "live@example.com")
        #expect(world.keychain.box.writes.contains { $0.service == TempWorld.prefix + "pro" } == false)
        #expect(world.marker() == "pro")
    }

    @Test("clicking the slot that really holds the live login fixes a stale marker")
    func staleMarkerFixedByTheRealHolder() throws {
        let world = try Self.world(activeName: "pro")
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        let plan = try world.switcher.switchTo("perso2", dryRun: false)
        #expect(plan.performed)
        #expect(plan.isNoOp)
        #expect(plan.steps.map(\.title) == ["save the live credentials back into \"perso2\"",
                                            "record the active login"])
        #expect(plan.steps.filter { !$0.done }.isEmpty)
        #expect(world.marker() == "perso2")
        #expect(world.keychain.box.items[TempWorld.live] == Self.liveItem(access: "live-access"))
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.keychain.box.writes.map(\.service) == [TempWorld.prefix + "perso2"])
    }

    @Test("a stale marker with nowhere to save the live login refuses to switch")
    func staleMarkerRefuses() throws {
        let world = try TempWorld(activeName: "pro", items: [
            TempWorld.prefix + "perso2": Self.slot(access: "stale-perso2", email: "live@example.com"),
            TempWorld.prefix + "pro": Self.slot(access: "pro-access", email: "pro@example.com"),
            TempWorld.live: Self.liveItem(access: "live-access"),
        ], config: TempWorld.config(email: "nobody@example.com"))
        defer { world.cleanUp() }
        let before = try Data(contentsOf: world.configURL)

        #expect(throws: SwitchError.markerStale("pro", liveEmail: "nobody@example.com",
                                                storedEmail: "pro@example.com")) {
            try world.switcher.switchTo("perso2", dryRun: false)
        }
        #expect(world.keychain.box.writes.isEmpty)
        #expect(try Data(contentsOf: world.configURL) == before)
        #expect(world.marker() == "pro")
    }

    @Test("a marker naming a slot with no readable email is trusted when no other slot holds the login")
    func markerWithUnreadableSlotIsTrusted() throws {
        let world = try TempWorld(activeName: "broken", items: [
            TempWorld.prefix + "broken": Data("{\"credentials\":{\"claudeAiOauth\":{\"accessToken\":\"x\"".utf8),
            TempWorld.prefix + "pro": Self.slot(access: "pro-access", email: "pro@example.com"),
            TempWorld.live: Self.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }
        let plan = try world.switcher.switchTo("pro", dryRun: false)
        #expect(plan.performed)
        #expect(plan.from?.name == "broken")
        let repaired = try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.prefix + "broken"]))
        #expect(repaired.credentials.accessToken == "live-access")
    }

    @Test("a marker naming a corrupt slot defers to the slot that really holds the live login")
    func markerNamingACorruptSlotDefersToTheRealHolder() throws {
        let world = try TempWorld(activeName: "broken", items: [
            TempWorld.prefix + "broken": SlotStoreTests.truncatedPayload,
            TempWorld.prefix + "perso2": Self.slot(access: "stale-perso2", email: "live@example.com"),
            TempWorld.prefix + "pro": Self.slot(access: "pro-access", email: "pro@example.com"),
            TempWorld.live: Self.liveItem(access: "live-access"),
        ])
        defer { world.cleanUp() }

        let plan = try world.switcher.switchTo("pro", dryRun: false)
        #expect(plan.performed)
        #expect(plan.from?.name == "perso2")
        #expect(world.keychain.box.items[TempWorld.prefix + "broken"] == SlotStoreTests.truncatedPayload)
        let saved = try CredentialPayload.parse(
            try #require(world.keychain.box.items[TempWorld.prefix + "perso2"]))
        #expect(saved.credentials.accessToken == "live-access")
        #expect(world.marker() == "pro")
    }
}
