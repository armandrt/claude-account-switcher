import CryptoKit
import Foundation

/// The OAuth flow `/login` performs, performed from here instead.
///
/// Read out of the Claude Code binary (2.1.263), not guessed: one public client
/// id (`9d1c250a-…`, no `client_secret` anywhere); PKCE S256 unconditionally;
/// the redirect is `http://localhost:<port>/callback` on a port the OS picks,
/// so arbitrary-port loopback is registered (RFC 8252 §7.3) and the hostname
/// is `localhost`, not `127.0.0.1`; the token exchange is JSON, not
/// form-encoded, with `client_id` and `state` in the body.
///
/// Nothing here touches the live login: a minted account goes into its own slot.
public struct OAuthLogin: Sendable {
    public struct Endpoints: Sendable {
        public var clientID: String
        /// Answers 307 to claude.ai's own authorize page with the query untouched.
        public var authorizeURL: URL
        public var tokenURL: URL
        public var profileURL: URL
        /// Anthropic's page that shows the code on screen, for the paste fallback.
        public var manualRedirect: URL
        public var scopes: [String]

        public init(clientID: String, authorizeURL: URL, tokenURL: URL, profileURL: URL,
                    manualRedirect: URL, scopes: [String]) {
            self.clientID = clientID
            self.authorizeURL = authorizeURL
            self.tokenURL = tokenURL
            self.profileURL = profileURL
            self.manualRedirect = manualRedirect
            self.scopes = scopes
        }

        /// The five scopes a subscription login is granted. Claude Code also asks
        /// for `org:create_api_key`, which is not granted and not needed here.
        public static let claudeCodeScopes = [
            "user:profile", "user:inference", "user:sessions:claude_code",
            "user:mcp_servers", "user:file_upload",
        ]

        public static let claudeAI = Endpoints(
            clientID: TokenRefresher.claudeCodeClientID,
            authorizeURL: URL(string: "https://claude.com/cai/oauth/authorize")!,
            tokenURL: TokenRefresher.defaultEndpoint,
            profileURL: URL(string: "https://api.anthropic.com/api/oauth/profile")!,
            manualRedirect: URL(string: "https://platform.claude.com/oauth/code/callback")!,
            scopes: claudeCodeScopes)
    }

    /// Where the authorization server sends the code back to.
    public enum Redirect: Equatable, Sendable {
        case loopback(port: Int)
        case manual

        public func url(_ endpoints: Endpoints) -> String {
            switch self {
            case .loopback(let port): return "http://localhost:\(port)/callback"
            case .manual: return endpoints.manualRedirect.absoluteString
            }
        }
    }

    /// Its own session rather than `URLSession.shared`: the shared one has a
    /// disk cache and a cookie jar, and a profile response names the owner.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    public let endpoints: Endpoints
    let session: URLSession

    public init(endpoints: Endpoints = .claudeAI, session: URLSession = OAuthLogin.privateSession) {
        self.endpoints = endpoints
        self.session = session
    }

    public static func stubbed(_ protocolClass: AnyClass, endpoints: Endpoints = .claudeAI) -> OAuthLogin {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return OAuthLogin(endpoints: endpoints, session: URLSession(configuration: configuration))
    }
}

public enum LoginError: Error, Equatable, CustomStringConvertible {
    /// The consent screen was refused, or the window was closed on it.
    case denied(String)
    /// A callback carrying a `state` this app did not issue.
    case stateMismatch
    case noCode
    /// `invalid_grant`: a code is good for one use and about a minute.
    case codeExpired
    case http(Int, String)
    case badResponse(String)
    case transport(String)
    /// The paste field got something that is not `<code>#<state>`.
    case malformedPaste

    public var description: String {
        switch self {
        case .denied(let why): return "the sign-in was not completed: \(why)"
        case .stateMismatch:
            return "that callback was not for this sign-in — nothing was exchanged"
        case .noCode: return "the browser came back without an authorization code"
        case .codeExpired:
            return "that code has expired or was already used — start the sign-in again"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse(let why): return "unexpected token response: \(why)"
        case .transport(let why): return "network: \(why)"
        case .malformedPaste:
            return "that does not look like the whole code — copy all of it, including the part after the #"
        }
    }
}

// MARK: - The authorize URL

extension OAuthLogin {
    /// The URL the browser opens, parameter for parameter as Claude Code builds it.
    public func authorizeURL(pkce: PKCE, redirect: Redirect) -> URL {
        var components = URLComponents(url: endpoints.authorizeURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            // `code=true` makes the page show the code as well, which is what the paste fallback relies on.
            URLQueryItem(name: "code", value: "true"),
            URLQueryItem(name: "client_id", value: endpoints.clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect.url(endpoints)),
            URLQueryItem(name: "scope", value: endpoints.scopes.joined(separator: " ")),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "code_challenge_method", value: pkce.method),
            URLQueryItem(name: "state", value: pkce.state),
        ]
        return components.url!
    }

    /// The paste flow hands back `<code>#<state>` as one string. Empty pieces are
    /// kept, so half a code, or `a##b`, is a malformed paste and not a plausible pair.
    public static func splitPastedCode(_ pasted: String) throws -> (code: String, state: String) {
        let parts = pasted.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "#", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw LoginError.malformedPaste
        }
        return (String(parts[0]), String(parts[1]))
    }
}

// MARK: - Codes are good once

/// Which codes this process has already put on the wire, as salted hashes: the
/// Return key and the button both fire, and a second exchange of one code is an
/// `invalid_grant` that reads like a dead account. Nothing here holds a code.
final class SpentCodes: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [String] = []
    private let salt = PKCE.randomURLSafe(bytes: 16)
    private let limit = 16

    static let shared = SpentCodes()

    private func fingerprint(_ code: String, _ state: String) -> String {
        PKCE.base64URL(Data(SHA256.hash(data: Data("\(salt)|\(state)|\(code)".utf8))))
    }

    /// False when this pair has already been exchanged in this process.
    func claim(code: String, state: String) -> Bool {
        let mark = fingerprint(code, state)
        return lock.withLock {
            guard !seen.contains(mark) else { return false }
            seen.append(mark)
            if seen.count > limit { seen.removeFirst(seen.count - limit) }
            return true
        }
    }

    /// A request that never reached the server leaves the code unused.
    func release(code: String, state: String) {
        let mark = fingerprint(code, state)
        lock.withLock { seen.removeAll { $0 == mark } }
    }
}

// MARK: - The exchange

extension OAuthLogin {
    /// Checks the state, swaps the code for tokens, then asks who they belong to.
    public func complete(code: String, state: String, pkce: PKCE, redirect: Redirect,
                         now: Date = Date()) async throws -> MintedLogin {
        guard PKCE.equal(state, pkce.state) else { throw LoginError.stateMismatch }
        guard !code.isEmpty else { throw LoginError.noCode }
        // A code lives about a minute; a verifier older than the pair's lifetime
        // belongs to a sign-in nobody is waiting on.
        guard !pkce.isStale(now: now) else { throw LoginError.codeExpired }
        guard SpentCodes.shared.claim(code: code, state: state) else { throw LoginError.codeExpired }

        let body: [String: Any] = [
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect.url(endpoints),
            "client_id": endpoints.clientID,
            "code_verifier": pkce.verifier,
            "state": state,
        ]
        let json: [String: Any]
        do {
            json = try await post(endpoints.tokenURL, body: body)
        } catch LoginError.transport(let why) {
            // Nothing reached the server, so the code is still good: let it be retried.
            SpentCodes.shared.release(code: code, state: state)
            throw LoginError.transport(why)
        }

        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw LoginError.badResponse("no access_token in a 200")
        }
        var login = MintedLogin(
            accessToken: accessToken,
            refreshToken: (json["refresh_token"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            expiresAt: Self.expiresAt(json["expires_in"], now: now),
            scopes: (json["scope"] as? String)?.split(separator: " ").map(String.init)
                ?? endpoints.scopes)
        if login.refreshToken == nil {
            login.warnings.append("the sign-in came back without a refresh token, so this login would "
                + "stop working in a few hours — it is not stored")
        }
        if !login.scopes.contains("user:profile") {
            login.warnings.append("this login was not granted user:profile, so its quota cannot be read")
        }

        // The token response names the account; the profile fills in the rest.
        // A profile that will not load is not fatal, the slot works without it.
        if let account = json["account"] as? [String: Any] {
            login.account = OAuthAccount(
                emailAddress: (account["email_address"] ?? account["email"]) as? String,
                accountUuid: account["uuid"] as? String)
        }
        if let fetched = try? await profile(accessToken: accessToken) {
            if let mismatch = Self.mismatch(login.account, fetched.account) {
                // The token response is the one that describes these tokens; a
                // profile for somebody else names an account the owner would confirm.
                login.warnings.append(mismatch)
            } else {
                login.subscriptionType = fetched.subscriptionType
                login.rateLimitTier = fetched.rateLimitTier
                // A profile with no email would lose the address the panel shows before writing.
                if fetched.account.emailAddress != nil {
                    login.account = fetched.account
                    login.accountJSON = fetched.json
                }
            }
        }
        if login.accountJSON == nil, let account = login.account {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            login.accountJSON = try? encoder.encode(account)
        }
        return login
    }

    /// `expires_in` is the server's clock; this one may be minutes off, so a
    /// margin comes off it, and a value outside all reason is treated as absent
    /// rather than stored as an expiry in the year 4000.
    static func expiresAt(_ value: Any?, now: Date) -> Double? {
        guard let seconds = UsageDecoder.double(value), seconds > 0,
              seconds <= 90 * 24 * 3600 else { return nil }
        let safe = max(0, seconds - TokenRefresher.clockSkew)
        return ((now.timeIntervalSince1970 + safe) * 1000).rounded()
    }

    /// Non-nil when the profile describes a different account from the one the
    /// tokens came with; both halves have to be known for it to count.
    static func mismatch(_ token: OAuthAccount?, _ profile: OAuthAccount) -> String? {
        guard let token else { return nil }
        func differs(_ left: String?, _ right: String?) -> Bool {
            guard let left, let right, !left.isEmpty, !right.isEmpty else { return false }
            return left.caseInsensitiveCompare(right) != .orderedSame
        }
        guard differs(token.accountUuid, profile.accountUuid)
                || differs(token.emailAddress, profile.emailAddress) else { return nil }
        return "the profile came back for a different account than the sign-in did, so the "
            + "sign-in's own account was kept — check the address before storing this"
    }

    /// A server's error text reaches the panel and the log. Anything long enough
    /// to be a token, a code or a verifier is replaced by its length first.
    static func scrubbed(_ text: String) -> String {
        var out = "", run = ""
        func flush() {
            out += run.count >= 24 ? "<\(run.count) chars>" : run
            run = ""
        }
        for character in text {
            if character.isLetter || character.isNumber
                || character == "-" || character == "_" || character == "." {
                run.append(character)
            } else {
                flush()
                out.append(character)
            }
        }
        flush()
        return out
    }

    private func post(_ url: URL, body: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 30

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LoginError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw LoginError.badResponse("no HTTP response")
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            if text.contains("invalid_grant") { throw LoginError.codeExpired }
            throw LoginError.http(http.statusCode, Self.scrubbed(String(text.prefix(400))))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoginError.badResponse("a 200 that is not a JSON object (\(data.count) bytes)")
        }
        return json
    }
}

// MARK: - Who it belongs to

extension OAuthLogin {
    public struct Profile: Sendable {
        public var account: OAuthAccount
        /// The `oauthAccount` object as bytes, ready to splice into `~/.claude.json`.
        public var json: Data
        public var subscriptionType: String?
        public var rateLimitTier: String?
    }

    public func profile(accessToken: String) async throws -> Profile {
        var request = URLRequest(url: endpoints.profileURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw LoginError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw LoginError.http(code, "the profile could not be read")
        }
        return Self.profile(from: json)
    }

    /// Maps the profile response onto the `oauthAccount` shape in `~/.claude.json`.
    /// Only keys actually present are written: a null invented here would delete
    /// a key the owner has, since a switch copies this object over theirs.
    public static func profile(from json: [String: Any]) -> Profile {
        let account = json["account"] as? [String: Any] ?? [:]
        let organization = json["organization"] as? [String: Any] ?? [:]

        var object: [String: Any] = [:]
        func carry(_ key: String, _ value: Any?) {
            if let value, !(value is NSNull) { object[key] = value }
        }
        carry("emailAddress", account["email_address"] ?? account["email"])
        carry("accountUuid", account["uuid"])
        carry("displayName", account["display_name"])
        carry("fullName", account["full_name"])
        carry("organizationUuid", organization["uuid"])
        carry("organizationName", organization["name"])
        carry("organizationRole", organization["role"] ?? account["organization_role"])
        carry("organizationType", organization["organization_type"])
        carry("organizationRateLimitTier", organization["rate_limit_tier"])
        carry("billingType", organization["billing_type"])
        carry("seatTier", organization["seat_tier"])

        let decoded = (try? JSONSerialization.data(withJSONObject: object))
            .flatMap { try? JSONDecoder().decode(OAuthAccount.self, from: $0) }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return Profile(account: decoded ?? OAuthAccount(),
                       json: data,
                       subscriptionType: subscriptionType(organization["organization_type"] as? String),
                       rateLimitTier: organization["rate_limit_tier"] as? String)
    }

    /// The binary's own mapping: `claude_max` → `max`, and so on.
    static func subscriptionType(_ organizationType: String?) -> String? {
        guard let organizationType else { return nil }
        if organizationType.hasPrefix("claude_") { return String(organizationType.dropFirst(7)) }
        return organizationType
    }
}
