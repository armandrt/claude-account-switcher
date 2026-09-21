import Foundation
import Testing
@testable import SwitcherCore

/// The only tests that touch the real keychain, and only under `CAS Test Login: `.  They are
/// opt-in (`CAS_KEYCHAIN_TESTS=1`) because an ad-hoc signed build gets a new identity on
/// every rebuild and macOS may ask for a password.
let touchesKeychain = ProcessInfo.processInfo.environment["CAS_KEYCHAIN_TESTS"] != nil

@Suite("Keychain writes", .serialized)
struct KeychainWriteTests {
    static let prefix = "CAS Test Login: "

    @Test("refuses the live item and anything outside the injected prefix")
    func guards() {
        let writer = SystemKeychainWriter(servicePrefix: Self.prefix)
        #expect(throws: (any Error).self) {
            try writer.write(Data("x".utf8), service: "Claude Code-credentials", label: "no")
        }
        #expect(throws: (any Error).self) {
            try writer.write(Data("x".utf8), service: "Claude Code Login: perso", label: "no")
        }
        #expect(throws: (any Error).self) {
            try writer.delete(service: "Claude Code Login: perso")
        }
        let production = SystemKeychainWriter(servicePrefix: "Claude Code Login: ")
        #expect(throws: (any Error).self) {
            try production.write(Data("x".utf8), service: "Claude Code-credentials", label: "no")
        }
    }

    @Test("round trip: add, read, update, delete", .enabled(if: touchesKeychain))
    func roundTrip() throws {
        let name = "cas-selftest-\(UUID().uuidString.prefix(8))"
        let service = Self.prefix + name
        let writer = SystemKeychainWriter(servicePrefix: Self.prefix)
        let reader = SystemKeychainReader()
        defer { try? writer.delete(service: service) }

        let first = SlotStoreTests.goodPayload(access: "sk-ant-oat01-first")
        try writer.write(first, service: service, label: "Claude Account Switcher self-test")

        #expect(try reader.services(withPrefix: Self.prefix).contains(service))
        let readBack = try reader.data(forService: service)
        #expect(readBack == first)
        #expect(try CredentialPayload.parse(readBack).credentials.accessToken == "sk-ant-oat01-first")

        // An update must replace the payload, not add a second item.
        let payload = try CredentialPayload.parse(first)
        let rotated = try payload.withRotatedTokens(accessToken: "sk-ant-oat01-second",
                                                    refreshToken: "rotated", expiresAt: 4_100_000_000_000)
        try writer.write(rotated, service: service, label: "Claude Account Switcher self-test")
        let updated = try CredentialPayload.parse(try reader.data(forService: service))
        #expect(updated.credentials.accessToken == "sk-ant-oat01-second")
        #expect(updated.credentials.refreshToken == "rotated")
        #expect(updated.account?.emailAddress == "someone@example.com")
        #expect(try reader.services(withPrefix: Self.prefix).filter { $0 == service }.count == 1)

        try writer.delete(service: service)
        #expect(try reader.services(withPrefix: Self.prefix).contains(service) == false)
        #expect(throws: (any Error).self) { try reader.data(forService: service) }
    }

    @Test("bytes an argument cannot carry are refused before anything is spawned")
    func refusesUncarriableBytes() {
        let writer = SystemKeychainWriter(servicePrefix: Self.prefix)
        let service = Self.prefix + "cas-never-written"
        // An argv string stops at the first NUL, so `security` would store a truncated
        // payload and exit 0 — exactly how the `pro` slot died.
        let withNUL = Data([0x7b, 0x22, 0x61, 0x00, 0x22, 0x7d])
        #expect(throws: (any Error).self) {
            try writer.write(withNUL, service: service, label: "no")
        }
        // 0xff is not valid UTF-8.
        let notUTF8 = Data([0x7b, 0xff, 0x7d])
        #expect(throws: (any Error).self) {
            try writer.write(notUTF8, service: service, label: "no")
        }
        #expect(SystemKeychainWriter.isCarriable(withNUL) == false)
        #expect(SystemKeychainWriter.isCarriable(notUTF8) == false)
        #expect(SystemKeychainWriter.isCarriable(Data()) == false)
        #expect(SystemKeychainWriter.isCarriable(Data(#"{"é":"ok\n"}"#.utf8)))
    }

    @Test("a repair refuses bytes it could not write back, rather than deleting first")
    func normaliseRefusesUnwritableBytes() {
        let writer = SystemKeychainWriter(servicePrefix: Self.prefix)
        // The guard is ahead of the delete, so nothing is spawned and nothing is removed.
        #expect(throws: (any Error).self) {
            try writer.normaliseAccess(service: Self.prefix + "cas-never-deleted",
                                       data: Data([0x7b, 0x00, 0x7d]), label: "no")
        }
        #expect(throws: (any Error).self) {
            try writer.normaliseAccess(service: Self.prefix + "cas-never-deleted",
                                       data: Data(), label: "no")
        }
    }

    /// A stand-in keychain for the rewrite order, so the real one is never touched.
    final class Store {
        var item: Data?
        var restored: [Data] = []
        var truncateWrites = false
        var failWrite = false
        var failReadBack = false

        init(_ item: Data?) { self.item = item }

        func delete() { item = nil }

        func write(_ data: Data) throws {
            if failWrite { throw Failure.boom }
            item = truncateWrites ? data.prefix(20) : data
        }

        func readBack() throws -> Data {
            if failReadBack { throw Failure.boom }
            guard let item else { throw Failure.boom }
            // `security` prints the secret with a newline; the reader trims it.
            return item + Data("\n".utf8)
        }

        func restore(_ data: Data) {
            restored.append(data)
            item = data
        }
    }

    enum Failure: Error { case boom }

    func rewrite(_ store: Store, _ data: Data) throws {
        try SystemKeychainWriter.rewrite(data: data, delete: store.delete,
                                         write: store.write, readBack: store.readBack,
                                         restore: store.restore)
    }

    @Test("a rewrite that cannot finish puts the bytes back instead of losing the item")
    func rewriteRestoresOnFailure() {
        let payload = SlotStoreTests.goodPayload()

        // The write fails after the delete: the item would be gone without the restore.
        let refused = Store(payload)
        refused.failWrite = true
        #expect(throws: (any Error).self) { try rewrite(refused, payload) }
        #expect(refused.restored == [payload])
        #expect(refused.item == payload)

        // The write is accepted but stores something else: still a restore, not a success.
        let truncating = Store(payload)
        truncating.truncateWrites = true
        #expect(throws: (any Error).self) { try rewrite(truncating, payload) }
        #expect(truncating.restored == [payload])
        #expect(truncating.item == payload)

        // The read back fails: the caller's bytes go back too.
        let blind = Store(payload)
        blind.failReadBack = true
        #expect(throws: (any Error).self) { try rewrite(blind, payload) }
        #expect(blind.restored == [payload])
        #expect(blind.item == payload)
    }

    @Test("a rewrite that works keeps the new item and restores nothing")
    func rewriteKeepsTheNewItem() throws {
        let payload = SlotStoreTests.goodPayload()
        let store = Store(payload)
        try rewrite(store, payload)
        #expect(store.item == payload)
        #expect(store.restored.isEmpty)

        #expect(SystemKeychainWriter.matches(payload + Data("\r\n".utf8), payload))
        #expect(SystemKeychainWriter.matches(payload.prefix(20), payload) == false)
    }

    /// Records the most `security` calls that were ever inside the gate at once.
    final class Overlap: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var most = 0

        func enter() { lock.withLock { current += 1; most = max(most, current) } }
        func leave() { lock.withLock { current -= 1 } }
    }

    @Test("`security` calls are serialised, so one item cannot raise two dialogs at once")
    func gateSerialisesCalls() {
        // macOS asks once per check in flight, not once per item: two concurrent reads of an
        // unapproved item are two identical dialogs, and neither waits for the other's answer.
        let overlap = Overlap()
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            KeychainGate.serialised { () -> Void in
                overlap.enter()
                Thread.sleep(forTimeInterval: 0.002)
                overlap.leave()
            }
        }
        #expect(overlap.most == 1)
    }

    @Test("a call slower than a dialog is marked PROMPTED, and names the item to rewrite")
    func auditRemembersWhichItemPrompted() {
        let service = Self.prefix + "cas-audit-\(UUID().uuidString.prefix(8))"
        #expect(KeychainAudit.didPrompt(service) == false)

        let quick = KeychainAudit.outcome(exit: 0, since: Date(), service: service)
        #expect(quick.contains("PROMPTED") == false)
        #expect(KeychainAudit.didPrompt(service) == false)

        let waited = Date(timeIntervalSinceNow: -KeychainAudit.dialogThreshold - 1)
        let slow = KeychainAudit.outcome(exit: 0, since: waited, service: service)
        #expect(slow.contains("PROMPTED"))
        // Approving the dialog changes nothing about the item, so it stays on the list until
        // something writes it again through `security`.
        #expect(KeychainAudit.didPrompt(service))
        #expect(KeychainAudit.promptedServices().contains(service))

        KeychainAudit.clearPrompt(service)
        #expect(KeychainAudit.didPrompt(service) == false)
        #expect(KeychainAudit.promptedServices().contains(service) == false)
    }

    @Test("a hex dump from security(1) is decoded, plain text is left alone")
    func hexDecoding() throws {
        let json = Data(#"{"a":1}"#.utf8)
        #expect(SystemKeychainReader.decodeHexIfNeeded(json) == json)

        let hex = Data(json.map { String(format: "%02x", $0) }.joined().utf8)
        #expect(SystemKeychainReader.decodeHexIfNeeded(hex) == json)
        let upper = Data(json.map { String(format: "%02X", $0) }.joined().utf8)
        #expect(SystemKeychainReader.decodeHexIfNeeded(upper) == json)

        // Odd length, or not hex at all, is passed through untouched.
        #expect(SystemKeychainReader.decodeHexIfNeeded(Data("abc".utf8)) == Data("abc".utf8))
        #expect(SystemKeychainReader.decodeHexIfNeeded(Data("zz".utf8)) == Data("zz".utf8))
    }

    @Test("a capture round trips through the real keychain", .enabled(if: touchesKeychain))
    func captureRoundTrip() throws {
        let tag = UUID().uuidString.prefix(8)
        let liveService = Self.prefix + "cas-live-\(tag)"
        let slotName = "cas-capture-\(tag)"
        let writer = SystemKeychainWriter(servicePrefix: Self.prefix)
        let reader = SystemKeychainReader()
        defer {
            try? writer.delete(service: liveService)
            try? writer.delete(service: Self.prefix + slotName)
        }

        // A stand-in for `Claude Code-credentials`, made by this test.
        let live = Data(#"{"claudeAiOauth":{"accessToken":"cas-test-access","refreshToken":"cas-test-refresh","expiresAt":4000000000000,"refreshTokenExpiresAt":5000000000000,"scopes":["user:profile"]}}"#.utf8)
        try writer.write(live, service: liveService, label: "Claude Account Switcher self-test")

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-capture-\(tag)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent(".claude.json")
        try Data(#"{"numStartups":1,"oauthAccount":{"emailAddress":"self-test@example.com"}}"#.utf8)
            .write(to: config)

        let switcher = Switcher(
            reader: reader, writer: writer, loginPrefix: Self.prefix, liveService: liveService,
            paths: Switcher.Paths(config: config,
                                  activeLogin: directory.appendingPathComponent("active-login"),
                                  lock: directory.appendingPathComponent("switch.lock")))
        let plan = try switcher.capture(into: slotName, dryRun: false)
        #expect(plan.performed)
        #expect(plan.liveEmail == "self-test@example.com")

        let stored = try CredentialPayload.parse(try reader.data(forService: Self.prefix + slotName))
        #expect(stored.credentials.accessToken == "cas-test-access")
        #expect(stored.account?.emailAddress == "self-test@example.com")
        #expect(switcher.activeSlotName() == slotName)
    }
}
