import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// Signing in from inside the app.  The browser is a closure here and both
/// endpoints are stubs, so nothing opens and nothing is written outside the
/// in-memory keychain.  The loopback listener is the one piece left out: it
/// binds a socket, so these tests drive the paste fallback instead.
@Suite("Add account")
@MainActor
struct AddAccountTests {
    static let profileJSON = """
    {"account":{"email_address":"new@example.com","uuid":"abc-123","full_name":"A Name"},
     "organization":{"uuid":"org-1","name":"Org","organization_type":"claude_max",
                     "rate_limit_tier":"default_claude_max_20x"}}
    """

    static func tokenJSON(refresh: String = "new-refresh") -> String {
        """
        {"access_token":"new-access","refresh_token":"\(refresh)","expires_in":3600,
         "account":{"email_address":"new@example.com","uuid":"abc-123"}}
        """
    }

    /// Takes the sign-in as far as the panel showing whose account came back.
    static func mint(_ world: AppWorld, as name: String) async throws {
        AppStub.arm(json: tokenJSON(), for: world.loginTokenURL)
        AppStub.arm(json: profileJSON, for: world.profileURL)
        world.model.captureName = name
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)
        let pkce = try #require(world.model.loginPKCE)
        world.model.login?.pasted = "the-code#\(pkce.state)"
        world.model.submitPastedCode()
        _ = await settle { world.model.login?.stage == .confirming }
    }

    @Test("a name that is not usable is refused before the browser opens")
    func badNameIsRefused() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.captureName = "not a name"
        world.model.beginAddAccount()
        world.model.openSignIn()
        #expect(world.model.login?.stage == .naming)
        #expect(world.model.login?.error?.contains("not a usable slot name") == true)
        #expect(world.opened.isEmpty)
        world.model.cancelLogin()
        #expect(world.model.login == nil)
        #expect(world.model.loginPKCE == nil)
    }

    @Test("a name that already holds a working login is refused, and the live one twice over")
    func takenNamesAreRefused() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.captureName = "pro"
        world.model.beginAddAccount()
        world.model.openSignIn()
        #expect(world.model.login?.error?.contains("already holds a working login") == true)
        #expect(world.opened.isEmpty)

        world.model.captureName = "perso2"
        world.model.beginAddAccount()
        world.model.openSignIn()
        #expect(world.model.login?.error?.contains("is the live login") == true)
        #expect(world.opened.isEmpty)
        world.model.cancelLogin()
    }

    @Test("the live row is never offered a repair")
    func repairRefusesTheLiveSlot() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.beginRepair(of: "perso2")
        #expect(world.model.login == nil)
        #expect(world.model.actionError?.contains("is the live login") == true)
    }

    @Test("a corrupt row is repairable, and says that signing in is the repair")
    func repairExplainsACorruptSlot() async throws {
        var items = AppWorld.defaultItems()
        items[AppWorld.prefix + "pro"] = Data("truncated".utf8)
        let world = try AppWorld(items: items)
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.beginRepair(of: "pro")
        let login = try #require(world.model.login)
        #expect(login.isRepair)
        #expect(login.name == "pro")
        #expect(login.warnings.first?.contains("signing in again is the repair") == true)
        world.model.cancelLogin()
    }

    @Test("the paste page is opened with an S256 challenge and the code-display redirect")
    func manualSignInOpensTheRightURL() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()

        world.model.captureName = "spare"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)

        #expect(world.model.login?.stage == .pasting)
        #expect(world.opened.count == 1)
        let opened = try #require(world.opened.first)
        let components = try #require(URLComponents(url: opened, resolvingAgainstBaseURL: false))
        let query = try #require(components.queryItems)
        func value(_ name: String) -> String? { query.first { $0.name == name }?.value }
        #expect(value("code_challenge_method") == "S256")
        #expect(value("code_challenge") == world.model.loginPKCE?.challenge)
        #expect(value("state") == world.model.loginPKCE?.state)
        #expect(value("redirect_uri") == world.manualRedirectURL.absoluteString)
        #expect(value("client_id") == "test-client")
        world.model.cancelLogin()
    }

    @Test("half a pasted code is refused without spending it")
    func malformedPasteIsRefused() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.model.captureName = "spare"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)

        world.model.login?.pasted = "just-a-code"
        world.model.submitPastedCode()
        #expect(world.model.login?.stage == .pasting)
        #expect(world.model.login?.error?.contains("copy all of it") == true)
        #expect(AppStub.calls(for: world.loginTokenURL).isEmpty)
        world.model.cancelLogin()
    }

    @Test("the email is on screen before anything is written, and the button writes it")
    func signInStoresOnlyAfterTheEmailIsShown() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.armUsage()

        try await Self.mint(world, as: "spare")
        #expect(world.model.login?.stage == .confirming)
        #expect(world.model.login?.minted?.email == "new@example.com")
        #expect(world.model.loginPKCE == nil, "the verifier is spent with the code")
        #expect(world.keychain.item(AppWorld.prefix + "spare") == nil, "nothing written yet")

        world.model.confirmLogin()
        #expect(await settle { world.model.login == nil })
        let stored = try #require(world.keychain.item(AppWorld.prefix + "spare"))
        let payload = try CredentialPayload.parse(stored)
        #expect(payload.credentials.accessToken == "new-access")
        #expect(payload.credentials.refreshToken == "new-refresh")
        #expect(payload.account?.emailAddress == "new@example.com")
        #expect(payload.account?.organizationRateLimitTier == "default_claude_max_20x")
        #expect(world.model.captureName == "")
        // The live login is exactly where it was.
        #expect(world.liveAccessToken() == "live-access")
        #expect(world.marker() == "perso2")
        #expect(world.configEmail() == "live@example.com")
        await world.expectNothingStuck()
    }

    @Test("a second slot for an account already stored is called out, not refused")
    func duplicateEmailWarns() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        AppStub.arm(json: """
        {"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,
         "account":{"email_address":"pro@example.com","uuid":"abc"}}
        """, for: world.loginTokenURL)
        AppStub.arm(json: #"{"account":{"email_address":"pro@example.com"},"organization":{}}"#,
                    for: world.profileURL)

        world.model.captureName = "pro-again"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)
        let pkce = try #require(world.model.loginPKCE)
        world.model.login?.pasted = "code#\(pkce.state)"
        world.model.submitPastedCode()
        #expect(await settle { world.model.login?.stage == .confirming })
        #expect(world.model.login?.warnings.contains { $0.contains("already stored as pro") } == true)
        world.model.cancelLogin()
    }

    @Test("a login with no refresh token is refused at the write, and says why")
    func noRefreshTokenIsRefused() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        AppStub.arm(json: """
        {"access_token":"new-access","expires_in":3600,
         "account":{"email_address":"new@example.com","uuid":"abc"}}
        """, for: world.loginTokenURL)
        AppStub.arm(json: Self.profileJSON, for: world.profileURL)

        world.model.captureName = "spare"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)
        let pkce = try #require(world.model.loginPKCE)
        world.model.login?.pasted = "code#\(pkce.state)"
        world.model.submitPastedCode()
        #expect(await settle { world.model.login?.stage == .confirming })

        world.model.confirmLogin()
        #expect(await settle { world.model.login?.stage == .confirming
                               && world.model.login?.error != nil })
        #expect(world.model.login?.error?.contains("no refresh token") == true)
        #expect(world.keychain.item(AppWorld.prefix + "spare") == nil)
        world.model.cancelLogin()
    }

    @Test("a token exchange that fails leaves the panel usable, not stuck on storing")
    func failedExchangeIsNotStuck() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        AppStub.arm(json: #"{"error":"invalid_grant"}"#, status: 400, for: world.loginTokenURL)

        world.model.captureName = "spare"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)
        let pkce = try #require(world.model.loginPKCE)
        world.model.login?.pasted = "code#\(pkce.state)"
        world.model.submitPastedCode()

        #expect(await settle { world.model.login?.error != nil })
        #expect(world.model.login?.stage == .pasting, "back where it can be tried again")
        #expect(world.model.loginPKCE != nil, "the same pair still matches the page that is open")
        #expect(world.keychain.item(AppWorld.prefix + "spare") == nil)
        #expect(world.logText().contains("sign-in failed"))
        world.model.cancelLogin()
        #expect(world.model.login == nil)
        #expect(world.model.loginPKCE == nil)
    }

    @Test("a state that does not match the one that was sent is thrown out")
    func stateMismatchIsRefused() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        AppStub.arm(json: Self.tokenJSON(), for: world.loginTokenURL)

        world.model.captureName = "spare"
        world.model.beginAddAccount()
        world.model.openSignIn(manual: true)
        world.model.login?.pasted = "code#someone-elses-state"
        world.model.submitPastedCode()

        #expect(await settle { world.model.login?.error != nil })
        #expect(AppStub.calls(for: world.loginTokenURL).isEmpty, "never sent")
        #expect(world.model.login?.stage != .storing)
        world.model.cancelLogin()
    }

    @Test("a slot that became the live one while the browser was open is not overwritten")
    func liveSlotIsRefusedAtTheWrite() async throws {
        let world = try AppWorld()
        defer { world.cleanUp() }
        await world.model.reloadSlots()
        world.armUsage()

        try await Self.mint(world, as: "spare")
        // The panel was open; a switch happened behind it.
        world.keychain.box.items[AppWorld.prefix + "spare"] =
            AppWorld.slot(access: "spare-access", email: "spare@example.com")
        try Data("spare\n".utf8).write(to: world.markerURL)
        await world.model.reloadSlots()

        world.model.confirmLogin()
        #expect(world.model.login?.error?.contains("is the live login") == true)
        #expect(world.storedAccessToken("spare") == "spare-access", "not overwritten")
    }
}
