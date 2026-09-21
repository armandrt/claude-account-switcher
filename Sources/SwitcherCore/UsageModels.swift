import Foundation

public enum LimitKind: Equatable, Hashable, Sendable {
    case session
    case weeklyAll
    case weeklyScoped
    /// Anything the endpoint grows later; shown as-is, never fatal.
    case unknown(String)

    public init(raw: String) {
        switch raw {
        case "session": self = .session
        case "weekly_all": self = .weeklyAll
        case "weekly_scoped": self = .weeklyScoped
        default: self = .unknown(raw)
        }
    }

    public var raw: String {
        switch self {
        case .session: return "session"
        case .weeklyAll: return "weekly_all"
        case .weeklyScoped: return "weekly_scoped"
        case .unknown(let value): return value
        }
    }

    /// A scoped limit blocks one model; the others block everything.
    public var blocksEverything: Bool {
        switch self {
        case .session, .weeklyAll: return true
        case .weeklyScoped, .unknown: return false
        }
    }
}

public enum Severity: String, Comparable, Sendable {
    case normal, warning, critical, unknown

    public init(raw: String?) {
        guard let raw else { self = .unknown; return }
        self = Severity(rawValue: raw) ?? .unknown
    }

    var rank: Int {
        switch self {
        case .normal: return 0
        case .unknown: return 1
        case .warning: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rank < rhs.rank }
}

public struct UsageLimit: Identifiable, Equatable, Codable, Sendable {
    public var kind: LimitKind
    public var group: String?
    public var percent: Double?
    public var severity: Severity
    public var resetsAt: Date?
    public var modelDisplayName: String?
    public var surface: String?
    public var isActive: Bool

    public var id: String { "\(kind.raw)|\(group ?? "")|\(modelDisplayName ?? "")" }

    public init(kind: LimitKind, group: String? = nil, percent: Double? = nil,
                severity: Severity = .unknown, resetsAt: Date? = nil,
                modelDisplayName: String? = nil, surface: String? = nil, isActive: Bool = false) {
        self.kind = kind
        self.group = group
        self.percent = percent
        self.severity = severity
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
        self.surface = surface
        self.isActive = isActive
    }

    public var title: String {
        switch kind {
        case .session: return "Session"
        case .weeklyAll: return "Weekly"
        case .weeklyScoped: return "Weekly · \(modelDisplayName ?? "scoped")"
        case .unknown(let raw): return modelDisplayName.map { "\(raw) · \($0)" } ?? raw
        }
    }

    /// Quota left. Clamped, because a percentage outside 0-100 is the endpoint
    /// changing meaning under us, and "105% left" would flatter an empty account.
    public var remaining: Double? { percent.map { min(100, max(0, 100 - $0)) } }

    /// True once the window this limit measures has rolled over.
    public func hasReset(by now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// How long a rolled-over window may still be reported as empty.
    ///
    /// At `resets_at` the window really is empty, and that is knowledge, not a
    /// guess. It decays: every minute after the reset is a minute of work we
    /// never saw. Inside the grace the app is still asking (2 min cadence, and
    /// the longest planned backoff is 15 min plus jitter), so little can have
    /// happened unseen; past it we have simply lost touch, and "unknown" is the
    /// honest answer rather than "full".
    public static let rolloverGrace: TimeInterval = 1800

    /// The reading as it stands at `now`.
    ///
    /// A window that has passed its reset is empty again, whatever the last
    /// call said: the quota came back on a schedule the server already told us.
    /// Keeping the old figure would show 4% left on a window that is full, so
    /// arithmetic beats a stale number here — but only while the arithmetic is
    /// still worth anything (see `rolloverGrace`). A reading from days ago whose
    /// reset has long passed becomes "unknown", never 0: making a limit look
    /// better than it is, is the direction that rewrites credentials.
    public func asOf(_ now: Date) -> UsageLimit {
        guard let resetsAt, resetsAt <= now else { return self }
        var rolled = self
        rolled.resetsAt = nil
        if now.timeIntervalSince(resetsAt) <= Self.rolloverGrace {
            rolled.percent = 0
            rolled.severity = .normal
        } else {
            rolled.percent = nil
            rolled.severity = .unknown
        }
        return rolled
    }
}

public struct LegacyWindow: Equatable, Codable, Sendable {
    public var utilization: Double?
    public var resetsAt: Date?

    public func hasReset(by now: Date) -> Bool {
        guard let resetsAt else { return false }
        return resetsAt <= now
    }

    /// The same rule as `UsageLimit.asOf`, including its grace: a legacy window
    /// whose reset passed long ago is unknown, not empty.
    public func asOf(_ now: Date) -> LegacyWindow {
        guard let resetsAt, resetsAt <= now else { return self }
        let fresh = now.timeIntervalSince(resetsAt) <= UsageLimit.rolloverGrace
        return LegacyWindow(utilization: fresh ? 0 : nil, resetsAt: nil)
    }
}

// MARK: - Codable

/// Stored as the wire string, so an unknown kind survives the cache unchanged.
extension LimitKind: Codable {
    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

extension Severity: Codable {
    public init(from decoder: Decoder) throws {
        self.init(raw: try decoder.singleValueContainer().decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
