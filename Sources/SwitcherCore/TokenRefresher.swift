import Foundation

public enum RefreshError: Error, Equatable, CustomStringConvertible {
    /// Claude Code owns the live item and its refresh lock; the app never touches it.
    case refusedLiveSlot(String)
    case noRefreshToken
    case refreshTokenExpired
    /// `invalid_grant`: the refresh token is dead and only a new login fixes it.
    case needsRelogin(String)
    case http(Int, String)
    case badResponse(String)
    case transport(String)
    case writeBack(String)
    /// The slot was removed, replaced or switched to while it was being renewed.
    case slotChanged(String)

    public var description: String {
        switch self {
        case .refusedLiveSlot(let name): return "refused to refresh \(name): it is the live login"
        case .noRefreshToken: return "no refresh token stored"
        case .refreshTokenExpired: return "refresh token past refreshTokenExpiresAt"
        case .needsRelogin(let why): return "needs re-login: \(why)"
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .badResponse(let why): return "unexpected token response: \(why)"
        case .transport(let why): return "network: \(why)"
        case .writeBack(let why): return "refreshed but could not store: \(why)"
        case .slotChanged(let why): return why
        }
    }

    public var needsLoginAgain: Bool {
        switch self {
        case .needsRelogin, .refreshTokenExpired, .noRefreshToken: return true
        default: return false
        }
    }
}

/// Refreshes the access token of an inactive slot and writes the rotated tokens
/// back. Single-flight per slot: concurrent callers share one network call.
///
/// The rule the whole type is built around: **the moment the server answers
/// 200, the old refresh token is dead and the new one exists only here.** So
/// nothing is sent until the stored copy has been re-read (it may already have
/// been renewed by something else), nothing is discarded when a write fails,
/// and no keychain call is allowed to block the actor — a permission dialog
/// would otherwise freeze every renewal and the Retry save button with it.
public actor TokenRefresher {
    /// Claude Code's public OAuth client id, the one its login flow uses.
    public static let claudeCodeClientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    public static let defaultEndpoint = URL(string: "https://platform.claude.com/v1/oauth/token")!
    /// This clock and the server's are not the same clock; a token inside this
    /// window of its expiry counts as expired, and `expires_in` is shortened by it.
    public static let clockSkew: TimeInterval = 60
    public static let defaultKeychainDeadline: TimeInterval = 20

    /// Its own session: `URLSession.shared` has a disk cache and a cookie jar.
    public static let privateSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: configuration)
    }()

    let session: URLSession
    let endpoint: URL
    let clientID: String
    let writer: KeychainWriting?
    /// Reads a slot back after writing it; a keychain write is not trusted until it is read.
    let reader: KeychainReading?
    let servicePrefix: String
    let keychainDeadline: TimeInterval
    let liveSlotName: @Sendable () -> String?
    /// The address Claude Code is logged in as. The marker can be stale — a
    /// `/login` moves the live login without moving it — and renewing the slot
    /// that really holds the live account retires the token Claude Code is using.
    let liveAccountEmail: @Sendable () -> String?

    private var inFlight: [String: Task<OAuthCredentials, Error>] = [:]
    private var writeBacks: [String: Task<Void, Error>] = [:]
    /// Rotated tokens the keychain would not take. The server has already
    /// retired the old ones, so these are the only working copy.
    private var unstored: [String: Data] = [:]

    public init(session: URLSession = TokenRefresher.privateSession,
                endpoint: URL = TokenRefresher.defaultEndpoint,
                clientID: String = TokenRefresher.claudeCodeClientID,
                writer: KeychainWriting? = nil,
                reader: KeychainReading? = nil,
                servicePrefix: String = SlotStore.defaultLoginPrefix,
                keychainDeadline: TimeInterval = TokenRefresher.defaultKeychainDeadline,
                liveSlotName: @escaping @Sendable () -> String? = { nil },
                liveAccountEmail: @escaping @Sendable () -> String? = { nil }) {
        self.session = session
        self.endpoint = endpoint
        self.clientID = clientID
        self.writer = writer
        self.reader = reader
        self.servicePrefix = servicePrefix
        self.keychainDeadline = keychainDeadline
        self.liveSlotName = liveSlotName
        self.liveAccountEmail = liveAccountEmail
    }

    public static func stubbed(_ protocolClass: AnyClass, writer: KeychainWriting? = nil,
                               reader: KeychainReading? = nil,
                               servicePrefix: String = "CAS Test Login: ",
                               keychainDeadline: TimeInterval = TokenRefresher.defaultKeychainDeadline,
                               liveSlotName: @escaping @Sendable () -> String? = { nil },
                               liveAccountEmail: @escaping @Sendable () -> String? = { nil }) -> TokenRefresher {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [protocolClass]
        return TokenRefresher(session: URLSession(configuration: configuration),
                              writer: writer, reader: reader, servicePrefix: servicePrefix,
                              keychainDeadline: keychainDeadline,
                              liveSlotName: liveSlotName, liveAccountEmail: liveAccountEmail)
    }
}

// MARK: - One renewal at a time, per slot

extension TokenRefresher {
    /// Refreshes `slot` and stores the rotated tokens. A second caller joins the first call.
    public func refresh(slot: String, payload: CredentialPayload,
                        now: Date = Date()) async throws -> OAuthCredentials {
        try refuseLive(slot: slot, payload: payload)
        if let existing = inFlight[slot] { return try await existing.value }

        // The caller's payload still holds the refresh token the server has already
        // consumed; sending it again would end in invalid_grant. Store what we have.
        if let held = unstored[slot] {
            guard let kept = try? CredentialPayload.parse(held) else {
                // Never fall through to another rotation: the only working refresh
                // token for this slot is the one in here.
                throw RefreshError.writeBack(
                    "\"\(slot)\" is holding renewed tokens that cannot be rebuilt;"
                        + " sign in to that account again from the panel")
            }
            try await retryWriteBack(slot: slot)
            return kept.credentials
        }

        let task = Task<OAuthCredentials, Error> { [self] in
            try await perform(slot: slot, payload: payload, now: now)
        }
        inFlight[slot] = task
        defer { inFlight[slot] = nil }
        return try await task.value
    }

    /// True while a refresh for `slot` is on the wire.
    public func isRefreshing(_ slot: String) -> Bool { inFlight[slot] != nil }

    /// The live login is Claude Code's to renew: rotating it retires the token
    /// in `Claude Code-credentials` and logs the owner out of their own session.
    private func refuseLive(slot: String, payload: CredentialPayload?) throws {
        if let live = liveSlotName(), live == slot { throw RefreshError.refusedLiveSlot(slot) }
        if let live = liveAccountEmail(), !live.isEmpty,
           let mine = payload?.account?.emailAddress, !mine.isEmpty,
           live.caseInsensitiveCompare(mine) == .orderedSame {
            throw RefreshError.refusedLiveSlot(slot)
        }
    }

    private func perform(slot: String, payload: CredentialPayload, now: Date) async throws -> OAuthCredentials {
        guard writer != nil else {
            throw RefreshError.writeBack("no keychain writer, so a rotation could not be kept")
        }
        guard reader != nil else {
            throw RefreshError.writeBack("no keychain reader, so a rotation could not be checked")
        }
        let service = servicePrefix + slot

        // Re-read before sending anything. The caller's payload can be minutes
        // old: another renewal, a switch or `claude-acct` may have replaced the
        // refresh token in it, and sending a retired one reads as a dead account.
        let existing: Data?
        do {
            existing = try await readSlot(service: service)
        } catch {
            // Nothing has been sent yet, so nothing is lost by stopping here.
            throw RefreshError.slotChanged(
                "\"\(slot)\" could not be read from the keychain, so nothing was renewed: \(error)")
        }
        guard let storedData = existing else {
            throw RefreshError.slotChanged(
                "\"\(slot)\" is not in the keychain any more, so nothing was renewed")
        }
        let current = (try? CredentialPayload.parse(storedData)) ?? payload
        let before = Self.identity(of: current)
        try refuseLive(slot: slot, payload: current)

        // Somebody got there first, and its token is still good: a second
        // rotation would retire a working refresh token for nothing.
        if let expiry = current.credentials.expiry,
           expiry.timeIntervalSince(now) > Self.clockSkew,
           current.credentials.refreshToken?.isEmpty == false {
            return current.credentials
        }
        guard let refreshToken = current.credentials.refreshToken, !refreshToken.isEmpty else {
            throw RefreshError.noRefreshToken
        }
        if current.credentials.refreshTokenIsDead(now: now) {
            throw RefreshError.refreshTokenExpired
        }

        let json = try await exchange(refreshToken: refreshToken)
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw RefreshError.badResponse("no access_token in a 200")
        }
        var rotated = current.credentials
        rotated.accessToken = accessToken
        if let token = (json["refresh_token"] as? String).flatMap({ $0.isEmpty ? nil : $0 }) {
            rotated.refreshToken = token
        }
        if let expiresAt = OAuthLogin.expiresAt(json["expires_in"], now: now) {
            rotated.expiresAt = expiresAt
        }

        // From here the old refresh token is dead whatever happens next: every
        // path below either stores the new one or says plainly that it did not.
        let stillThere: Data?
        do {
            stillThere = try await readSlot(service: service)
        } catch {
            unstored[slot] = Self.payloadBytes(current: current, rotated: rotated)
            throw RefreshError.writeBack(
                "\"\(slot)\" could not be read after it was renewed (\(error)); the new tokens are"
                    + " held in memory only — use Retry save on its row before quitting")
        }
        guard let afterData = stillThere else {
            throw RefreshError.slotChanged(
                "\"\(slot)\" was removed while it was being renewed, so it was not written back —"
                    + " the account has to be signed in to again if it is wanted")
        }
        let after = (try? CredentialPayload.parse(afterData)).map { Self.identity(of: $0) }
        if let after, after != before {
            throw RefreshError.slotChanged(
                "\"\(slot)\" was replaced by another login while it was being renewed; the renewed"
                    + " tokens were dropped rather than written over it")
        }

        try await store(slot: slot, payload: current, rotated: rotated)

        if let live = liveSlotName(), live == slot {
            throw RefreshError.slotChanged(
                "\"\(slot)\" became the live login while it was being renewed. The slot holds the"
                    + " new tokens, but Claude Code may be holding the one this renewal retired —"
                    + " switch away and back, or sign in to it again.")
        }
        return rotated
    }

    private func exchange(refreshToken: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
        ])
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw RefreshError.transport((error as NSError).localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.badResponse("no HTTP response")
        }
        let body = String(data: data, encoding: .utf8) ?? ""
        guard http.statusCode == 200 else {
            if body.contains("invalid_grant") {
                throw RefreshError.needsRelogin("the refresh token was rejected (invalid_grant)")
            }
            throw RefreshError.http(http.statusCode, OAuthLogin.scrubbed(String(body.prefix(400))))
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RefreshError.badResponse("a 200 that is not a JSON object (\(data.count) bytes)")
        }
        return json
    }
}

// MARK: - Keeping what the server issued

extension TokenRefresher {
    /// Writes the rotated tokens back and reads them back to prove it. Two attempts,
    /// each verified by a read of its own; after that they are held in `unstored`
    /// for `retryWriteBack`, never discarded.
    private func store(slot: String, payload: CredentialPayload, rotated: OAuthCredentials) async throws {
        let data = Self.payloadBytes(current: payload, rotated: rotated)
        var last: Error?
        for _ in 0..<2 {
            if let error = await attemptStore(slot: slot, data: data, expected: rotated) {
                last = error
                // A write that timed out may still have landed behind the dialog.
                if await isStored(slot: slot, expected: rotated) {
                    unstored[slot] = nil
                    return
                }
            } else {
                unstored[slot] = nil
                return
            }
        }
        unstored[slot] = data
        let reason = last.map { "\($0)" } ?? "the keychain refused the write"
        throw RefreshError.writeBack(
            "\(reason) — the rotated tokens for \"\(slot)\" are held in memory only; use Retry"
                + " save on its row before quitting, or sign in to that account again from the panel")
    }

    /// The slot as it should now read. The old refresh token is already retired,
    /// so even a slot whose raw JSON will not rebuild gets a minimal payload
    /// rather than nothing.
    static func payloadBytes(current: CredentialPayload, rotated: OAuthCredentials) -> Data {
        (try? current.withRotatedTokens(accessToken: rotated.accessToken,
                                        refreshToken: rotated.refreshToken,
                                        expiresAt: rotated.expiresAt))
            ?? minimalPayload(rotated, account: current.accountJSON)
    }

    /// JSON built from values that cannot fail to encode: whatever else breaks,
    /// a rotation is never lost for want of a payload to put it in.
    static func minimalPayload(_ credentials: OAuthCredentials, account: Data?) -> Data {
        var oauth: [String: Any] = [
            "accessToken": credentials.accessToken, "scopes": credentials.scopes,
        ]
        if let token = credentials.refreshToken { oauth["refreshToken"] = token }
        if let expiresAt = credentials.expiresAt { oauth["expiresAt"] = expiresAt }
        if let dies = credentials.refreshTokenExpiresAt { oauth["refreshTokenExpiresAt"] = dies }
        if let tier = credentials.subscriptionType { oauth["subscriptionType"] = tier }
        if let tier = credentials.rateLimitTier { oauth["rateLimitTier"] = tier }
        let inner = (try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth],
                                                 options: [.sortedKeys]))
            ?? Data(#"{"claudeAiOauth":{}}"#.utf8)
        if let account, let whole = try? CredentialPayload.slotPayload(credentials: inner,
                                                                      account: account) {
            return whole
        }
        var out = Data(#"{"credentials":"#.utf8)
        out.append(inner)
        out.append(Data(#","oauthAccount":{}}"#.utf8))
        return out
    }

    /// nil when the write landed and read back as what was written.
    private func attemptStore(slot: String, data: Data, expected: OAuthCredentials) async -> Error? {
        guard let writer, let reader else { return RefreshError.writeBack("no keychain writer") }
        let service = servicePrefix + slot
        let label = "Claude Code login snapshot for \(slot)"
        do {
            try await BlockingKeychain.run(keychainDeadline, "storing \"\(service)\"") {
                try writer.write(data, service: service, label: label)
            }
            let readBack = try await BlockingKeychain.run(keychainDeadline,
                                                          "reading \"\(service)\" back") {
                try reader.data(forService: service)
            }
            let parsed = try CredentialPayload.parse(readBack).credentials
            guard parsed.accessToken == expected.accessToken,
                  parsed.refreshToken == expected.refreshToken else {
                return RefreshError.writeBack(
                    "\"\(service)\" came back as \(readBack.count) bytes that are not what was written")
            }
            return nil
        } catch {
            return error
        }
    }

    /// Whether the item already holds these tokens, whatever the write said.
    private func isStored(slot: String, expected: OAuthCredentials) async -> Bool {
        // try? covers both answers that mean "not what was written": no item, and
        // a keychain that would not say.
        guard let data = try? await readSlot(service: servicePrefix + slot),
              let parsed = try? CredentialPayload.parse(data) else { return false }
        return parsed.credentials.accessToken == expected.accessToken
            && parsed.credentials.refreshToken == expected.refreshToken
    }

    /// nil means there is no such item. Anything else the keychain says is
    /// thrown as it came, so the caller can say whether a rotation happened yet.
    private func readSlot(service: String) async throws -> Data? {
        guard let reader else { return nil }
        do {
            return try await BlockingKeychain.run(keychainDeadline, "reading \"\(service)\"") {
                try reader.data(forService: service)
            }
        } catch KeychainError.itemNotFound {
            return nil
        }
    }

    /// Who a slot belongs to, for telling "the same account, renewed" from "a
    /// different login has been put in this slot since".
    static func identity(of payload: CredentialPayload) -> String {
        let uuid = payload.account?.accountUuid ?? ""
        let email = payload.account?.emailAddress?.lowercased() ?? ""
        return "\(uuid)|\(email)"
    }

    /// True when a rotation happened and could not be stored; quitting would lose it.
    public func hasUnstoredTokens(for slot: String) -> Bool { unstored[slot] != nil }

    /// Every slot holding tokens the keychain has not taken, whether or not the
    /// panel still lists it: quitting now loses these.
    public func unstoredSlotNames() -> [String] { unstored.keys.sorted() }

    /// Drops held tokens for a slot the owner has removed on purpose.
    public func forget(slot: String) { unstored[slot] = nil }

    /// Tries the write again with the tokens already in hand. No network call:
    /// another rotation would retire the only working refresh token.
    public func retryWriteBack(slot: String) async throws {
        if let existing = writeBacks[slot] {
            try await existing.value
            return
        }
        guard unstored[slot] != nil else { return }
        let task = Task<Void, Error> { [self] in try await performWriteBack(slot: slot) }
        writeBacks[slot] = task
        defer { writeBacks[slot] = nil }
        try await task.value
    }

    private func performWriteBack(slot: String) async throws {
        guard let data = unstored[slot] else { return }
        let held: CredentialPayload
        do {
            held = try CredentialPayload.parse(data)
        } catch {
            throw RefreshError.writeBack("the held tokens for \"\(slot)\" cannot be rebuilt: \(error)")
        }
        // The slot may have been signed in to again while these were waiting;
        // writing them then would throw away the login that replaced them.
        if let current = try? await readSlot(service: servicePrefix + slot),
           let parsed = try? CredentialPayload.parse(current),
           Self.identity(of: parsed) != Self.identity(of: held) {
            unstored[slot] = nil
            throw RefreshError.slotChanged(
                "\"\(slot)\" holds a different account now, so the tokens renewed earlier were"
                    + " dropped instead of being written over it")
        }
        if let error = await attemptStore(slot: slot, data: data, expected: held.credentials) {
            guard await isStored(slot: slot, expected: held.credentials) else {
                if let refresh = error as? RefreshError { throw refresh }
                throw RefreshError.writeBack("\(error)")
            }
        }
        unstored[slot] = nil
    }
}
