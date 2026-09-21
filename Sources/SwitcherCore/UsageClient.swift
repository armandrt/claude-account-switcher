import Foundation

/// The call Claude Code's own `/usage` makes.
public struct UsageClient: Sendable {
    public static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    public static let betaHeader = "oauth-2025-04-20"

    let session: URLSession
    let endpoint: URL

    public init(session: URLSession = .shared, endpoint: URL = UsageClient.endpoint) {
        self.session = session
        self.endpoint = endpoint
    }

    /// A session whose only traffic goes through `protocolClass`, for tests.
    public static func stubbed(_ protocolClass: AnyClass) -> UsageClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return UsageClient(session: URLSession(configuration: configuration))
    }

    public func fetch(accessToken: String, now: Date = Date()) async throws -> UsageSnapshot {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 20
        // A reply served from URLCache would be an old reading wearing a fresh `fetchedAt`.
        request.cachePolicy = .reloadIgnoringLocalCacheData

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            return try UsageDecoder.decode(data, fetchedAt: now)
        case 401:
            throw UsageError.unauthorized
        case 429:
            throw UsageError.rateLimited(
                Self.retryAfter(http.value(forHTTPHeaderField: "Retry-After")))
        case 403:
            let body = String(data: data, encoding: .utf8) ?? ""
            if body.contains("oauth_scope_insufficient") { throw UsageError.scopeInsufficient }
            throw UsageError.http(403, String(body.prefix(200)))
        default:
            let body = String(data: data, encoding: .utf8) ?? ""
            throw UsageError.http(http.statusCode, String(body.prefix(200)))
        }
    }

    /// `Retry-After` in delta-seconds, when it says something usable.
    ///
    /// This endpoint really answers `0`, which cannot be taken literally, so a
    /// non-positive hint is absent. So is anything that is not a plain number:
    /// `Double("inf")` and `Double("nan")` both parse, and an infinite hint would
    /// park the app until it is relaunched. The HTTP-date form is not accepted —
    /// it has never been sent, and guessing at a clock skew is worse than using
    /// our own ladder.
    static func retryAfter(_ header: String?) -> TimeInterval? {
        guard let text = header?.trimmingCharacters(in: .whitespaces),
              let seconds = TimeInterval(text), seconds.isFinite, seconds > 0
        else { return nil }
        return seconds
    }
}
