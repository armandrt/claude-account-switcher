import Darwin
import Foundation
import Testing
@testable import SwitcherCore

/// No network, no browser, no real keychain: the sign-in's handling of codes,
/// verifiers and fresh tokens, exercised on its pure parts.
///
/// The three tests that bind a real loopback socket are opt-in
/// (`CAS_SOCKET_TESTS=1`), so the default run opens nothing.
@Suite("PKCE")
struct PKCETests {
    static let rfcVerifier = "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

    @Test("the challenge is the SHA-256 of the verifier, base64url, unpadded")
    func challenge() {
        // RFC 7636 appendix B's worked example.
        #expect(PKCE.challenge(for: Self.rfcVerifier) == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(PKCE(verifier: Self.rfcVerifier).method == "S256")
    }

    @Test("base64url leaves nothing that has to be escaped in a URL")
    func urlSafe() {
        for _ in 0..<50 {
            let value = PKCE.randomURLSafe(bytes: 32)
            #expect(value.count == 43)
            #expect(value.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        }
    }

    @Test("two logins never share a verifier or a state")
    func distinct() {
        let first = PKCE()
        let second = PKCE()
        #expect(first.verifier != second.verifier)
        #expect(first.state != second.state)
        #expect(first.challenge == PKCE.challenge(for: first.verifier))
    }

    @Test("printing a PKCE never prints the verifier")
    func hidesVerifier() {
        let pkce = PKCE(verifier: Self.rfcVerifier, state: "the-state")
        #expect("\(pkce)".contains("dBjftJeZ4CVP") == false)
        #expect(String(reflecting: pkce).contains("dBjftJeZ4CVP") == false)
        #expect("\(pkce)".contains("the-state"))
    }

    @Test("a pair goes stale, so an abandoned sign-in cannot be exchanged later")
    func staleness() {
        let now = Date()
        let fresh = PKCE(createdAt: now)
        #expect(fresh.isStale(now: now) == false)
        #expect(fresh.isStale(now: now.addingTimeInterval(PKCE.lifetime - 1)) == false)
        #expect(fresh.isStale(now: now.addingTimeInterval(PKCE.lifetime + 1)))
    }

    @Test("states are compared whole, not up to the first difference")
    func constantTimeCompare() {
        #expect(PKCE.equal("abcdef", "abcdef"))
        #expect(PKCE.equal("abcdef", "abcdeg") == false)
        #expect(PKCE.equal("abcdef", "Abcdef") == false)
        #expect(PKCE.equal("abcdef", "abcde") == false)
        #expect(PKCE.equal("", ""))
        let pkce = PKCE(state: "the-state")
        #expect(pkce.matches(state: "the-state"))
        #expect(pkce.matches(state: nil) == false)
        #expect(pkce.matches(state: "the-state ") == false)
    }
}

@Suite("Loopback callback")
struct LoopbackCallbackTests {
    static var socketsAllowed: Bool {
        ProcessInfo.processInfo.environment["CAS_SOCKET_TESTS"] != nil
    }

    @Test("the code and the state come off the request line")
    func parses() throws {
        let result = try #require(LoopbackCallback.parse(
            request: "GET /callback?code=abc123&state=xyz HTTP/1.1\r\nHost: localhost\r\n\r\n",
            expectedPath: "/callback"))
        #expect(result.code == "abc123")
        #expect(result.state == "xyz")
        #expect(result.error == nil)
    }

    @Test("a refusal is read as a refusal, not as a missing code")
    func denied() throws {
        let result = try #require(LoopbackCallback.parse(
            request: "GET /callback?error=access_denied&error_description=User%20refused HTTP/1.1\r\n\r\n",
            expectedPath: "/callback"))
        #expect(result.code == nil)
        #expect(result.error == "access_denied")
        #expect(result.errorDescription == "User refused")
    }

    @Test("a favicon request, an empty connection, another path and garbage are not the callback")
    func otherPaths() {
        for request in ["GET /favicon.ico HTTP/1.1\r\n\r\n", "", "nonsense",
                        "GET /callbackx?code=1 HTTP/1.1\r\n\r\n"] {
            #expect(LoopbackCallback.parse(request: request, expectedPath: "/callback") == nil)
        }
        #expect(LoopbackCallback.parse(request: "GET /callback HTTP/1.1\r\n\r\n",
                                       expectedPath: "/callback") != nil)
    }

    @Test("a request line still missing its CRLF is not parsed; the listener keeps reading")
    func partialSegment() {
        #expect(LoopbackCallback.parse(request: "GET /callback?code=abc&sta",
                                       expectedPath: "/callback") == nil)
        #expect(LoopbackCallback.hasHeaderEnd(Array("GET /callback?code=abc&sta".utf8)) == false)
        #expect(LoopbackCallback.hasHeaderEnd(Array("GET /callback?code=a&state=x HTTP/1.1\r\n".utf8)) == false)
        #expect(LoopbackCallback.hasHeaderEnd(
            Array("GET /callback?code=a&state=x HTTP/1.1\r\nHost: localhost\r\n\r\n".utf8)))
        // The end of the headers is found wherever it falls, not only at the end.
        #expect(LoopbackCallback.hasHeaderEnd(Array("GET / HTTP/1.1\r\nA: b\r\n\r\nbody".utf8)))
        #expect(LoopbackCallback.hasHeaderEnd(Array("\r\n\r\n".utf8)))
        #expect(LoopbackCallback.hasHeaderEnd([]) == false)
    }

    @Test("only a callback echoing this sign-in's state ends the wait")
    func stateGate() {
        let ours = LoopbackCallback.Result(code: "c", state: "ours")
        let theirs = LoopbackCallback.Result(code: "c", state: "theirs")
        let noState = LoopbackCallback.Result(code: "c")
        let deniedNoState = LoopbackCallback.Result(error: "access_denied")
        let deniedWrongState = LoopbackCallback.Result(state: "theirs", error: "access_denied")
        #expect(LoopbackCallback.accepts(ours, expectedState: "ours"))
        #expect(LoopbackCallback.accepts(theirs, expectedState: "ours") == false)
        #expect(LoopbackCallback.accepts(noState, expectedState: "ours") == false)
        #expect(LoopbackCallback.accepts(deniedNoState, expectedState: "ours"))
        #expect(LoopbackCallback.accepts(deniedWrongState, expectedState: "ours") == false)
        #expect(LoopbackCallback.accepts(theirs, expectedState: nil))
    }

    @Test("the served page names no code and escapes the server's text")
    func page() {
        let ok = LoopbackCallback.page(for: .init(code: "secret-code", state: "s"))
        #expect(ok.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(ok.contains("secret-code") == false)
        #expect(ok.contains("Cache-Control: no-store"))
        #expect(ok.contains("Referrer-Policy: no-referrer"))
        let bad = LoopbackCallback.page(for: .init(error: "x", errorDescription: "<script>alert(1)</script>"))
        #expect(bad.contains("<script>") == false)
        #expect(bad.contains("&lt;script&gt;"))
    }

    @Test("a cancelled sign-in never opens a socket at all")
    func cancelledBeforeStart() {
        let listener = LoopbackCallback(expectedState: "s", timeout: 1)
        listener.cancel()
        #expect(throws: LoopbackCallback.Failure.cancelled) { _ = try listener.wait() }
    }

    @Test("a callback split across two segments is still one request",
          .enabled(if: LoopbackCallbackTests.socketsAllowed))
    func splitAcrossSegments() async throws {
        let listener = LoopbackCallback(expectedState: "the-state", timeout: 10)
        let port = try listener.start()
        let waiting = Task.detached { try listener.wait() }

        let client = try LoopbackClient(port: port)
        client.send("GET /callback?code=abc&sta")
        try await Task.sleep(nanoseconds: 150_000_000)
        client.send("te=the-state HTTP/1.1\r\nHost: localhost\r\n\r\n")

        let result = try await waiting.value
        #expect(result.code == "abc")
        #expect(result.state == "the-state")
        let page = client.readAll()
        #expect(page.contains("You are signed in."))
        #expect(page.contains("abc") == false)      // the code is never in the page
        client.close()
    }

    @Test("a browser that connects and says nothing does not hold up the real callback",
          .enabled(if: LoopbackCallbackTests.socketsAllowed))
    func silentConnection() async throws {
        let listener = LoopbackCallback(expectedState: "the-state", timeout: 15)
        let port = try listener.start()
        let waiting = Task.detached { try listener.wait() }

        let silent = try LoopbackClient(port: port)        // connects, sends nothing
        let real = try LoopbackClient(port: port)
        real.send("GET /callback?code=abc&state=the-state HTTP/1.1\r\nHost: localhost\r\n\r\n")

        let result = try await waiting.value
        #expect(result.code == "abc")
        silent.close()
        real.close()
    }

    @Test("a wrong state gets a 404 and the listener keeps waiting for the right one",
          .enabled(if: LoopbackCallbackTests.socketsAllowed))
    func wrongStateIs404() async throws {
        let listener = LoopbackCallback(expectedState: "the-state", timeout: 15)
        let port = try listener.start()
        let waiting = Task.detached { try listener.wait() }

        let other = try LoopbackClient(port: port)
        other.send("GET /callback?code=stolen&state=somebody-elses HTTP/1.1\r\n\r\n")
        #expect(other.readAll().contains("404"))
        other.close()

        let real = try LoopbackClient(port: port)
        real.send("GET /callback?code=abc&state=the-state HTTP/1.1\r\n\r\n")
        let result = try await waiting.value
        #expect(result.code == "abc")
        real.close()

        // One listener, one sign-in: it does not quietly bind a second port.
        #expect(throws: LoopbackCallback.Failure.finished) { _ = try listener.start() }
        #expect(throws: LoopbackCallback.Failure.finished) { _ = try listener.wait() }
    }
}

/// The other end of the loopback listener, for the opt-in socket tests.
final class LoopbackClient {
    private let handle: Int32

    init(port: Int) throws {
        handle = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { throw LoopbackCallback.Failure.cannotListen("connect()") }
    }

    func send(_ text: String) {
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBufferPointer { Darwin.send(handle, $0.baseAddress, $0.count, 0) }
    }

    func readAll() -> String {
        var out = Data()
        var chunk = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = recv(handle, &chunk, chunk.count, 0)
            guard count > 0 else { break }
            out.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: out, as: UTF8.self)
    }

    func close() { Darwin.close(handle) }
}

@Suite("Storing a minted login")
struct LoginSlotTests {
    static func login(access: String = "fresh-access", refresh: String? = "fresh-refresh",
                      email: String = "new@example.com") -> MintedLogin {
        MintedLogin(
            accessToken: access, refreshToken: refresh, expiresAt: 1_700_000_000_000,
            scopes: ["user:profile", "user:inference"], subscriptionType: "max",
            account: OAuthAccount(emailAddress: email),
            accountJSON: Data(#"{"emailAddress":"\#(email)","organizationName":"Personal"}"#.utf8))
    }

    static func writer(_ keychain: FakeKeychain, live: String? = nil) -> LoginSlotWriter {
        LoginSlotWriter(reader: keychain, writer: keychain, loginPrefix: TempWorld.prefix,
                        liveSlotName: { live })
    }

    @Test("the slot it writes is the shape a switch can load")
    func shape() throws {
        let keychain = FakeKeychain()
        let bytes = try Self.writer(keychain).store(Self.login(), as: "newone")

        let stored = try #require(keychain.box.items[TempWorld.prefix + "newone"])
        #expect(stored.count == bytes)
        let payload = try CredentialPayload.parse(stored)
        #expect(payload.credentials.accessToken == "fresh-access")
        #expect(payload.credentials.refreshToken == "fresh-refresh")
        #expect(payload.credentials.scopes == ["user:profile", "user:inference"])
        #expect(payload.account?.emailAddress == "new@example.com")
        // A switch copies `credentials` into the live item byte for byte: nothing invented beside claudeAiOauth.
        let root = try #require(try JSONSerialization.jsonObject(with: stored) as? [String: Any])
        let credentials = try #require(root["credentials"] as? [String: Any])
        #expect(Array(credentials.keys) == ["claudeAiOauth"])
        let account = try #require(root["oauthAccount"] as? [String: Any])
        #expect(account["organizationName"] as? String == "Personal")
    }

    @Test("it never writes the live item, whatever it is asked for")
    func neverLive() {
        let writer = SystemKeychainWriter(servicePrefix: SlotStore.defaultLoginPrefix)
        #expect(throws: KeychainError.self) {
            try writer.write(Data("{}".utf8), service: "Claude Code-credentials", label: "x")
        }
    }

    @Test("the live slot is refused here too, not only in the panel")
    func neverTheLiveSlot() {
        let keychain = FakeKeychain()
        #expect(throws: LoginSlotError.liveSlot("perso2")) {
            try Self.writer(keychain, live: "perso2").store(Self.login(), as: "perso2")
        }
        #expect(keychain.box.items.isEmpty)
    }

    @Test("a name that already holds a working login is refused, not overwritten")
    func neverOverwrites() throws {
        let keychain = FakeKeychain()
        let writer = Self.writer(keychain)
        try writer.store(Self.login(email: "first@example.com"), as: "perso")

        #expect(throws: LoginSlotError.nameTaken("perso", email: "first@example.com")) {
            try writer.store(Self.login(email: "second@example.com"), as: "perso")
        }
        let stored = try #require(keychain.box.items[TempWorld.prefix + "perso"])
        #expect(try CredentialPayload.parse(stored).account?.emailAddress == "first@example.com")

        try writer.store(Self.login(email: "second@example.com"), as: "perso", replacing: true)
        let replaced = try #require(keychain.box.items[TempWorld.prefix + "perso"])
        #expect(try CredentialPayload.parse(replaced).account?.emailAddress == "second@example.com")
    }

    @Test("a name the keychain will not read is not treated as an empty one")
    func unreadableNameIsNotEmpty() throws {
        let keychain = FakeKeychain()
        let service = TempWorld.prefix + "perso"
        keychain.box.items[service] = Data(#"{"credentials":{"claudeAiOauth":{"accessToken":"a"}}}"#.utf8)
        keychain.box.failures[service] = .status(-25308, service)

        // Overwriting because a read failed is how a working account would be lost.
        #expect(throws: LoginSlotError.self) {
            try Self.writer(keychain).store(Self.login(), as: "perso")
        }
        #expect(keychain.box.writes.isEmpty)
        // A repair says so, and goes ahead once the keychain answers again.
        keychain.box.failures.removeValue(forKey: service)
        try Self.writer(keychain).store(Self.login(), as: "perso", replacing: true)
        #expect(keychain.box.writes.count == 1)
    }

    @Test("a corrupt slot does not count as taken: replacing it is the repair")
    func corruptIsReplaceable() throws {
        let keychain = FakeKeychain()
        keychain.box.items[TempWorld.prefix + "pro"] = Data("{\"credentials\":{\"claud".utf8)
        try Self.writer(keychain).store(Self.login(), as: "pro")
        #expect(try CredentialPayload.parse(#require(keychain.box.items[TempWorld.prefix + "pro"]))
            .credentials.accessToken == "fresh-access")
    }

    @Test("a login whose profile never loaded is still storable")
    func storableWithoutProfile() throws {
        let keychain = FakeKeychain()
        var login = Self.login()
        login.account = nil
        login.accountJSON = nil
        try Self.writer(keychain).store(login, as: "noprofile")

        let payload = try CredentialPayload.parse(
            try #require(keychain.box.items[TempWorld.prefix + "noprofile"]))
        #expect(payload.credentials.accessToken == "fresh-access")
        #expect(payload.account?.emailAddress == nil)
    }

    @Test("a login with no refresh token is not stored at all")
    func needsRefreshToken() {
        let keychain = FakeKeychain()
        #expect(throws: LoginSlotError.noRefreshToken) {
            try Self.writer(keychain).store(Self.login(refresh: nil), as: "shortlived")
        }
        #expect(throws: LoginSlotError.noRefreshToken) {
            try Self.writer(keychain).store(Self.login(refresh: ""), as: "shortlived")
        }
        #expect(keychain.box.items.isEmpty)
    }

    @Test("a write that comes back short is a failure, not a success")
    func verifiesTheWrite() {
        let keychain = FakeKeychain()
        keychain.box.truncateWrites.insert(TempWorld.prefix + "newone")
        #expect(throws: LoginSlotError.self) {
            try Self.writer(keychain).store(Self.login(), as: "newone")
        }
    }

    @Test("a write that came back without its refresh token is a failure too")
    func verifiesTheWholePayload() {
        let keychain = ScriptedKeychain()
        keychain.mutateWrite = { data in
            guard let object = try? JSONSerialization.jsonObject(with: data),
                  var root = object as? [String: Any],
                  var credentials = root["credentials"] as? [String: Any],
                  var oauth = credentials["claudeAiOauth"] as? [String: Any] else { return data }
            oauth["refreshToken"] = nil
            credentials["claudeAiOauth"] = oauth
            root["credentials"] = credentials
            return (try? JSONSerialization.data(withJSONObject: root)) ?? data
        }
        let writer = LoginSlotWriter(reader: keychain, writer: keychain,
                                     loginPrefix: TempWorld.prefix)
        #expect(throws: LoginSlotError.self) { try writer.store(Self.login(), as: "newone") }
    }

    @Test("a keychain dialog nobody answers is a sentence, not a panel stuck on storing")
    func dialogDoesNotHang() {
        let keychain = ScriptedKeychain()
        keychain.writeDelay = 2
        let writer = LoginSlotWriter(reader: keychain, writer: keychain,
                                     loginPrefix: TempWorld.prefix, deadline: 0.2)
        let began = Date()
        do {
            try writer.store(Self.login(), as: "newone")
            Issue.record("a write nobody answered is not a stored login")
        } catch let error as LoginSlotError {
            guard case .write(let why) = error else { Issue.record("wrong error: \(error)"); return }
            #expect(why.contains("keychain"))
            #expect(why.contains("fresh-refresh") == false)
        } catch {
            Issue.record("wrong error: \(error)")
        }
        #expect(Date().timeIntervalSince(began) < 1.5)
    }

    @Test("names `claude-acct` would refuse are refused here too")
    func nameRules() {
        let keychain = FakeKeychain()
        for name in ["", "with space", "slash/es", "quote\"d"] {
            #expect(throws: LoginSlotError.badName(name)) {
                try Self.writer(keychain).store(Self.login(), as: name)
            }
        }
    }

    @Test("printing a minted login never prints a token or the full email")
    func hidesTokens() {
        let text = "\(Self.login(access: "access-secret-1234", refresh: "refresh-secret-5678"))"
        #expect(text.contains("access-secret") == false)
        #expect(text.contains("refresh-secret") == false)
        #expect(text.contains("new@example.com") == false)
    }
}
