import Foundation

/// The `oauthAccount` object `claude-acct` copies out of `~/.claude.json`.
public struct OAuthAccount: Codable, Equatable, Sendable {
    public var emailAddress: String?
    public var displayName: String?
    public var organizationName: String?
    public var organizationRole: String?
    public var userRateLimitTier: String?
    public var organizationRateLimitTier: String?
    public var accountUuid: String?

    public init(emailAddress: String? = nil, displayName: String? = nil,
                organizationName: String? = nil, organizationRole: String? = nil,
                userRateLimitTier: String? = nil, organizationRateLimitTier: String? = nil,
                accountUuid: String? = nil) {
        self.emailAddress = emailAddress
        self.displayName = displayName
        self.organizationName = organizationName
        self.organizationRole = organizationRole
        self.userRateLimitTier = userRateLimitTier
        self.organizationRateLimitTier = organizationRateLimitTier
        self.accountUuid = accountUuid
    }

    /// The organisation's tier wins, as Claude Code uses it.
    public var planTier: String? { organizationRateLimitTier ?? userRateLimitTier }
}

/// A `Claude Code Login: <name>` payload: `{credentials, oauthAccount}`.  The raw JSON is
/// kept so writes can copy values byte for byte instead of re-encoding them.
public struct CredentialPayload: Equatable, Sendable {
    public var credentials: OAuthCredentials
    public var account: OAuthAccount?
    public let raw: Data

    public enum ParseError: Error, Equatable, CustomStringConvertible {
        case notJSON(bytes: Int)
        case noOAuthObject(bytes: Int)
        case noAccessToken

        public var description: String {
            switch self {
            case .notJSON(let n): return "not valid JSON (\(n) bytes — looks truncated)"
            case .noOAuthObject(let n): return "no credentials.claudeAiOauth object (\(n) bytes)"
            case .noAccessToken: return "no access token in the payload"
            }
        }
    }
}

extension CredentialPayload {
    /// Parses a slot payload; `liveShape` parses the bare `{claudeAiOauth: …}` live item.
    public static func parse(_ data: Data, liveShape: Bool = false) throws -> CredentialPayload {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let root = any as? [String: Any] else {
            throw ParseError.notJSON(bytes: data.count)
        }
        let credentialsObject: [String: Any]
        if liveShape {
            credentialsObject = root
        } else {
            credentialsObject = (root["credentials"] as? [String: Any]) ?? [:]
        }
        guard let oauth = credentialsObject["claudeAiOauth"] as? [String: Any] else {
            throw ParseError.noOAuthObject(bytes: data.count)
        }
        let oauthData = try JSONSerialization.data(withJSONObject: oauth)
        let creds = try JSONDecoder().decode(OAuthCredentials.self, from: oauthData)
        guard !creds.accessToken.isEmpty else { throw ParseError.noAccessToken }

        var account: OAuthAccount?
        if let accountObject = root["oauthAccount"] as? [String: Any],
           let accountData = try? JSONSerialization.data(withJSONObject: accountObject) {
            account = try? JSONDecoder().decode(OAuthAccount.self, from: accountData)
        }
        return CredentialPayload(credentials: creds, account: account, raw: data)
    }

    /// The payload with the rotated token fields replaced.  Every key survives (including
    /// ones this build has never heard of), but the JSON is re-encoded with sorted keys.
    public func withRotatedTokens(accessToken: String, refreshToken: String?,
                                  expiresAt: Double?, liveShape: Bool = false) throws -> Data {
        guard var root = try JSONSerialization.jsonObject(with: raw) as? [String: Any] else {
            throw ParseError.notJSON(bytes: raw.count)
        }
        let key = liveShape ? nil : "credentials"
        var credentialsObject = key.map { (root[$0] as? [String: Any]) ?? [:] } ?? root
        guard var oauth = credentialsObject["claudeAiOauth"] as? [String: Any] else {
            throw ParseError.noOAuthObject(bytes: raw.count)
        }
        oauth["accessToken"] = accessToken
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        credentialsObject["claudeAiOauth"] = oauth
        if let key {
            root[key] = credentialsObject
        } else {
            root = credentialsObject
        }
        let out = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        _ = try CredentialPayload.parse(out, liveShape: liveShape)
        return out
    }
}

extension CredentialPayload {
    /// The raw bytes of the `credentials` value; a switch copies these into the live item unchanged.
    public var credentialsJSON: Data? {
        guard let range = try? JSONSplice.valueRange(of: "credentials", in: raw) else { return nil }
        return raw.subdata(in: range)
    }

    /// The raw bytes of the `oauthAccount` value.
    public var accountJSON: Data? {
        guard let range = try? JSONSplice.valueRange(of: "oauthAccount", in: raw) else { return nil }
        return raw.subdata(in: range)
    }

    /// The `{credentials, oauthAccount}` payload a capture writes, composed textually so
    /// both values go in byte for byte; parsed before it is handed back.
    public static func slotPayload(credentials: Data, account: Data?) throws -> Data {
        var out = Data(#"{"credentials":"#.utf8)
        out.append(credentials)
        out.append(Data(#","oauthAccount":"#.utf8))
        out.append(account ?? Data("{}".utf8))
        out.append(Data("}".utf8))
        _ = try CredentialPayload.parse(out)
        return out
    }
}
