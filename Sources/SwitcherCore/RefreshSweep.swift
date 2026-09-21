import Foundation

/// What one account gets during a "Refresh all", decided before any request goes out.
public enum SweepAction: Equatable, Sendable {
    /// Access token expired, refresh token alive: renew, then read the quota.
    case renew
    case read
    /// Nothing this button can do, and why, in the words the report uses.
    case skip(String)

    public var isSkip: Bool { if case .skip = self { return true }; return false }

    /// Requests this step makes if nothing goes wrong; the panel counts them out loud.
    public var requests: Int {
        switch self {
        case .renew: return 2
        case .read: return 1
        case .skip: return 0
        }
    }
}

public struct SweepStep: Equatable, Sendable, Identifiable {
    public var name: String
    public var action: SweepAction
    public var id: String { name }

    public init(name: String, action: SweepAction) {
        self.name = name
        self.action = action
    }
}

/// Works out what "Refresh all" will do to each slot. Every refusal here saves a
/// request from the shared allowance, which is the scarce thing.
public enum SweepPlanner {
    /// How new a reading has to be for the sweep to leave that account alone.
    /// The active account is polled about this often anyway, so re-reading it
    /// spends a request and a 30 s wait on a number already on screen.
    public static let freshEnough: TimeInterval = 150

    /// Stalest first, and anything read moments ago is left alone.
    /// `readAt` gives the age of each account's reading, by name.
    public static func plan(slots: [Slot], readAt: [String: Date] = [:],
                            now: Date = Date()) -> [SweepStep] {
        // A rename that failed after its copy leaves two slots under one name
        // (PLAN §4.2). Two steps with one name would spend two of the allowance's
        // requests on one account and hand the list two rows with the same id.
        var seen: Set<String> = []
        let unique = slots.filter { seen.insert($0.name).inserted }
        // Stalest first. `sorted` is not stable, so equal readings are separated by
        // the order the accounts arrived in — the owner's dragged order — rather
        // than by whatever introsort does with equal keys: with a 429 ending the
        // sweep at any step, which account goes first is the whole outcome.
        let ordered = unique.enumerated().sorted { left, right in
            let a = readAt[left.element.name] ?? .distantPast
            let b = readAt[right.element.name] ?? .distantPast
            return a == b ? left.offset < right.offset : a < b
        }.map(\.element)
        return ordered.map { slot in
            SweepStep(name: slot.name,
                      action: action(for: slot, readAt: readAt[slot.name], now: now))
        }
    }

    public static func action(for slot: Slot, readAt: Date? = nil,
                              now: Date = Date()) -> SweepAction {
        if slot.health == .ok, let readAt, now.timeIntervalSince(readAt) < freshEnough {
            return .skip("its numbers are less than \(Int(freshEnough / 60)) minutes old")
        }
        return uncachedAction(for: slot, now: now)
    }

    private static func uncachedAction(for slot: Slot, now: Date) -> SweepAction {
        switch slot.health {
        case .corrupt:
            return .skip("the stored login is corrupt, so there is nothing to renew — it needs a new login")
        case .unreadable(let why):
            return .skip("its keychain item could not be read: \(why)")
        case .needsRelogin:
            return .skip("its refresh token is dead — only a new login fixes that")
        case .ok, .expired:
            break
        }
        guard let credentials = slot.credentials else {
            return .skip("nothing readable is stored for it")
        }
        guard credentials.canReadUsage else {
            // A setup-token slot: renewing it would work and the quota read would still 403.
            return .skip("its token has no user:profile scope, so its quota cannot be read")
        }
        if slot.health == .expired {
            guard !slot.isActive else {
                return .skip("it is the live login, and Claude Code renews that one")
            }
            return .renew
        }
        return .read
    }
}

/// One account's fate once the sweep has been through it.
public struct SweepOutcome: Equatable, Sendable, Identifiable {
    public enum Result: Equatable, Sendable {
        case renewed
        case alreadyFine
        /// Renewed, but the rotated tokens are in memory only; "Retry save" is the way out.
        case renewedNotStored(String)
        case skipped(String)
        case failed(String)
        /// The sweep stopped before reaching it.
        case notReached
    }

    public var name: String
    public var result: Result
    public var id: String { name }

    public init(name: String, result: Result) {
        self.name = name
        self.result = result
    }
}

/// What the sweep did: what was renewed, what was already fine, what failed and why.
public struct SweepReport: Equatable, Sendable {
    public var outcomes: [SweepOutcome]
    /// Set when the sweep gave up early: a 429, or the Stop button.
    public var stopped: String?

    public init(outcomes: [SweepOutcome], stopped: String? = nil) {
        self.outcomes = outcomes
        self.stopped = stopped
    }

    public func names(_ match: (SweepOutcome.Result) -> Bool) -> [String] {
        outcomes.filter { match($0.result) }.map(\.name)
    }

    public var renewed: [String] {
        names {
            if case .renewed = $0 { return true }
            if case .renewedNotStored = $0 { return true }
            return false
        }
    }
    public var alreadyFine: [String] { names { $0 == .alreadyFine } }

    /// Everything that did not end well, each with its reason. A skip and a
    /// failure read alike here: either way the account still has no numbers.
    public var problems: [(name: String, why: String)] {
        outcomes.compactMap { outcome in
            switch outcome.result {
            case .skipped(let why), .failed(let why), .renewedNotStored(let why):
                return (outcome.name, why)
            case .notReached:
                return (outcome.name, "the sweep stopped before reaching it")
            case .renewed, .alreadyFine:
                return nil
            }
        }
    }

    public var headline: String {
        var parts: [String] = []
        if !renewed.isEmpty { parts.append("\(renewed.count) renewed") }
        if !alreadyFine.isEmpty { parts.append("\(alreadyFine.count) already fine") }
        if !problems.isEmpty { parts.append("\(problems.count) left as \(problems.count == 1 ? "it was" : "they were")") }
        let summary = parts.isEmpty ? "nothing to do" : parts.joined(separator: " · ")
        guard let stopped else { return summary }
        return "stopped: \(stopped) — \(summary)"
    }

    /// One line per account that still has a problem; successes are only counted.
    public var lines: [String] { problems.map { "\($0.name) — \($0.why)" } }
}

/// Background renewal of accounts whose access token has run out, so no account
/// ever goes dark. Always on; the interval is a throttle against a renewal storm,
/// not a schedule — a renewal happens only when a token has actually expired.
public enum AutoRenew {
    /// At most one renewal this often.
    public static let interval: TimeInterval = 300

    /// The one slot worth renewing right now, or nil: the access token that
    /// expired longest ago wins.
    public static func due(slots: [Slot], lastRenewAt: Date?, now: Date = Date()) -> String? {
        // `abs`: a stamp from the future is a clock that moved, and an opt-in that
        // can never come due again is a feature silently switched off.
        if let lastRenewAt, abs(now.timeIntervalSince(lastRenewAt)) < interval { return nil }
        let candidates = slots.filter { slot in
            !slot.isActive && SweepPlanner.action(for: slot, now: now) == .renew
        }
        return candidates.min { left, right in
            (left.credentials?.expiry ?? .distantPast) < (right.credentials?.expiry ?? .distantPast)
        }?.name
    }
}
