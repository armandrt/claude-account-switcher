import Foundation
import Testing
@testable import SwitcherCore

@Suite("Slot store")
struct SlotStoreTests {
    static func goodPayload(access: String = "sk-ant-oat01-aaaa",
                            expiresAt: Double = 4_000_000_000_000,
                            refreshExpiresAt: Double = 5_000_000_000_000,
                            email: String = "someone@example.com") -> Data {
        Data("""
        {"credentials":{"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"refresh",
          "expiresAt":\(expiresAt),"refreshTokenExpiresAt":\(refreshExpiresAt),
          "scopes":["user:profile","user:inference"],"subscriptionType":"max",
          "rateLimitTier":"default_claude_max_20x"}},
         "oauthAccount":{"emailAddress":"\(email)","organizationRateLimitTier":"default_claude_max_20x",
          "organizationName":"Someone"}}
        """.utf8)
    }

    /// Valid JSON up to a point, then cut off, like a slot `security -i` truncated.
    static let truncatedPayload = Data(
        #"{"credentials":{"mcpOAuth":{"atlassian|60c8":{"serverName":"atlas"#.utf8)

    static func store(activeName: String?, items: [String: Data],
                      failures: [String: KeychainError] = [:],
                      repair: SlotStore.AccessRepair? = nil) throws -> SlotStore {
        let keychain = FakeKeychain()
        keychain.box.items = items
        keychain.box.failures = failures
        let marker = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-active-login-\(UUID().uuidString)")
        if let activeName {
            try Data(activeName.utf8).write(to: marker)
        }
        // Never nil by accident: behind a fake reader the store must wire no repair at
        // all, or the suite would rewrite items in the real keychain.
        let effective: SlotStore.AccessRepair = repair ?? { _ in nil }
        return SlotStore(reader: keychain, loginPrefix: "CAS Test Login: ",
                         liveService: "CAS Test Live", activeLoginURL: marker,
                         repair: effective)
    }

    /// Counts what the store asked it to repair, and answers with whatever it was given.
    final class Repairs: @unchecked Sendable {
        let lock = NSLock()
        var asked: [String] = []
        var answer: Data?

        init(answer: Data? = nil) { self.answer = answer }

        var repair: SlotStore.AccessRepair {
            { [self] service in
                lock.lock()
                defer { lock.unlock() }
                asked.append(service)
                return answer
            }
        }
    }

    @Test("lists the slots, reads the live item, and names the active one")
    func listsSlots() throws {
        let store = try Self.store(activeName: "perso2", items: [
            "CAS Test Login: perso": Self.goodPayload(),
            "CAS Test Login: perso2": Self.goodPayload(access: "sk-ant-oat01-bbbb"),
            "CAS Test Login: pro": Self.truncatedPayload,
            "CAS Test Live": Data(#"{"claudeAiOauth":{"accessToken":"sk-ant-oat01-live","refreshToken":"r","expiresAt":4000000000000,"refreshTokenExpiresAt":5000000000000,"scopes":["user:profile"]}}"#.utf8),
            "Some Other Service": Data("{}".utf8),
        ])
        #expect(try store.slotNames() == ["perso", "perso2", "pro"])
        #expect(store.activeSlotName() == "perso2")

        let slots = store.slots(now: Date(timeIntervalSince1970: 1_000_000))
        #expect(slots.map(\.name) == ["perso", "perso2", "pro"])
        #expect(slots.map(\.isActive) == [false, true, false])

        // The active slot's numbers come from the live item; its email from the snapshot.
        let active = try #require(slots.first { $0.isActive })
        #expect(active.credentials?.accessToken == "sk-ant-oat01-live")
        #expect(active.usesLiveCredentials)
        #expect(active.health == .ok)
        #expect(active.email == "someone@example.com")
        #expect(active.planTier == "default_claude_max_20x")

        let inactive = try #require(slots.first { $0.name == "perso" })
        #expect(inactive.credentials?.accessToken == "sk-ant-oat01-aaaa")
        #expect(inactive.usesLiveCredentials == false)
    }

    @Test("a truncated payload is a corrupt slot, not a crash")
    func truncatedSlot() throws {
        let store = try Self.store(activeName: "perso", items: [
            "CAS Test Login: pro": Self.truncatedPayload,
        ])
        let slot = try #require(store.slots().first)
        #expect(slot.name == "pro")
        #expect(slot.health.label == "corrupt")
        #expect(slot.health.detail?.contains("truncated") == true)
        #expect(slot.byteCount == Self.truncatedPayload.count)
        #expect(slot.credentials == nil)
    }

    @Test("expiry drives credential health")
    func health() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let store = try Self.store(activeName: nil, items: [
            "CAS Test Login: fresh": Self.goodPayload(),
            "CAS Test Login: stale": Self.goodPayload(expiresAt: 500_000_000),
            "CAS Test Login: dead": Self.goodPayload(expiresAt: 500_000_000,
                                                     refreshExpiresAt: 900_000_000),
        ])
        var byName: [String: Slot] = [:]
        for slot in store.slots(now: now) { byName[slot.name] = slot }
        #expect(byName["fresh"]?.health == .ok)
        #expect(byName["stale"]?.health == .expired)
        #expect(byName["dead"]?.health == .needsRelogin)
        #expect(byName["dead"]?.health.isUsable == false)
    }

    @Test("a keychain that will not hand over an item is reported, not fatal")
    func unreadable() throws {
        let store = try Self.store(activeName: nil,
                              items: ["CAS Test Login: locked": Data()],
                              failures: ["CAS Test Login: locked":
                                            .interactionRequired("CAS Test Login: locked")])
        let slot = try #require(store.slots().first)
        #expect(slot.health.label == "unreadable")
        #expect(slot.health.isUsable == false)
    }

    @Test("only an item security(1) ran and was refused is worth rewriting")
    func repairIsOfferedOnlyWhereItCanHelp() {
        #expect(SlotStore.isWorthRepairing(KeychainError.cliFailed(1, "x")))
        #expect(SlotStore.isWorthRepairing(KeychainError.cliFailed(51, "x")))
        // Nothing to repair, and a `security` that would not start would fail the
        // rewrite too — after the delete that makes room for it.
        #expect(SlotStore.isWorthRepairing(KeychainError.itemNotFound("x")) == false)
        #expect(SlotStore.isWorthRepairing(KeychainError.cliFailed(44, "x")) == false)
        #expect(SlotStore.isWorthRepairing(KeychainError.cliFailed(-1, "x")) == false)
        #expect(SlotStore.isWorthRepairing(KeychainError.interactionRequired("x")) == false)
        #expect(SlotStore.isWorthRepairing(KeychainError.status(-25300, "x")) == false)

        // Behind an injected reader there is no repair wired at all, so the suite can
        // never rewrite an item in the real keychain.
        let fake = SlotStore(reader: FakeKeychain(), loginPrefix: "CAS Test Login: ")
        #expect(fake.repair == nil)
    }

    @Test("a prompted item is settled only against the real keychain")
    func settlesOnlyTheRealKeychain() throws {
        // The rewrite that ends the asking deletes and writes a real keychain item, so behind
        // an injected reader it must not happen at all — the suite would be rewriting the
        // owner's logins.
        let service = "CAS Test Login: prompted"
        KeychainAudit.note(prompted: service)
        defer { KeychainAudit.clearPrompt(service) }

        let store = try Self.store(activeName: nil, items: [service: Self.goodPayload()])
        #expect(store.slots().count == 1)
        #expect(KeychainAudit.didPrompt(service))
    }

    @Test("a refused read is repaired once; a missing item never is")
    func repairsARefusedRead() throws {
        let repairs = Repairs(answer: Self.goodPayload(access: "sk-ant-oat01-repaired"))
        let store = try Self.store(
            activeName: nil, items: ["CAS Test Login: locked": Data()],
            failures: ["CAS Test Login: locked": .cliFailed(51, "CAS Test Login: locked")],
            repair: repairs.repair)
        let slot = try #require(store.slots().first)
        #expect(repairs.asked == ["CAS Test Login: locked"])
        #expect(slot.health == .ok)
        #expect(slot.credentials?.accessToken == "sk-ant-oat01-repaired")

        // A read that says the item is not there is left alone.
        let missing = Repairs(answer: Self.goodPayload())
        let gone = try Self.store(
            activeName: nil, items: ["CAS Test Login: gone": Data()],
            failures: ["CAS Test Login: gone": .itemNotFound("CAS Test Login: gone")],
            repair: missing.repair)
        #expect(gone.slots().first?.health.label == "unreadable")
        #expect(missing.asked.isEmpty)
    }

    @Test("a repair that could not finish leaves the slot unreadable, not pretend-fine")
    func failedRepairIsNotHidden() throws {
        let repairs = Repairs(answer: nil)
        let store = try Self.store(
            activeName: nil, items: ["CAS Test Login: locked": Data()],
            failures: ["CAS Test Login: locked": .cliFailed(51, "CAS Test Login: locked")],
            repair: repairs.repair)
        let slot = try #require(store.slots().first)
        #expect(repairs.asked == ["CAS Test Login: locked"])
        #expect(slot.health.label == "unreadable")
        #expect(slot.credentials == nil)
    }

    @Test("no live item at all still yields slots")
    func noLiveItem() throws {
        let store = try Self.store(activeName: "perso",
                              items: ["CAS Test Login: perso": Self.goodPayload()])
        let slot = try #require(store.slots().first)
        #expect(slot.isActive)
        #expect(slot.usesLiveCredentials == false)
        #expect(slot.credentials?.accessToken == "sk-ant-oat01-aaaa")
    }

    @Test("interpolating credentials never prints a token")
    func redactedDescription() throws {
        let payload = try CredentialPayload.parse(Self.goodPayload(access: "sk-ant-oat01-secret"))
        let text = "\(payload.credentials)"
        #expect(text.contains("sk-ant-oat01-secret") == false)
        #expect(text.contains("…cret>"))
        #expect("\(payload)".contains("sk-ant-oat01-secret") == false)
    }
}
