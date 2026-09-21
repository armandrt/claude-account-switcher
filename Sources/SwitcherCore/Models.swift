import Foundation

/// The `claudeAiOauth` object inside a `Claude Code-credentials` payload.  Unknown keys are
/// ignored on decode; writes go through `CredentialPayload.withRotatedTokens`, never this type.
public struct OAuthCredentials: Codable, Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// Milliseconds since the epoch, as Claude Code stores them.
    public var expiresAt: Double?
    public var refreshTokenExpiresAt: Double?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Double? = nil,
                refreshTokenExpiresAt: Double? = nil, scopes: [String] = [],
                subscriptionType: String? = nil, rateLimitTier: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.refreshTokenExpiresAt = refreshTokenExpiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
    }

    enum CodingKeys: String, CodingKey {
        case accessToken, refreshToken, expiresAt, refreshTokenExpiresAt
        case scopes, subscriptionType, rateLimitTier
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decodeIfPresent(String.self, forKey: .accessToken) ?? ""
        refreshToken = try c.decodeIfPresent(String.self, forKey: .refreshToken)
        expiresAt = try c.decodeIfPresent(Double.self, forKey: .expiresAt)
        refreshTokenExpiresAt = try c.decodeIfPresent(Double.self, forKey: .refreshTokenExpiresAt)
        scopes = try c.decodeIfPresent([String].self, forKey: .scopes) ?? []
        subscriptionType = try c.decodeIfPresent(String.self, forKey: .subscriptionType)
        rateLimitTier = try c.decodeIfPresent(String.self, forKey: .rateLimitTier)
    }

    public var expiry: Date? { expiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }
    public var refreshExpiry: Date? { refreshTokenExpiresAt.map { Date(timeIntervalSince1970: $0 / 1000) } }

    public func isExpired(now: Date = Date()) -> Bool {
        guard let expiry else { return false }
        return expiry <= now
    }

    public func refreshTokenIsDead(now: Date = Date()) -> Bool {
        guard let refreshExpiry else { return refreshToken == nil }
        return refreshExpiry <= now
    }

    /// `/api/oauth/usage` needs `user:profile`; `setup-token` tokens do not have it.
    public var canReadUsage: Bool { scopes.contains("user:profile") }
}

/// Interpolating the struct (in an error, a log line, a test failure) must never print a token.
extension OAuthCredentials: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "OAuthCredentials(access: \(Redact.token(accessToken)), refresh: \(Redact.token(refreshToken)), "
            + "expires: \(expiry.map(String.init(describing:)) ?? "—"), tier: \(rateLimitTier ?? "—"))"
    }

    public var debugDescription: String { description }
}
