import Foundation

/// A login this app obtained itself, on its way into a named slot.
///
/// `accountJSON` is the profile kept as bytes: a switch splices it straight
/// into `~/.claude.json`, so nothing is re-encoded or invented on the way.
public struct MintedLogin: Equatable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    /// Milliseconds since the epoch, as Claude Code stores them.
    public var expiresAt: Double?
    public var scopes: [String]
    public var subscriptionType: String?
    public var rateLimitTier: String?
    public var account: OAuthAccount?
    public var accountJSON: Data?
    /// Things the panel must say before the owner stores this: a response with
    /// no refresh token, a profile naming a different account, a missing scope.
    public var warnings: [String] = []

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Double? = nil,
                scopes: [String] = [], subscriptionType: String? = nil,
                rateLimitTier: String? = nil,
                account: OAuthAccount? = nil, accountJSON: Data? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scopes = scopes
        self.subscriptionType = subscriptionType
        self.rateLimitTier = rateLimitTier
        self.account = account
        self.accountJSON = accountJSON
    }

    public var email: String? { account?.emailAddress }

    /// A login with no refresh token dies in a few hours and cannot be renewed;
    /// it is never stored, so the panel has to say so before the button is used.
    public var lacksRefreshToken: Bool { refreshToken?.isEmpty != false }

    /// The `{claudeAiOauth: …}` value of a slot: exactly the keys the live item
    /// carries, since a switch copies it into `Claude Code-credentials` unchanged.
    public func credentialsJSON() throws -> Data {
        var oauth: [String: Any] = ["accessToken": accessToken, "scopes": scopes]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        if let subscriptionType { oauth["subscriptionType"] = subscriptionType }
        if let rateLimitTier { oauth["rateLimitTier"] = rateLimitTier }
        return try JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth],
                                          options: [.sortedKeys])
    }

    /// The whole slot payload, in the shape `capture` writes.
    public func slotPayload() throws -> Data {
        try CredentialPayload.slotPayload(credentials: try credentialsJSON(), account: accountJSON)
    }
}

extension MintedLogin: CustomStringConvertible {
    /// Never the tokens: this is what an interpolation or a log would print.
    public var description: String {
        "MintedLogin(\(Redact.email(email)), access \(Redact.token(accessToken)), "
            + "refresh \(Redact.token(refreshToken)))"
    }
}

public enum LoginSlotError: Error, Equatable, CustomStringConvertible {
    case badName(String)
    /// The name holds a slot that parses; it is never overwritten unasked.
    case nameTaken(String, email: String?)
    /// The keychain would not say what is under that name, so nothing is written.
    case cannotCheckName(String, why: String)
    case noRefreshToken
    /// The live slot has to go on mirroring `Claude Code-credentials`.
    case liveSlot(String)
    case write(String)

    public var description: String {
        switch self {
        case .badName(let name):
            return "\"\(name)\" is not a usable slot name (letters, digits, . _ -)"
        case .nameTaken(let name, let email):
            return "\"\(name)\" already holds a working login\(email.map { " for \($0)" } ?? "")"
                + " — choose another name, or replace it on purpose"
        case .cannotCheckName(let name, let why):
            return "what is stored under \"\(name)\" could not be read (\(why)), so nothing was"
                + " written — it may hold a working login"
        case .noRefreshToken:
            return "the login came back with no refresh token, so it would stop working in a few hours"
        case .liveSlot(let name):
            return "\"\(name)\" is the live login: storing another account there would leave Claude"
                + " Code running on one account and the slot naming another"
        case .write(let why): return why
        }
    }
}

/// Runs a blocking keychain call with a deadline.
///
/// `security` answers in milliseconds, unless macOS has put a permission dialog
/// in front of it — and then it waits for as long as the dialog is unanswered.
/// Without a deadline a sign-in hangs in "storing…" with nothing on screen,
/// which is what the owner saw when a login "couldn't log".
enum BlockingKeychain {
    struct TimedOut: Error, CustomStringConvertible {
        let what: String
        let seconds: TimeInterval

        var description: String {
            "\(what) got no answer in \(Int(seconds)) s — macOS is probably showing a keychain"
                + " permission dialog behind the app. Answer it (Always Allow), then try again."
        }
    }

    private final class Box<T>: @unchecked Sendable {
        var result: Result<T, Error>?
        let lock = NSLock()
        /// Whichever of the two finishes first answers, exactly once.
        func claim() -> Bool { lock.withLock { let first = !claimed; claimed = true; return first } }
        private var claimed = false
    }

    /// For callers that are already off the main thread and have nothing to await.
    static func sync<T: Sendable>(_ seconds: TimeInterval, _ what: String,
                                  _ body: @escaping @Sendable () throws -> T) throws -> T {
        let box = Box<T>()
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let value = Result { try body() }
            box.lock.withLock { box.result = value }
            done.signal()
        }
        guard done.wait(timeout: .now() + seconds) == .success,
              let result = box.lock.withLock({ box.result }) else {
            throw TimedOut(what: what, seconds: seconds)
        }
        return try result.get()
    }

    /// The same, for an actor: the keychain call runs on a Dispatch thread, so a
    /// dialog cannot freeze the actor and every renewal behind it.
    static func run<T: Sendable>(_ seconds: TimeInterval, _ what: String,
                                 _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let box = Box<T>()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = Result { try body() }
                if box.claim() { continuation.resume(with: result) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if box.claim() {
                    continuation.resume(throwing: TimedOut(what: what, seconds: seconds))
                }
            }
        }
    }
}

/// Writes a minted login into one named slot and nothing else: never the live
/// item (its writer cannot reach it), never `~/.claude.json`, never the
/// active-login marker. Adding an account does not change which one is in use.
public struct LoginSlotWriter: Sendable {
    /// Long enough for a slow keychain, short enough that a dialog nobody
    /// answers becomes a sentence on screen rather than a frozen panel.
    public static let defaultDeadline: TimeInterval = 20

    let reader: KeychainReading
    let writer: KeychainWriting
    let loginPrefix: String
    let deadline: TimeInterval
    /// The slot Claude Code is using now, when the caller can say; a sign-in
    /// into it is refused here as well as in the panel.
    let liveSlotName: @Sendable () -> String?

    public init(reader: KeychainReading = SystemKeychainReader(),
                writer: KeychainWriting? = nil,
                loginPrefix: String = SlotStore.defaultLoginPrefix,
                deadline: TimeInterval = LoginSlotWriter.defaultDeadline,
                liveSlotName: @escaping @Sendable () -> String? = { nil }) {
        self.reader = reader
        self.writer = writer ?? SystemKeychainWriter(servicePrefix: loginPrefix)
        self.loginPrefix = loginPrefix
        self.deadline = deadline
        self.liveSlotName = liveSlotName
    }

    /// Wired to one store, so the live slot is known without the caller saying so.
    public init(store: SlotStore, deadline: TimeInterval = LoginSlotWriter.defaultDeadline) {
        self.init(reader: store.reader,
                  writer: SystemKeychainWriter(servicePrefix: store.loginPrefix),
                  loginPrefix: store.loginPrefix,
                  deadline: deadline,
                  liveSlotName: { store.activeSlotName() })
    }

    /// What the keychain says is under that name.
    public enum Stored: Equatable {
        case nothing
        /// There is an item, but nothing this app can parse: replacing it is the repair.
        case corrupt
        case readable(email: String?)
        /// The keychain would not answer, so what is in there is unknown.
        case unreadable(String)
    }

    public func stored(_ name: String) -> Stored {
        let reader = self.reader
        let service = loginPrefix + name
        do {
            let data = try BlockingKeychain.sync(deadline, "reading \"\(service)\"") {
                try reader.data(forService: service)
            }
            guard let payload = try? CredentialPayload.parse(data) else { return .corrupt }
            return .readable(email: payload.account?.emailAddress)
        } catch KeychainError.itemNotFound {
            return .nothing
        } catch {
            return .unreadable("\(error)")
        }
    }

    /// What is stored under that name, if anything readable is.
    public func existing(_ name: String) -> CredentialPayload? {
        let reader = self.reader
        let service = loginPrefix + name
        guard let data = try? BlockingKeychain.sync(deadline, "reading \"\(service)\"", {
            try reader.data(forService: service)
        }) else { return nil }
        return try? CredentialPayload.parse(data)
    }

    /// Stores the login. `replacing` must be true to write over a slot that
    /// parses; a corrupt one is replaceable without asking.
    @discardableResult
    public func store(_ login: MintedLogin, as name: String,
                      replacing: Bool = false) throws -> Int {
        guard Switcher.isValidName(name) else { throw LoginSlotError.badName(name) }
        if let live = liveSlotName(), live == name { throw LoginSlotError.liveSlot(name) }
        guard !login.lacksRefreshToken else { throw LoginSlotError.noRefreshToken }
        if !replacing {
            switch stored(name) {
            case .readable(let email): throw LoginSlotError.nameTaken(name, email: email)
            // A read that failed is not an empty slot: overwriting on the
            // strength of an error is how a working account would be lost.
            case .unreadable(let why): throw LoginSlotError.cannotCheckName(name, why: why)
            case .nothing, .corrupt: break
            }
        }

        let payload = try login.slotPayload()
        let service = loginPrefix + name
        let writer = self.writer
        let reader = self.reader
        do {
            try BlockingKeychain.sync(deadline, "storing \"\(service)\"") {
                try writer.write(payload, service: service,
                                 label: "Claude Code login snapshot for \(name)")
            }
        } catch let timeout as BlockingKeychain.TimedOut {
            throw LoginSlotError.write(timeout.description)
        }

        // Read back and compare: a keychain that stores a truncated value is how one slot already died.
        let readBack: Data
        do {
            readBack = try BlockingKeychain.sync(deadline, "reading \"\(service)\" back") {
                try reader.data(forService: service)
            }
        } catch {
            throw LoginSlotError.write("wrote \"\(service)\" but cannot read it back: \(error)")
        }
        guard Self.matches(readBack, payload) else {
            throw LoginSlotError.write(
                "\"\(service)\" came back as \(readBack.count) bytes that are not what was written")
        }
        return payload.count
    }

    /// Byte for byte, not "the access token looks right": a payload that came
    /// back short of its refresh token would pass any lighter comparison, and a
    /// slot with no refresh token is an account that dies in a few hours.
    /// `security` prints a trailing newline, which the reader already trims.
    static func matches(_ readBack: Data, _ written: Data) -> Bool {
        func trimmed(_ data: Data) -> Data {
            var bytes = data
            while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
            return bytes
        }
        guard trimmed(readBack) == trimmed(written) else { return false }
        guard let parsed = try? CredentialPayload.parse(readBack) else { return false }
        return !parsed.credentials.accessToken.isEmpty
            && parsed.credentials.refreshToken?.isEmpty == false
    }
}
