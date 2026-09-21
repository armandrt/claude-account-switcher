import Foundation
import Testing
@testable import SwitcherCore

/// Every parameter of the authorize URL and the exchange was read out of the
/// Claude Code binary; these pin what was read so a "tidy-up" fails here rather
/// than in a browser. Token and profile calls go through the stubbed URLProtocol.
///
/// Every test uses a code of its own: a code is good once per process now, and
/// two tests sharing one string would be the same replay this guards against.
@Suite("OAuth login", .serialized)
struct OAuthLoginTests {
    static let profilePath = OAuthLogin.Endpoints.claudeAI.profileURL.path

    /// The stub is keyed by path and the refresher suite uses the real token
    /// path, so the exchange tests point at one of their own.
    static let tokenPath = "/v1/oauth/token-exchange-tests"
    static var endpoints: OAuthLogin.Endpoints {
        var endpoints = OAuthLogin.Endpoints.claudeAI
        endpoints.tokenURL = URL(string: "https://platform.claude.com\(tokenPath)")!
        return endpoints
    }

    static func pkce(createdAt: Date = Date()) -> PKCE {
        PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk", state: "the-state",
             createdAt: createdAt)
    }

    static func client() -> OAuthLogin {
        OAuthLogin.stubbed(StubProtocol.self, endpoints: endpoints)
    }

    static func tokenReply(refresh: String? = "new-refresh") -> Data {
        let field = refresh.map { "\"refresh_token\":\"\($0)\"," } ?? ""
        return Data("""
        {"access_token":"new-access",\(field)
         "expires_in":28800,
         "scope":"user:profile user:inference","token_type":"Bearer",
         "account":{"uuid":"acc-1","email_address":"someone@example.com"},
         "organization":{"uuid":"org-1","name":"Personal"}}
        """.utf8)
    }

    static func profileReply(email: String = "someone@example.com", uuid: String = "acc-1") -> Data {
        Data("""
        {"account":{"uuid":"\(uuid)","email":"\(email)","display_name":"Someone",
                    "full_name":"Some One"},
         "organization":{"uuid":"org-1","name":"Personal","organization_type":"claude_max",
                         "rate_limit_tier":"default_claude_max_20x","billing_type":"stripe",
                         "seat_tier":null}}
        """.utf8)
    }

    static func armBoth(token: Data, profile: Data?) {
        StubProtocol.reset(tokenPath)
        StubProtocol.reset(profilePath)
        StubProtocol.arm(.init(status: 200, body: token), for: tokenPath)
        if let profile { StubProtocol.arm(.init(status: 200, body: profile), for: profilePath) }
    }

    @Test("the endpoints are the ones the binary uses")
    func endpointsAreTheRealOnes() {
        let endpoints = OAuthLogin.Endpoints.claudeAI
        #expect(endpoints.clientID == TokenRefresher.claudeCodeClientID)
        #expect(endpoints.tokenURL == TokenRefresher.defaultEndpoint)
        #expect(endpoints.tokenURL.absoluteString == "https://platform.claude.com/v1/oauth/token")
        #expect(endpoints.authorizeURL.absoluteString == "https://claude.com/cai/oauth/authorize")
        #expect(endpoints.profileURL.absoluteString == "https://api.anthropic.com/api/oauth/profile")
        #expect(endpoints.manualRedirect.absoluteString
                == "https://platform.claude.com/oauth/code/callback")
    }

    @Test("the authorize URL carries every parameter Claude Code sends")
    func authorizeURL() throws {
        let client = OAuthLogin()
        let url = client.authorizeURL(pkce: Self.pkce(), redirect: .loopback(port: 51234))
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        var query: [String: String] = [:]
        for item in components.queryItems ?? [] { query[item.name] = item.value }

        #expect(components.host == "claude.com")
        #expect(components.path == "/cai/oauth/authorize")
        #expect(query["client_id"] == "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
        #expect(query["response_type"] == "code")
        #expect(query["code"] == "true")
        // `localhost`, not `127.0.0.1`: the binary sends the first.
        #expect(query["redirect_uri"] == "http://localhost:51234/callback")
        #expect(query["code_challenge_method"] == "S256")
        #expect(query["code_challenge"] == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(query["state"] == "the-state")
        #expect(query["scope"] == "user:profile user:inference user:sessions:claude_code "
                + "user:mcp_servers user:file_upload")
        // The verifier must never be in the URL.
        #expect(url.absoluteString.contains("dBjftJeZ4CVP") == false)
    }

    @Test("the manual URL differs only in where the code is sent")
    func manualURL() throws {
        let client = OAuthLogin()
        let url = client.authorizeURL(pkce: Self.pkce(), redirect: .manual)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        let redirect = (components.queryItems ?? []).first { $0.name == "redirect_uri" }?.value
        #expect(redirect == "https://platform.claude.com/oauth/code/callback")
    }

    @Test("the pasted code is <code>#<state>, and half of it is not enough")
    func pastedCode() throws {
        let (code, state) = try OAuthLogin.splitPastedCode("  abc123#xyz789\n")
        #expect(code == "abc123")
        #expect(state == "xyz789")
        for bad in ["abc123", "#xyz", "abc#", "", "a#b#c", "a##b", "#", " # "] {
            #expect(throws: LoginError.malformedPaste) { _ = try OAuthLogin.splitPastedCode(bad) }
        }
    }

    @Test("the exchange sends JSON with the verifier, and never a secret")
    func exchange() async throws {
        Self.armBoth(token: Self.tokenReply(), profile: Self.profileReply())

        let client = Self.client()
        // A clock with sub-millisecond fraction: expiresAt must still be whole milliseconds.
        let now = Date(timeIntervalSince1970: 1_000_000.0004567)
        let login = try await client.complete(code: "code-exchange", state: "the-state",
                                              pkce: Self.pkce(createdAt: now),
                                              redirect: .loopback(port: 51234), now: now)

        let call = try #require(StubProtocol.calls(for: Self.tokenPath).last)
        #expect(call.request.httpMethod == "POST")
        #expect(call.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(call.request.value(forHTTPHeaderField: "Authorization") == nil)
        let body = try #require(try JSONSerialization.jsonObject(with: call.body) as? [String: Any])
        #expect(body["grant_type"] as? String == "authorization_code")
        #expect(body["code"] as? String == "code-exchange")
        #expect(body["code_verifier"] as? String == "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(body["client_id"] as? String == TokenRefresher.claudeCodeClientID)
        #expect(body["state"] as? String == "the-state")
        // The same string it was authorized with.
        #expect(body["redirect_uri"] as? String == "http://localhost:51234/callback")
        #expect(body["client_secret"] == nil)

        #expect(login.accessToken == "new-access")
        #expect(login.refreshToken == "new-refresh")
        // 28800 s less the skew margin, in milliseconds.
        #expect(login.expiresAt == 1_028_740_000)
        #expect(login.email == "someone@example.com")
        #expect(login.subscriptionType == "max")
        #expect(login.rateLimitTier == "default_claude_max_20x")
        #expect(login.warnings.isEmpty)
    }

    @Test("a callback carrying somebody else's state is never exchanged")
    func stateMismatch() async {
        StubProtocol.reset(Self.tokenPath)
        await #expect(throws: LoginError.stateMismatch) {
            _ = try await Self.client().complete(code: "code-mismatch", state: "not-our-state",
                                                 pkce: Self.pkce(), redirect: .manual)
        }
        #expect(StubProtocol.calls(for: Self.tokenPath).isEmpty)
    }

    @Test("a used or stale code says so instead of reporting a 400")
    func expiredCode() async throws {
        StubProtocol.reset(Self.tokenPath)
        StubProtocol.arm(.init(status: 400, body: Data(#"{"error":"invalid_grant"}"#.utf8)),
                         for: Self.tokenPath)
        await #expect(throws: LoginError.codeExpired) {
            _ = try await Self.client().complete(code: "code-old", state: "the-state",
                                                 pkce: Self.pkce(), redirect: .manual)
        }
    }

    @Test("one code is exchanged once, however many times the button is pressed")
    func codeIsSpentOnce() async throws {
        Self.armBoth(token: Self.tokenReply(), profile: Self.profileReply())
        let client = Self.client()
        _ = try await client.complete(code: "code-reuse", state: "the-state",
                                      pkce: Self.pkce(), redirect: .manual)
        #expect(StubProtocol.calls(for: Self.tokenPath).count == 1)

        // Return and the button both fire; the second must not spend the code again.
        await #expect(throws: LoginError.codeExpired) {
            _ = try await client.complete(code: "code-reuse", state: "the-state",
                                          pkce: Self.pkce(), redirect: .manual)
        }
        #expect(StubProtocol.calls(for: Self.tokenPath).count == 1)
    }

    @Test("a request that never left leaves the code usable")
    func transportFailureKeepsTheCode() async throws {
        StubProtocol.reset(Self.tokenPath)
        StubProtocol.arm(.init(status: 0, error: URLError(.notConnectedToInternet)),
                         for: Self.tokenPath)
        let client = Self.client()
        await #expect(throws: (any Error).self) {
            _ = try await client.complete(code: "code-transport", state: "the-state",
                                          pkce: Self.pkce(), redirect: .manual)
        }
        Self.armBoth(token: Self.tokenReply(), profile: Self.profileReply())
        let login = try await client.complete(code: "code-transport", state: "the-state",
                                              pkce: Self.pkce(), redirect: .manual)
        #expect(login.accessToken == "new-access")
    }

    @Test("a verifier older than a sign-in is not exchanged")
    func staleVerifier() async throws {
        StubProtocol.reset(Self.tokenPath)
        let old = Self.pkce(createdAt: Date(timeIntervalSinceNow: -PKCE.lifetime - 60))
        await #expect(throws: LoginError.codeExpired) {
            _ = try await Self.client().complete(code: "code-stale", state: "the-state",
                                                 pkce: old, redirect: .manual)
        }
        #expect(StubProtocol.calls(for: Self.tokenPath).isEmpty)
    }

    @Test("a 200 with no refresh token says so rather than looking like a login")
    func noRefreshToken() async throws {
        Self.armBoth(token: Self.tokenReply(refresh: nil), profile: Self.profileReply())
        let login = try await Self.client().complete(code: "code-no-refresh", state: "the-state",
                                                     pkce: Self.pkce(), redirect: .manual)
        #expect(login.lacksRefreshToken)
        #expect(login.warnings.contains { $0.contains("refresh token") })
        // And the writer refuses it outright, so no slot is left to die in a few hours.
        #expect(throws: LoginSlotError.noRefreshToken) {
            try LoginSlotWriter(reader: FakeKeychain(), writer: FakeKeychain(),
                                loginPrefix: TempWorld.prefix).store(login, as: "shortlived")
        }
    }

    @Test("a 200 that is not JSON is reported, and no token is invented")
    func notJSON() async throws {
        StubProtocol.reset(Self.tokenPath)
        StubProtocol.arm(.init(status: 200, body: Data("<html>gateway</html>".utf8)), for: Self.tokenPath)
        await #expect(throws: (any Error).self) {
            _ = try await Self.client().complete(code: "code-html", state: "the-state",
                                                 pkce: Self.pkce(), redirect: .manual)
        }
    }

    @Test("an error body reaches the panel with nothing token-shaped left in it")
    func scrubsErrorBodies() async throws {
        StubProtocol.reset(Self.tokenPath)
        let secret = "sk-ant-oat01-BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB"
        StubProtocol.arm(.init(status: 500, body: Data(#"{"detail":"boom \#(secret)"}"#.utf8)),
                         for: Self.tokenPath)
        do {
            _ = try await Self.client().complete(code: "code-scrub", state: "the-state",
                                                 pkce: Self.pkce(), redirect: .manual)
            Issue.record("a 500 is not a login")
        } catch {
            #expect("\(error)".contains("boom"))
            #expect("\(error)".contains(secret) == false)
        }
    }

    @Test("a profile that will not load does not lose the login")
    func profileOptional() async throws {
        StubProtocol.reset(Self.tokenPath)
        StubProtocol.reset(Self.profilePath)
        StubProtocol.arm(.init(status: 200, body: Self.tokenReply()), for: Self.tokenPath)
        StubProtocol.arm(.init(status: 500, body: Data()), for: Self.profilePath)

        let login = try await Self.client().complete(code: "code-profile-500", state: "the-state",
                                                     pkce: Self.pkce(), redirect: .manual)
        #expect(login.accessToken == "new-access")
        #expect(login.email == "someone@example.com")
        // The token response's account still becomes an oauthAccount, with no nulls.
        let accountJSON = try #require(login.accountJSON)
        let object = try #require(try JSONSerialization.jsonObject(with: accountJSON) as? [String: Any])
        #expect(object["emailAddress"] as? String == "someone@example.com")
        #expect(object.values.contains { $0 is NSNull } == false)
    }

    @Test("a profile that answers with nothing keeps the account the token response named")
    func emptyProfile() async throws {
        Self.armBoth(token: Self.tokenReply(), profile: Data("{}".utf8))
        let login = try await Self.client().complete(code: "code-profile-empty", state: "the-state",
                                                     pkce: Self.pkce(), redirect: .manual)
        // Taking that profile would leave the panel with no email to show before it writes.
        #expect(login.email == "someone@example.com")
        let accountJSON = try #require(login.accountJSON)
        let object = try #require(try JSONSerialization.jsonObject(with: accountJSON)
            as? [String: Any])
        #expect(object["emailAddress"] as? String == "someone@example.com")
    }

    @Test("a profile for a different account never renames the login")
    func profileForSomebodyElse() async throws {
        Self.armBoth(token: Self.tokenReply(),
                     profile: Self.profileReply(email: "someone-else@example.com", uuid: "acc-2"))
        let login = try await Self.client().complete(code: "code-profile-other", state: "the-state",
                                                     pkce: Self.pkce(), redirect: .manual)
        // The address the owner confirms against is the one these tokens belong to.
        #expect(login.email == "someone@example.com")
        #expect(login.warnings.contains { $0.contains("different account") })
        #expect(login.subscriptionType == nil)
    }

    @Test("the profile becomes an oauthAccount with no invented keys")
    func profileMapping() throws {
        let json = try #require(try JSONSerialization.jsonObject(with: Self.profileReply())
            as? [String: Any])
        let profile = OAuthLogin.profile(from: json)
        #expect(profile.account.emailAddress == "someone@example.com")
        #expect(profile.account.organizationName == "Personal")
        #expect(profile.account.organizationRateLimitTier == "default_claude_max_20x")
        #expect(profile.subscriptionType == "max")

        let object = try #require(try JSONSerialization.jsonObject(with: profile.json)
            as? [String: Any])
        // A null written here would delete a key the owner has in ~/.claude.json.
        #expect(object["seatTier"] == nil)
        #expect(object.values.contains { $0 is NSNull } == false)
        #expect(object["fullName"] as? String == "Some One")
        #expect(object["billingType"] as? String == "stripe")
    }

    @Test("expires_in is read defensively and never trusted to the second")
    func expiryMath() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(OAuthLogin.expiresAt(28800, now: now) == 1_028_740_000)
        // Some servers send it as a string.
        #expect(OAuthLogin.expiresAt("28800", now: now) == 1_028_740_000)
        // A window shorter than the margin is not negative time.
        #expect(OAuthLogin.expiresAt(10, now: now) == 1_000_000_000)
        for absurd in [0, -1, 400 * 24 * 3600] {
            #expect(OAuthLogin.expiresAt(absurd, now: now) == nil)
        }
        #expect(OAuthLogin.expiresAt(nil, now: now) == nil)
        #expect(OAuthLogin.expiresAt("soon", now: now) == nil)
    }

    @Test("organization types map the way the binary maps them")
    func subscriptionTypes() {
        #expect(OAuthLogin.subscriptionType("claude_max") == "max")
        #expect(OAuthLogin.subscriptionType("claude_pro") == "pro")
        #expect(OAuthLogin.subscriptionType("claude_enterprise") == "enterprise")
        #expect(OAuthLogin.subscriptionType(nil) == nil)
    }

    @Test("a long token in a server's text is replaced by its length")
    func scrubber() {
        let token = String(repeating: "a", count: 40)
        #expect(OAuthLogin.scrubbed("error: \(token) happened") == "error: <40 chars> happened")
        #expect(OAuthLogin.scrubbed("rate_limit_error at 12:00") == "rate_limit_error at 12:00")
    }
}
