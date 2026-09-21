import Foundation
import Testing
@testable import SwitcherApp
import SwitcherCore

/// Fakes for the app target's tests.  Nothing here reaches the real keychain,
/// the network, `~/.claude.json`, `~/.config` or the owner's defaults: a world
/// is a temporary directory, an in-memory keychain, a dictionary of preferences
/// and a `URLProtocol` that answers from a table.
///
/// Every world puts its own UUID in the URLs it arms, so suites run in parallel
/// without one test's reply landing in another's session.

// MARK: - The network

/// Canned replies keyed by URL path; an unarmed path answers 599.
final class AppStub: URLProtocol {
    struct Reply: @unchecked Sendable {
        var status: Int = 200
        var body: Data = Data()
        /// Held open so a test can stop a sweep while a request is in flight.
        var delay: TimeInterval = 0
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: Reply] = [:]
        var calls: [String: [Data]] = [:]
    }

    private static let state = State()

    static func arm(_ reply: Reply, for url: URL) {
        state.lock.withLock {
            state.replies[url.path] = reply
            state.calls[url.path] = []
        }
    }

    static func arm(json: String, status: Int = 200, delay: TimeInterval = 0, for url: URL) {
        arm(Reply(status: status, body: Data(json.utf8), delay: delay), for: url)
    }

    /// The bodies sent to that URL, in order; the count is the request count.
    static func calls(for url: URL) -> [Data] {
        state.lock.withLock { state.calls[url.path] ?? [] }
    }

    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AppStub.self]
        return URLSession(configuration: configuration)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while true {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let sent = Self.body(of: request)
        let reply = Self.state.lock.withLock { () -> Reply in
            Self.state.calls[path, default: []].append(sent)
            return Self.state.replies[path] ?? Reply(status: 599)
        }
        let finish = { [weak self] in
            guard let self else { return }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: finish)
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}

// MARK: - The keychain

/// An in-memory keychain with injectable faults, locked because the model reads
/// slots from a detached task.
struct FakeKeychain: KeychainReading, KeychainWriting {
    final class Box: @unchecked Sendable {
        let lock = NSLock()
        var items: [String: Data] = [:]
        var readFailures: [String: KeychainError] = [:]
        var writeFailures: [String: KeychainError] = [:]
        /// Accepts the write and stores something else: the failure that killed a real slot.
        var truncateWrites: Set<String> = []
        var writes: [String] = []
        var deletes: [String] = []
    }
    let box = Box()

    func services(withPrefix prefix: String) throws -> [String] {
        box.lock.withLock { () -> [String] in
            box.items.keys.filter { $0.hasPrefix(prefix) }.sorted()
        }
    }

    func data(forService service: String) throws -> Data {
        try box.lock.withLock { () -> Data in
            if let failure = box.readFailures[service] { throw failure }
            guard let data = box.items[service] else { throw KeychainError.itemNotFound(service) }
            return data
        }
    }

    func write(_ data: Data, service: String, label: String) throws {
        try box.lock.withLock { () -> Void in
            if let failure = box.writeFailures[service] { throw failure }
            box.writes.append(service)
            box.items[service] = box.truncateWrites.contains(service) ? Data(data.prefix(20)) : data
        }
    }

    func delete(service: String) throws {
        box.lock.withLock { () -> Void in
            box.deletes.append(service)
            box.items[service] = nil
        }
    }

    func item(_ service: String) -> Data? {
        box.lock.withLock { () -> Data? in box.items[service] }
    }

    var writeCount: Int { box.lock.withLock { () -> Int in box.writes.count } }
}

// MARK: - The defaults

/// What `UserDefaults` is to the app, a dictionary is here: a test neither reads
/// nor writes the owner's real defaults.
final class FakePreferences: Preferences {
    var values: [String: Any] = [:]

    func bool(forKey defaultName: String) -> Bool { values[defaultName] as? Bool ?? false }
    func data(forKey defaultName: String) -> Data? { values[defaultName] as? Data }
    func stringArray(forKey defaultName: String) -> [String]? { values[defaultName] as? [String] }
    func object(forKey defaultName: String) -> Any? { values[defaultName] }

    func set(_ value: Any?, forKey defaultName: String) {
        if let value {
            values[defaultName] = value
        } else {
            values.removeValue(forKey: defaultName)
        }
    }
}

// MARK: - A whole app in a temporary directory

@MainActor
final class AppWorld {
    static let prefix = "CAS Test Login: "
    static let liveService = "CAS Test Live"

    let id: String
    let directory: URL
    let keychain: FakeKeychain
    let preferences: FakePreferences
    let model: AppModel
    /// Kept so `relaunch()` can build a second model over the same world.
    let store: SlotStore
    let switcher: Switcher
    let usageCache: UsageCache
    let stubSession: URLSession
    let usageURL: URL
    let refreshTokenURL: URL
    let loginTokenURL: URL
    let profileURL: URL
    let authorizeURL: URL
    let manualRedirectURL: URL
    /// Every URL the app asked to open, instead of a browser.
    var opened: [URL] = []

    /// The config and the marker live one level down, so a test can take away
    /// the right to create a file next to them without touching the lock.
    var homeURL: URL { directory.appendingPathComponent("home") }
    var configURL: URL { homeURL.appendingPathComponent(".claude.json") }
    var markerURL: URL { homeURL.appendingPathComponent("active-login") }

    /// A slot payload in the shape `capture` writes.
    static func slot(access: String, email: String, expiresIn: TimeInterval = 3600,
                     refreshIn: TimeInterval = 86_400,
                     scopes: [String] = ["user:profile", "user:inference"],
                     now: Date = Date()) -> Data {
        let expires = (now.timeIntervalSince1970 + expiresIn) * 1000
        let refreshExpires = (now.timeIntervalSince1970 + refreshIn) * 1000
        let scopeList = scopes.map { "\"\($0)\"" }.joined(separator: ",")
        return Data("""
        {"credentials":{"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"refresh-\(access)",
          "expiresAt":\(expires),"refreshTokenExpiresAt":\(refreshExpires),
          "scopes":[\(scopeList)],"subscriptionType":"max"}},
         "oauthAccount":{"emailAddress":"\(email)","organizationRateLimitTier":"default_claude_max_20x",
          "accountUuid":"0000-\(access)"}}
        """.utf8)
    }

    static func liveItem(access: String, expiresIn: TimeInterval = 3600, now: Date = Date()) -> Data {
        let expires = (now.timeIntervalSince1970 + expiresIn) * 1000
        let refreshExpires = (now.timeIntervalSince1970 + 86_400) * 1000
        return Data("""
        {"claudeAiOauth":{"accessToken":"\(access)","refreshToken":"rotated-\(access)",
          "expiresAt":\(expires),"refreshTokenExpiresAt":\(refreshExpires),
          "scopes":["user:profile","user:inference"],"subscriptionType":"max"}}
        """.utf8)
    }

    static func config(email: String = "live@example.com") -> Data {
        Data("""
        {
          "numStartups": 8,
          "installMethod": "native",
          "oauthAccount": {
            "emailAddress": "\(email)",
            "organizationRateLimitTier": "default_claude_max_20x",
            "accountUuid": "0000-live"
          },
          "mcpServers": {"ssim": {"command": "/usr/bin/env", "args": ["x"]}},
          "autoCompactWindowsCache": 0.5
        }
        """.utf8)
    }

    /// The everyday world: `perso2` is live, `pro` is a healthy inactive slot.
    static func defaultItems(now: Date = Date()) -> [String: Data] {
        [prefix + "perso2": slot(access: "stale-perso2", email: "live@example.com", now: now),
         prefix + "pro": slot(access: "pro-access", email: "pro@example.com", now: now),
         liveService: liveItem(access: "live-access", now: now)]
    }

    init(items: [String: Data]? = nil, active: String? = "perso2",
         config: Data? = nil, cache: [String: UsageSnapshot] = [:]) throws {
        let id = UUID().uuidString
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-app-\(id)")
        let home = directory.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let configURL = home.appendingPathComponent(".claude.json")
        let markerURL = home.appendingPathComponent("active-login")
        try (config ?? Self.config()).write(to: configURL)
        if let active {
            try Data((active + "\n").utf8).write(to: markerURL)
        }

        let keychain = FakeKeychain()
        keychain.box.items = items ?? Self.defaultItems()
        let preferences = FakePreferences()

        let usageURL = URL(string: "https://stub.test/\(id)/usage")!
        let refreshTokenURL = URL(string: "https://stub.test/\(id)/refresh")!
        let loginTokenURL = URL(string: "https://stub.test/\(id)/login-token")!
        let profileURL = URL(string: "https://stub.test/\(id)/profile")!
        let authorizeURL = URL(string: "https://stub.test/\(id)/authorize")!
        let manualRedirectURL = URL(string: "https://stub.test/\(id)/manual")!

        let store = SlotStore(reader: keychain, loginPrefix: Self.prefix,
                              liveService: Self.liveService, activeLoginURL: markerURL)
        let switcher = Switcher(
            reader: keychain, writer: keychain, loginPrefix: Self.prefix,
            liveService: Self.liveService,
            paths: Switcher.Paths(config: configURL, activeLogin: markerURL,
                                  lock: directory.appendingPathComponent("switch.lock")))
        let usageCache = UsageCache(directory: directory)
        if !cache.isEmpty { try usageCache.save(cache) }

        let session = AppStub.session()
        let refresher = TokenRefresher(session: session, endpoint: refreshTokenURL,
                                       writer: keychain, reader: keychain,
                                       servicePrefix: Self.prefix,
                                       liveSlotName: { store.activeSlotName() })
        let model = AppModel(store: store, usage: UsageClient(session: session, endpoint: usageURL),
                             cache: usageCache, switcher: switcher, refresher: refresher,
                             preferences: preferences)

        self.id = id
        self.directory = directory
        self.keychain = keychain
        self.preferences = preferences
        self.store = store
        self.switcher = switcher
        self.usageCache = usageCache
        self.stubSession = session
        self.usageURL = usageURL
        self.refreshTokenURL = refreshTokenURL
        self.loginTokenURL = loginTokenURL
        self.profileURL = profileURL
        self.authorizeURL = authorizeURL
        self.manualRedirectURL = manualRedirectURL
        self.model = model

        model.loginWriter = keychain
        model.oauth = OAuthLogin(endpoints: endpoints, session: session)
        model.openURL = { [weak self] url in self?.opened.append(url) }
        // No floor and no backoff: the waits are what the app does to the
        // endpoint, not what a test should sit through.  Tests that care about
        // the allowance set their own.
        model.budget = RateLimitBudget(base: 60, cap: 120, jitterFraction: 0, minimumSpacing: 0)
    }

    /// The same world seen by a freshly launched app: new model, new allowance,
    /// same keychain, same preferences, same files.
    func relaunch() -> AppModel {
        let store = self.store
        let refresher = TokenRefresher(session: stubSession, endpoint: refreshTokenURL,
                                       writer: keychain, reader: keychain,
                                       servicePrefix: Self.prefix,
                                       liveSlotName: { store.activeSlotName() })
        let model = AppModel(store: store,
                             usage: UsageClient(session: stubSession, endpoint: usageURL),
                             cache: usageCache, switcher: switcher, refresher: refresher,
                             preferences: preferences)
        model.loginWriter = keychain
        model.oauth = OAuthLogin(endpoints: endpoints, session: stubSession)
        return model
    }

    var endpoints: OAuthLogin.Endpoints {
        OAuthLogin.Endpoints(clientID: "test-client", authorizeURL: authorizeURL,
                             tokenURL: loginTokenURL, profileURL: profileURL,
                             manualRedirect: manualRedirectURL,
                             scopes: OAuthLogin.Endpoints.claudeCodeScopes)
    }

    /// A 200 from the usage endpoint: percentages USED.
    func armUsage(session: Double = 20, weekly: Double = 40, delay: TimeInterval = 0) {
        AppStub.arm(json: """
        {"limits":[{"kind":"session","percent":\(session),"severity":"normal"},
                   {"kind":"weekly_all","percent":\(weekly),"severity":"normal"}]}
        """, delay: delay, for: usageURL)
    }

    func armRateLimited() {
        AppStub.arm(json: #"{"error":{"type":"rate_limit_error"}}"#, status: 429, for: usageURL)
    }

    /// A 200 from the refresh grant, rotating both tokens.
    func armRefresh(access: String = "renewed-access", refresh: String = "renewed-refresh") {
        AppStub.arm(json: """
        {"access_token":"\(access)","refresh_token":"\(refresh)","expires_in":3600}
        """, for: refreshTokenURL)
    }

    func marker() -> String? {
        try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func configEmail() -> String? {
        guard let data = try? Data(contentsOf: configURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = json["oauthAccount"] as? [String: Any] else { return nil }
        return account["emailAddress"] as? String
    }

    func backups() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: homeURL.path)) ?? []
        return names.filter { $0.hasPrefix(".claude.json.bak.") }
    }

    func liveAccessToken() -> String? {
        guard let data = keychain.item(Self.liveService) else { return nil }
        return try? CredentialPayload.parse(data, liveShape: true).credentials.accessToken
    }

    func storedAccessToken(_ name: String) -> String? {
        guard let data = keychain.item(Self.prefix + name) else { return nil }
        return try? CredentialPayload.parse(data).credentials.accessToken
    }

    func logText() -> String {
        model.log.entries.map(\.text).joined(separator: " | ")
    }

    /// Nothing is left holding the model: every one of these is a state the app
    /// gets stuck in if an outcome forgets to clear it.
    func expectNothingStuck() async {
        // A background renewal may hold a row for a moment; stuck means it never lets go.
        #expect(await settle { model.busySlot == nil }, "busySlot is still held")
        #expect(model.switchingTo == nil, "a row is still marked as switching")
        #expect(model.sweepTask == nil, "a sweep is still running")
        #expect(model.sweepLine == nil, "the footer still shows a sweep")
        #expect(model.login == nil, "a sign-in is still open")
        #expect(model.pendingSwitch == nil, "a dry run is still on screen")
    }

    func cleanUp() {
        model.stop()
        // A test that made a directory read-only has to give it back first.
        for path in [directory.path, homeURL.path] {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        }
        try? FileManager.default.removeItem(at: directory)
    }
}

// MARK: - Waiting

/// Runs the main actor's queued work until `condition` holds.  Everything the
/// model does off the main actor comes back to it, so this is how a test waits
/// for a switch, a sweep or a sign-in without a sleep of its own.
@MainActor
func settle(within seconds: Double = 5, _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
    return condition()
}

/// One usage reading, for the on-disk cache.
func snapshot(session: Double = 20, weekly: Double = 40, fetchedAt: Date) -> UsageSnapshot {
    UsageSnapshot(limits: [UsageLimit(kind: .session, percent: session, severity: .normal),
                           UsageLimit(kind: .weeklyAll, percent: weekly, severity: .normal)],
                  fetchedAt: fetchedAt)
}
