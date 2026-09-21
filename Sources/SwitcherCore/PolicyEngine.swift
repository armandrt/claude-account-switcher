import Foundation

public enum SwitchMode: String, CaseIterable, Sendable {
    case manual, failover, balance

    public var title: String {
        switch self {
        case .manual: return "Manual"
        case .failover: return "Failover"
        case .balance: return "Balance"
        }
    }

    /// Plain text next to the picker; nothing to accept.
    public var sideNote: String? {
        self == .manual
            ? nil
            : "Automatic rotation between accounts might break Anthropic's Terms of Service."
    }
}

public struct PolicyConfig: Equatable, Sendable {
    /// Percentages of quota left.
    public var minSessionRemaining: Double = 5
    public var minWeeklyRemaining: Double = 2
    /// The best account has to beat the current one by more than this fraction.
    public var hysteresis: Double = 0.25
    /// No two switches closer together than this, unless the active one is stuck.
    public var minimumInterval: TimeInterval = 15 * 60

    public init(minSessionRemaining: Double = 5, minWeeklyRemaining: Double = 2,
                hysteresis: Double = 0.25, minimumInterval: TimeInterval = 15 * 60) {
        self.minSessionRemaining = minSessionRemaining
        self.minWeeklyRemaining = minWeeklyRemaining
        self.hysteresis = hysteresis
        self.minimumInterval = minimumInterval
    }
}

/// One account as the policy sees it.  No I/O, no clock of its own.
public struct PolicyAccount: Equatable, Sendable {
    public var name: String
    /// Tie-breaker: the order the accounts are listed in.
    public var order: Int
    /// Percentages USED, as the endpoint reports them.
    public var sessionPercent: Double?
    public var weeklyPercent: Double?
    public var weeklyResetsAt: Date?
    /// A model-scoped weekly limit at 100% for the model in use.
    public var blockedForModelInUse: Bool
    public var isUsable: Bool

    public init(name: String, order: Int = 0, sessionPercent: Double? = nil,
                weeklyPercent: Double? = nil, weeklyResetsAt: Date? = nil,
                blockedForModelInUse: Bool = false, isUsable: Bool = true) {
        self.name = name
        self.order = order
        self.sessionPercent = sessionPercent
        self.weeklyPercent = weeklyPercent
        self.weeklyResetsAt = weeklyResetsAt
        self.blockedForModelInUse = blockedForModelInUse
        self.isUsable = isUsable
    }

    /// Quota left, clamped: a percentage outside 0-100 reached the policy once and
    /// "105% left" is the kind of number that sends work to an empty account.
    /// An unread window counts as full, so that Failover can still fall back to a
    /// slot nobody has read; `hasWeeklyReading` is what stops Balance preferring it
    /// to an account we have actually measured.
    public var sessionRemaining: Double { Self.remaining(sessionPercent) }
    public var weeklyRemaining: Double { Self.remaining(weeklyPercent) }

    static func remaining(_ percentUsed: Double?) -> Double {
        guard let percentUsed, percentUsed.isFinite else { return 100 }
        return min(100, max(0, 100 - percentUsed))
    }

    /// The water-filling arithmetic is weekly; with no weekly number, urgency is a
    /// default wearing the clothes of a measurement.
    public var hasWeeklyReading: Bool { weeklyPercent != nil }
    /// Nothing at all has been read for this account.
    public var hasReading: Bool { sessionPercent != nil || weeklyPercent != nil }

    public func hoursUntilWeeklyReset(now: Date) -> Double? {
        guard let weeklyResetsAt else { return nil }
        let hours = weeklyResetsAt.timeIntervalSince(now) / 3600
        return hours.isFinite && hours > 0 ? hours : nil
    }

    /// The horizon used when the endpoint gave no reset time, or gave one that has
    /// already passed. A weekly window is seven days, and a window that just rolled
    /// over has the whole seven ahead of it: that is the *least* urgent state there
    /// is, so falling back to "the whole remainder, right now" — a number ten to a
    /// hundred times any real rate — inverted the choice every time.
    public static let unknownResetHorizonHours: Double = 168
    /// Below this a switch cannot land before the window rolls anyway, so the
    /// division stops here instead of running off towards infinity.
    public static let minimumHorizonHours: Double = 0.25

    /// Weekly quota left per hour until it resets, in %/h, always finite.
    public func urgency(now: Date) -> Double {
        let hours = max(Self.minimumHorizonHours,
                        hoursUntilWeeklyReset(now: now) ?? Self.unknownResetHorizonHours)
        return weeklyRemaining / hours
    }

    /// Nothing more can run here right now.
    public var isStuck: Bool {
        !isUsable || (sessionPercent ?? 0) >= 100 || (weeklyPercent ?? 0) >= 100 || blockedForModelInUse
    }

    public func isEligible(_ config: PolicyConfig) -> Bool {
        isUsable
            && !blockedForModelInUse
            && sessionRemaining >= config.minSessionRemaining
            && weeklyRemaining >= config.minWeeklyRemaining
    }
}
