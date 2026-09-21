import Foundation

/// Enumerates the accounts `claude-acct` stores.  Read-only, no migration.
public struct SlotStore: Sendable {
    public static let defaultLoginPrefix = "Claude Code Login: "
    public static let defaultLiveService = "Claude Code-credentials"
    public static var defaultActiveLoginURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".config/claude-accounts/active-login")
    }

    /// Rewrites one item's partition list and hands back its bytes, or nil if it could not.
    public typealias AccessRepair = @Sendable (_ service: String) -> Data?

    public let reader: KeychainReading
    public let loginPrefix: String
    public let liveService: String
    public let activeLoginURL: URL
    let repair: AccessRepair?

    public init(reader: KeychainReading = SystemKeychainReader(),
                loginPrefix: String = SlotStore.defaultLoginPrefix,
                liveService: String = SlotStore.defaultLiveService,
                activeLoginURL: URL = SlotStore.defaultActiveLoginURL,
                repair: AccessRepair? = nil) {
        self.reader = reader
        self.loginPrefix = loginPrefix
        self.liveService = liveService
        self.activeLoginURL = activeLoginURL
        // The repair rewrites the real keychain, so it has no business running behind an
        // injected reader: the test suite must never reach a real item.
        if let repair {
            self.repair = repair
        } else if reader is SystemKeychainReader {
            self.repair = { service in
                SlotStore.repairAccess(service: service, prefix: loginPrefix)
            }
        } else {
            self.repair = nil
        }
    }

    /// The name the active-login marker holds, or nil if it is missing.
    public func activeSlotName() -> String? {
        guard let text = try? String(contentsOf: activeLoginURL, encoding: .utf8) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    public func slotNames() throws -> [String] {
        try reader.services(withPrefix: loginPrefix).map { String($0.dropFirst(loginPrefix.count)) }
    }

    /// The credentials Claude Code is using right now.  Never refreshed by this app.
    public func liveCredentials() -> Result<CredentialPayload, Error> {
        Result {
            let data = try reader.data(forService: liveService)
            return try CredentialPayload.parse(data, liveShape: true)
        }
    }

    public static func health(for credentials: OAuthCredentials, now: Date = Date()) -> CredentialHealth {
        if credentials.refreshTokenIsDead(now: now) { return .needsRelogin }
        if credentials.isExpired(now: now) { return .expired }
        return .ok
    }
}

extension SlotStore {
    /// Every slot, with the active one's numbers taken from the live item.  A payload that
    /// will not parse becomes a `corrupt` slot, never a crash.
    public func slots(now: Date = Date()) -> [Slot] {
        let active = activeSlotName()
        let names = (try? slotNames()) ?? []
        let live = liveCredentials()

        return names.sorted().map { name in
            let isActive = (name == active)
            if isActive, case .success(let livePayload) = live {
                var slot = slot(named: name, isActive: true, now: now)
                slot.credentials = livePayload.credentials
                slot.usesLiveCredentials = true
                slot.health = Self.health(for: livePayload.credentials, now: now)
                if slot.account == nil { slot.account = livePayload.account }
                return slot
            }
            return slot(named: name, isActive: isActive, now: now)
        }
    }

    func slot(named name: String, isActive: Bool, now: Date) -> Slot {
        let service = loginPrefix + name
        let data: Data
        do {
            data = try reader.data(forService: service)
            settleAfterPrompt(service: service, name: name, data: data)
        } catch {
            if Self.isWorthRepairing(error), let repaired = repair?(service) {
                return slot(named: name, isActive: isActive, now: now, data: repaired)
            }
            return Slot(name: name, isActive: isActive,
                        health: .unreadable("\(error)"), byteCount: 0)
        }
        return slot(named: name, isActive: isActive, now: now, data: data)
    }

    /// Only an item `security` ran and was refused is worth rewriting.  A missing item has
    /// nothing to repair, and a `security` that would not start would fail the rewrite too —
    /// after the delete that makes room for it.
    static func isWorthRepairing(_ error: Error) -> Bool {
        guard case .cliFailed(let code, _)? = error as? KeychainError else { return false }
        return code > 0 && code != 44
    }

    /// At most one attempt per item per launch: the framework read inside `repairAccess` is
    /// the one call that can raise a keychain dialog, and without this a repair that cannot
    /// finish raised it again on every poll.
    private final class RepairMemo: @unchecked Sendable {
        private let lock = NSLock()
        private var tried: Set<String> = []
        func claim(_ service: String) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return tried.insert(service).inserted
        }
    }
    private static let repairMemo = RepairMemo()
    private static let settleMemo = RepairMemo()

    /// A read that macOS put a dialog in front of, and that the owner then approved, leaves the
    /// item exactly as it was: its partition list still names a cdhash instead of `apple-tool:`,
    /// so the next tool to touch it — Claude Code shells out to `security` on every launch —
    /// is asked the same question again.  The bytes are in hand at this point, so the item is
    /// written again through `security` right here, which replaces the list for good.  One
    /// answer, once, and the item never asks anything again.
    ///
    /// Only for the real keychain, and once per item per launch: behind an injected reader
    /// there is nothing to settle, and an item that will not take the rewrite must not be
    /// rewritten on every poll.
    func settleAfterPrompt(service: String, name: String, data: Data) {
        guard reader is SystemKeychainReader, KeychainAudit.didPrompt(service) else { return }
        guard Self.settleMemo.claim(service) else { return }
        let account = NSUserName()
        let writer = SystemKeychainWriter(servicePrefix: loginPrefix, account: account)
        do {
            try writer.normaliseAccess(service: service, data: data,
                                       label: "Claude Code login snapshot for \(name)")
            KeychainAudit.clearPrompt(service)
            KeychainAudit.record("settled", service: service,
                                 outcome: "rewritten by security — its partition list is apple-tool: now")
        } catch {
            KeychainAudit.record("settle-failed", service: service, outcome: "\(error)")
        }
    }

    /// An item an earlier build created with `SecItemAdd` carries a partition list naming that
    /// build's cdhash, so `security` is refused or questioned on it and every poll asked for a
    /// password. If this app can still read it itself, it is written back through `security`
    /// once, which replaces the list with `apple-tool:`, and it behaves afterwards. Returns the
    /// bytes when the repair worked, nil when it did not — a slot that says "unreadable" is
    /// better than one that pretends bytes are stored.
    static func repairAccess(service: String, prefix: String) -> Data? {
        guard repairMemo.claim(service) else { return nil }
        let account = NSUserName()
        guard let data = SystemKeychainWriter.readOwnItem(service: service, account: account) else {
            return nil
        }
        let writer = SystemKeychainWriter(servicePrefix: prefix, account: account)
        let name = String(service.dropFirst(prefix.count))
        guard (try? writer.normaliseAccess(service: service, data: data,
                                           label: "Claude Code login snapshot for \(name)")) != nil
        else { return nil }
        return (try? SystemKeychainReader(account: account).data(forService: service)) ?? data
    }

    private func slot(named name: String, isActive: Bool, now: Date, data: Data) -> Slot {
        do {
            let payload = try CredentialPayload.parse(data)
            return Slot(name: name, isActive: isActive,
                        health: Self.health(for: payload.credentials, now: now),
                        credentials: payload.credentials, account: payload.account,
                        payload: payload, byteCount: data.count)
        } catch let error as CredentialPayload.ParseError {
            return Slot(name: name, isActive: isActive,
                        health: .corrupt(error.description), byteCount: data.count)
        } catch {
            return Slot(name: name, isActive: isActive,
                        health: .corrupt("\(error)"), byteCount: data.count)
        }
    }
}
