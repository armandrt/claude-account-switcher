import Foundation
import Testing
@testable import SwitcherCore

/// A keychain whose answers can change between calls, for the races a rotation
/// has to survive: the slot removed, replaced or written behind a dialog while
/// the request is out.
final class ScriptedKeychain: KeychainReading, KeychainWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var reads = 0
    private(set) var writes: [(service: String, bytes: Int)] = []
    /// Run before every read, with the count of reads so far: the test uses it
    /// to remove or replace an item between the two reads of one rotation.
    var beforeRead: (@Sendable (ScriptedKeychain, Int) -> Void)?
    /// How long a write blocks. A keychain dialog nobody answers is forever.
    var writeDelay: TimeInterval = 0
    /// Writes land, then block: the write the caller gave up on but that took.
    var writeLandsBeforeBlocking = false
    var writeFailure: KeychainError?
    /// What the keychain really stored, when it is not what it was handed.
    var mutateWrite: (@Sendable (Data) -> Data)?

    init(items: [String: Data] = [:]) { self.items = items }

    func put(_ service: String, _ data: Data?) { lock.withLock { items[service] = data } }
    func item(_ service: String) -> Data? { lock.withLock { items[service] } }

    func services(withPrefix prefix: String) throws -> [String] {
        lock.withLock { items.keys.filter { $0.hasPrefix(prefix) }.sorted() }
    }

    func data(forService service: String) throws -> Data {
        let count = lock.withLock { () -> Int in reads += 1; return reads }
        beforeRead?(self, count)
        guard let data = lock.withLock({ items[service] }) else {
            throw KeychainError.itemNotFound(service)
        }
        return data
    }

    func write(_ data: Data, service: String, label: String) throws {
        if let writeFailure { throw writeFailure }
        let stored = mutateWrite?(data) ?? data
        if writeLandsBeforeBlocking { lock.withLock { items[service] = stored } }
        if writeDelay > 0 { Thread.sleep(forTimeInterval: writeDelay) }
        lock.withLock {
            items[service] = stored
            writes.append((service, data.count))
        }
    }

    func delete(service: String) throws { lock.withLock { items[service] = nil } }
}

@Suite("Token refresher", .serialized)
struct TokenRefresherTests {
    static let slotPayload = """
    {"credentials":{"claudeAiOauth":{"accessToken":"old-access","refreshToken":"old-refresh",
      "expiresAt":1,"refreshTokenExpiresAt":99999999999999,"scopes":["user:profile"],
      "subscriptionType":"max"},
      "mcpOAuth":{"example-mcp|abc":{"serverName":"example-mcp","token":"keep-me"}}},
     "oauthAccount":{"emailAddress":"someone@example.com"}}
    """

    static let service = "CAS Test Login: perso"

    static func payload(_ text: String? = nil) throws -> CredentialPayload {
        try CredentialPayload.parse(Data((text ?? slotPayload).utf8))
    }

    /// The slot as the keychain holds it: a renewal re-reads it before sending
    /// anything, so every test starts from a stored item, as the app does.
    static func keychain(_ text: String? = nil) -> FakeKeychain {
        let keychain = FakeKeychain()
        keychain.box.items[service] = Data((text ?? slotPayload).utf8)
        return keychain
    }

    static func tokenReply(access: String = "new-access", refresh: String = "new-refresh") -> Data {
        Data(#"{"access_token":"\#(access)","refresh_token":"\#(refresh)","expires_in":28800,"token_type":"Bearer"}"#.utf8)
    }

    @Test("refuses the live slot before it touches the network")
    func refusesLiveSlot() async throws {
        StubProtocol.reset(StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               liveSlotName: { "perso2" })
        await #expect(throws: RefreshError.refusedLiveSlot("perso2")) {
            _ = try await refresher.refresh(slot: "perso2", payload: try Self.payload())
        }
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
    }

    @Test("refuses a slot holding the live account, whatever the marker says")
    func refusesLiveByEmail() async throws {
        StubProtocol.reset(StubPath.token)
        let keychain = Self.keychain()
        // The marker still names perso2; `/login` moved the live login to this one.
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               liveSlotName: { "perso2" },
                                               liveAccountEmail: { "Someone@Example.com" })
        await #expect(throws: RefreshError.refusedLiveSlot("perso")) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
        #expect(keychain.box.writes.isEmpty)
    }

    @Test("sends a refresh_token grant and writes the rotated tokens back")
    func writesBack() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               liveSlotName: { "perso2" })
        let now = Date(timeIntervalSince1970: 1_000_000)
        let credentials = try await refresher.refresh(slot: "perso", payload: try Self.payload(), now: now)

        #expect(credentials.accessToken == "new-access")
        #expect(credentials.refreshToken == "new-refresh")
        // expires_in less the skew margin: this clock is not the server's.
        #expect(abs((credentials.expiresAt ?? 0) - 1_028_740_000) < 0.5)

        let sent = try #require(StubProtocol.calls(for: StubPath.token).last?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["grant_type"] as? String == "refresh_token")
        #expect(body["refresh_token"] as? String == "old-refresh")
        #expect(body["client_id"] as? String == TokenRefresher.claudeCodeClientID)
        #expect(StubProtocol.calls(for: StubPath.token).last?.request.url == TokenRefresher.defaultEndpoint)
        #expect(StubProtocol.calls(for: StubPath.token).last?.request.httpMethod == "POST")

        // Everything else in the slot survives the write-back.
        let stored = try #require(keychain.box.items[Self.service])
        let reparsed = try CredentialPayload.parse(stored)
        #expect(reparsed.credentials.accessToken == "new-access")
        #expect(reparsed.account?.emailAddress == "someone@example.com")
        let root = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let creds = try #require(root["credentials"] as? [String: Any])
        #expect(creds["mcpOAuth"] != nil)
    }

    @Test("the token it sends is the stored one, not the caller's stale copy")
    func usesTheStoredRefreshToken() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: StubPath.token)
        // The panel read this row minutes ago; the slot has been rotated since.
        let stale = try Self.payload()
        let keychain = Self.keychain(Self.slotPayload.replacingOccurrences(
            of: "\"old-refresh\"", with: "\"rotated-since\""))
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        _ = try await refresher.refresh(slot: "perso", payload: stale)
        let sent = try #require(StubProtocol.calls(for: StubPath.token).last?.body)
        let body = try #require(try JSONSerialization.jsonObject(with: sent) as? [String: Any])
        #expect(body["refresh_token"] as? String == "rotated-since")
    }

    @Test("a slot something else already renewed is not rotated again")
    func doesNotRotateAWorkingToken() async throws {
        StubProtocol.reset(StubPath.token)
        let future = (Date().timeIntervalSince1970 + 3600) * 1000
        let keychain = Self.keychain(Self.slotPayload.replacingOccurrences(
            of: "\"expiresAt\":1,", with: "\"expiresAt\":\(future),"))
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        let credentials = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        #expect(credentials.accessToken == "old-access")
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
        #expect(keychain.box.writes.isEmpty)
    }

    @Test("a slot that is no longer in the keychain is not renewed or recreated")
    func goneBeforeTheRequest() async throws {
        StubProtocol.reset(StubPath.token)
        let keychain = FakeKeychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
        #expect(keychain.box.items.isEmpty)
    }

    @Test("a slot removed while the request was out is not recreated")
    func removedMidRotation() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: StubPath.token)
        let keychain = ScriptedKeychain(items: [Self.service: Data(Self.slotPayload.utf8)])
        keychain.beforeRead = { keychain, count in
            if count == 2 { keychain.put(Self.service, nil) }     // removed after the 200
        }
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        do {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
            Issue.record("a removed slot must not be written back")
        } catch let error as RefreshError {
            guard case .slotChanged(let why) = error else { Issue.record("wrong error: \(error)"); return }
            #expect(why.contains("removed"))
        }
        #expect(keychain.writes.isEmpty)
        #expect(keychain.item(Self.service) == nil)
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
    }

    @Test("a slot signed in to again mid-rotation keeps the new login")
    func replacedMidRotation() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: StubPath.token)
        let replacement = Self.slotPayload
            .replacingOccurrences(of: "someone@example.com", with: "somebody-else@example.com")
            .replacingOccurrences(of: "old-access", with: "brand-new-access")
        let keychain = ScriptedKeychain(items: [Self.service: Data(Self.slotPayload.utf8)])
        keychain.beforeRead = { keychain, count in
            if count == 2 { keychain.put(Self.service, Data(replacement.utf8)) }
        }
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(keychain.writes.isEmpty)
        let kept = try CredentialPayload.parse(try #require(keychain.item(Self.service)))
        #expect(kept.credentials.accessToken == "brand-new-access")
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
    }

    @Test("two callers for one slot share a single call")
    func singleFlight() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply(), delay: 0.5), for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        let payload = try Self.payload()

        async let first = refresher.refresh(slot: "perso", payload: payload)
        var waited = 0
        while await refresher.isRefreshing("perso") == false, waited < 200 {
            try await Task.sleep(nanoseconds: 2_000_000)
            waited += 1
        }
        #expect(await refresher.isRefreshing("perso"))
        async let second = refresher.refresh(slot: "perso", payload: payload)
        let results = try await [first, second]

        #expect(results[0].accessToken == "new-access")
        #expect(results[1].accessToken == "new-access")
        #expect(StubProtocol.calls(for: StubPath.token).count == 1)
    }

    @Test("a dead refresh token asks for a re-login instead of retrying")
    func deadRefreshToken() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)), for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: RefreshError.needsRelogin("the refresh token was rejected (invalid_grant)")) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }

        // An expired refreshTokenExpiresAt is caught before any request is sent.
        StubProtocol.reset(StubPath.token)
        let text = """
        {"credentials":{"claudeAiOauth":{"accessToken":"a","refreshToken":"r",
          "refreshTokenExpiresAt":1000}}}
        """
        let dead = Self.keychain(text)
        let deadRefresher = TokenRefresher.stubbed(StubProtocol.self, writer: dead, reader: dead)
        await #expect(throws: RefreshError.refreshTokenExpired) {
            _ = try await deadRefresher.refresh(slot: "perso", payload: try Self.payload(text),
                                                now: Date(timeIntervalSince1970: 5000))
        }
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
    }

    @Test("a 200 with no access_token is reported, not stored")
    func badBody() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Data(#"{"ok":true}"#.utf8)), for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(keychain.box.writes.isEmpty)
    }

    @Test("a 200 that is not JSON at all is reported, not stored")
    func notJSON() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Data("<html>gateway</html>".utf8)), for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(keychain.box.writes.isEmpty)
    }

    @Test("an error body never carries anything token-shaped onto the screen")
    func scrubsErrorBodies() async throws {
        StubProtocol.reset(StubPath.token)
        let secret = "sk-ant-oat01-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA"
        StubProtocol.arm(.init(status: 503, body: Data(#"{"detail":"upstream said \#(secret)"}"#.utf8)),
                         for: StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        do {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
            Issue.record("a 503 is not a renewal")
        } catch {
            let text = "\(error)"
            #expect(text.contains("upstream said"))
            #expect(text.contains(secret) == false)
        }
    }

    @Test("without a keychain writer or reader nothing is rotated")
    func noWriterNoRotation() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: StubPath.token)
        let refresher = TokenRefresher.stubbed(StubProtocol.self)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try Self.payload())
        }
        // A write that cannot be checked is a rotation that cannot be proved kept.
        let writeOnly = TokenRefresher.stubbed(StubProtocol.self, writer: Self.keychain())
        await #expect(throws: (any Error).self) {
            _ = try await writeOnly.refresh(slot: "perso", payload: try Self.payload())
        }
        #expect(StubProtocol.calls(for: StubPath.token).isEmpty)
    }
}

/// The write-back after a rotation: the server has moved on, and the only working
/// tokens are the ones in hand. Same suite as above because they share one stub path.
extension TokenRefresherTests {
    @Test("the stored item is read back and checked against what was written")
    func verifiesTheReadBack() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.truncateWrites.insert(Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
        }
        // Two attempts, and neither of them was believed.
        #expect(keychain.box.writes.count == 2)
        #expect(await refresher.hasUnstoredTokens(for: "perso"))
    }

    @Test("a rotation that cannot be stored is held, not thrown away")
    func holdsUnstoredTokens() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.writeFailures[Self.service] = .status(-25293, Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        do {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
            Issue.record("the refresh should have reported the failed write-back")
        } catch let error as RefreshError {
            guard case .writeBack(let why) = error else {
                Issue.record("wrong error: \(error)")
                return
            }
            #expect(why.contains("held in memory only"))
            #expect(why.contains("new-access") == false)      // never a token in a message
            #expect(why.contains("new-refresh") == false)
        }
        #expect(await refresher.hasUnstoredTokens(for: "perso"))
        #expect(await refresher.unstoredSlotNames() == ["perso"])

        // The retry uses the tokens already in hand: no second rotation.
        keychain.box.writeFailures.removeValue(forKey: Self.service)
        try await refresher.retryWriteBack(slot: "perso")
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
        #expect(StubProtocol.calls(for: StubPath.token).count == 1)

        let item = try #require(keychain.box.items[Self.service])
        let stored = try CredentialPayload.parse(item)
        #expect(stored.credentials.accessToken == "new-access")
        #expect(stored.credentials.refreshToken == "new-refresh")
        let root = try #require(try JSONSerialization.jsonObject(with: item) as? [String: Any])
        let credentials = try #require(root["credentials"] as? [String: Any])
        #expect(credentials["mcpOAuth"] != nil)
        #expect(stored.account?.emailAddress == "someone@example.com")
    }

    @Test("held tokens are stored on the next refresh instead of rotating again")
    func heldTokensAreNotRotatedTwice() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.writeFailures[Self.service] = .status(-25293, Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
        }
        #expect(StubProtocol.calls(for: StubPath.token).count == 1)

        // The sweep or the row button sends the same stale payload again.
        keychain.box.writeFailures.removeValue(forKey: Self.service)
        let credentials = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
        #expect(credentials.accessToken == "new-access")
        #expect(credentials.refreshToken == "new-refresh")
        #expect(StubProtocol.calls(for: StubPath.token).count == 1)
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
        #expect(try CredentialPayload.parse(try #require(keychain.box.items[Self.service]))
            .credentials.refreshToken == "new-refresh")
    }

    @Test("held tokens are dropped rather than written over a slot that now holds another login")
    func heldTokensNeverClobberANewLogin() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.writeFailures[Self.service] = .status(-25293, Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
        }

        // The owner signed in to that slot again while the tokens were waiting.
        keychain.box.writeFailures.removeValue(forKey: Self.service)
        keychain.box.items[Self.service] = Data(Self.slotPayload
            .replacingOccurrences(of: "someone@example.com", with: "new-login@example.com")
            .replacingOccurrences(of: "old-access", with: "the-new-login").utf8)
        await #expect(throws: (any Error).self) { try await refresher.retryWriteBack(slot: "perso") }

        #expect(try CredentialPayload.parse(try #require(keychain.box.items[Self.service]))
            .credentials.accessToken == "the-new-login")
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
    }

    @Test("a write that takes on the second attempt is not reported as a failure")
    func secondAttemptSucceeds() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.writeFailuresOnce[Self.service] = .status(-25308, Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)

        let credentials = try await refresher.refresh(slot: "perso",
                                                      payload: try TokenRefresherTests.payload())
        #expect(credentials.accessToken == "new-access")
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
        #expect(keychain.box.writes.count == 1)      // the refused one never landed
        #expect(try CredentialPayload.parse(try #require(
            keychain.box.items[Self.service])).credentials.accessToken == "new-access")
    }

    @Test("a keychain dialog nobody answers becomes a sentence, not a frozen renewal")
    func writeBehindADialog() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = ScriptedKeychain(items: [Self.service: Data(Self.slotPayload.utf8)])
        keychain.writeDelay = 1
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               keychainDeadline: 0.2)
        let began = Date()
        do {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
            Issue.record("a write nobody answered is not a stored rotation")
        } catch let error as RefreshError {
            guard case .writeBack(let why) = error else { Issue.record("wrong error: \(error)"); return }
            #expect(why.contains("keychain"))
            #expect(why.contains("held in memory only"))
            #expect(why.contains("new-refresh") == false)
        }
        // The actor answered rather than sitting behind the dialog for a minute.
        #expect(Date().timeIntervalSince(began) < 5)
        #expect(await refresher.hasUnstoredTokens(for: "perso"))
    }

    @Test("a write the caller gave up on, but that landed, is not reported as lost")
    func writeThatLandedLate() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = ScriptedKeychain(items: [Self.service: Data(Self.slotPayload.utf8)])
        keychain.writeLandsBeforeBlocking = true
        keychain.writeDelay = 0.6
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               keychainDeadline: 0.2)

        let credentials = try await refresher.refresh(slot: "perso",
                                                      payload: try TokenRefresherTests.payload())
        #expect(credentials.accessToken == "new-access")
        #expect(await refresher.hasUnstoredTokens(for: "perso") == false)
        #expect(try CredentialPayload.parse(try #require(keychain.item(Self.service)))
            .credentials.refreshToken == "new-refresh")
    }

    @Test("the live slot is still refused, and nothing is held for it")
    func liveSlotStaysRefused() async throws {
        StubProtocol.reset(StubPath.token)
        let keychain = Self.keychain()
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain,
                                               liveSlotName: { "perso2" })
        await #expect(throws: RefreshError.refusedLiveSlot("perso2")) {
            _ = try await refresher.refresh(slot: "perso2", payload: try TokenRefresherTests.payload())
        }
        #expect(keychain.box.writes.isEmpty)
        #expect(await refresher.hasUnstoredTokens(for: "perso2") == false)
    }

    @Test("held tokens can be dropped when the owner removes the account")
    func forgetting() async throws {
        StubProtocol.reset(StubPath.token)
        StubProtocol.arm(.init(status: 200, body: TokenRefresherTests.tokenReply()), for: StubPath.token)
        let keychain = Self.keychain()
        keychain.box.writeFailures[Self.service] = .status(-25293, Self.service)
        let refresher = TokenRefresher.stubbed(StubProtocol.self, writer: keychain, reader: keychain)
        await #expect(throws: (any Error).self) {
            _ = try await refresher.refresh(slot: "perso", payload: try TokenRefresherTests.payload())
        }
        #expect(await refresher.unstoredSlotNames() == ["perso"])
        await refresher.forget(slot: "perso")
        #expect(await refresher.unstoredSlotNames().isEmpty)
    }

    @Test("the fallback payload keeps the account and every token field")
    func minimalPayloadIsComplete() throws {
        let credentials = OAuthCredentials(
            accessToken: "a", refreshToken: "r", expiresAt: 42, refreshTokenExpiresAt: 99,
            scopes: ["user:profile"], subscriptionType: "max", rateLimitTier: "tier")
        let account = Data(#"{"emailAddress":"someone@example.com"}"#.utf8)
        let payload = try CredentialPayload.parse(
            TokenRefresher.minimalPayload(credentials, account: account))
        #expect(payload.credentials == credentials)
        #expect(payload.account?.emailAddress == "someone@example.com")

        // Even with nothing to put beside them, the tokens still land somewhere valid.
        let bare = try CredentialPayload.parse(TokenRefresher.minimalPayload(credentials, account: nil))
        #expect(bare.credentials.refreshToken == "r")
    }
}
