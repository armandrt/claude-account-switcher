import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage client", .serialized)
struct UsageClientTests {
    @Test("sends the OAuth headers Claude Code sends")
    func headers() async throws {
        StubProtocol.reset(StubPath.usage)
        StubProtocol.arm(.init(status: 200, body: try Fixture.usageResponse()), for: StubPath.usage)
        let client = UsageClient.stubbed(StubProtocol.self)

        let snapshot = try await client.fetch(accessToken: "sk-ant-oat01-TESTTOKEN")
        #expect(snapshot.weeklyPercent == 69)

        let request = try #require(StubProtocol.calls(for: StubPath.usage).last?.request)
        #expect(request.url == UsageClient.endpoint)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-ant-oat01-TESTTOKEN")
        #expect(request.value(forHTTPHeaderField: "anthropic-beta") == "oauth-2025-04-20")
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
    }

    @Test("401 and the setup-token 403 are told apart")
    func statuses() async throws {
        StubProtocol.reset(StubPath.usage)
        let client = UsageClient.stubbed(StubProtocol.self)

        StubProtocol.arm(.init(status: 401, body: Data("{}".utf8)), for: StubPath.usage)
        await #expect(throws: UsageError.unauthorized) { try await client.fetch(accessToken: "x") }

        StubProtocol.arm(.init(status: 403,
            body: Data(#"{"error":{"type":"oauth_scope_insufficient"}}"#.utf8)), for: StubPath.usage)
        await #expect(throws: UsageError.scopeInsufficient) { try await client.fetch(accessToken: "x") }

        StubProtocol.arm(.init(status: 503, body: Data("busy".utf8)), for: StubPath.usage)
        await #expect(throws: UsageError.http(503, "busy")) { try await client.fetch(accessToken: "x") }

        StubProtocol.arm(.init(status: 429, body: Data(#"{"error":{"type":"rate_limit_error"}}"#.utf8)),
                         for: StubPath.usage)
        await #expect(throws: UsageError.rateLimited(nil)) { try await client.fetch(accessToken: "x") }
        #expect(UsageError.rateLimited(90).bannerText == "rate limited — showing the last reading")
    }

    @Test("a Retry-After that says nothing usable is absent, not a wait")
    func retryAfterHints() {
        #expect(UsageClient.retryAfter("120") == 120)
        #expect(UsageClient.retryAfter(" 90 ") == 90)
        // What this endpoint actually sends, and what it must not be read as.
        #expect(UsageClient.retryAfter("0") == nil)
        #expect(UsageClient.retryAfter("-30") == nil)
        // Both of these parse as doubles, and an infinite wait never ends.
        #expect(UsageClient.retryAfter("inf") == nil)
        #expect(UsageClient.retryAfter("nan") == nil)
        #expect(UsageClient.retryAfter("1e400") == nil)
        // The HTTP-date form has never been sent; guessing at a clock skew is worse
        // than falling back on our own ladder.
        #expect(UsageClient.retryAfter("Wed, 21 Oct 2026 07:28:00 GMT") == nil)
        #expect(UsageClient.retryAfter(nil) == nil)
    }

    @Test("a broken payload surfaces as a shape change")
    func brokenBody() async throws {
        StubProtocol.reset(StubPath.usage)
        StubProtocol.arm(.init(status: 200, body: Data("nope".utf8)), for: StubPath.usage)
        let client = UsageClient.stubbed(StubProtocol.self)
        await #expect(throws: (any Error).self) { try await client.fetch(accessToken: "x") }
    }
}
