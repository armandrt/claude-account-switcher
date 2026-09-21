import Foundation

/// One shared allowance for every call the app makes to the usage endpoint.
///
/// Exponential backoff with jitter after a 429, and a hard floor between any two
/// requests whichever account they are for: the cadence belongs to the whole app.
public struct RateLimitBudget: Equatable, Sendable {
    /// First backoff after a 429; doubles per consecutive 429 up to `cap`.
    public var base: TimeInterval
    public var cap: TimeInterval
    /// Up to this fraction is added on top, so several clients never line up.
    public var jitterFraction: Double
    public var minimumSpacing: TimeInterval

    public private(set) var strikes = 0
    public private(set) var openUntil: Date?
    public private(set) var lastRequestAt: Date?

    public init(base: TimeInterval = 120, cap: TimeInterval = 900,
                jitterFraction: Double = 0.2, minimumSpacing: TimeInterval = 30) {
        self.base = base
        self.cap = cap
        self.jitterFraction = jitterFraction
        self.minimumSpacing = minimumSpacing
    }

    /// The longest this budget may ever hold a request back: the top of the ladder
    /// plus its jitter. Everything it stores is clamped to it, so neither a wild
    /// `Retry-After` nor a clock that jumped can park the app for good. Truncating
    /// a long hint costs at most one extra 429, because the ladder sends one
    /// request and then backs off again — a single request, never a burst.
    public var maximumWait: TimeInterval {
        Swift.max(0, minimumSpacing, cap * (1 + Swift.max(0, jitterFraction)))
    }

    public func allows(_ now: Date) -> Bool { waitTime(now: now) <= 0 }

    /// Seconds until the next request may go out.
    public func waitTime(now: Date) -> TimeInterval {
        var wait: TimeInterval = 0
        for deadline in [openUntil, lastRequestAt?.addingTimeInterval(minimumSpacing)] {
            guard let deadline else { continue }
            let left = deadline.timeIntervalSince(now)
            // A deadline further ahead than any wait this budget could have set was
            // written against a clock that has since moved backwards. Honouring it
            // would park the app until the clock caught up; ignoring it costs one
            // request, whose answer re-arms the ladder against the clock we have.
            guard left.isFinite, left <= maximumWait else { continue }
            wait = Swift.max(wait, left)
        }
        return Swift.max(0, wait)
    }

    /// Only ever moves forward, so an older stamp cannot reopen the floor — unless
    /// the stored one sits further ahead than any wait this budget could produce,
    /// which means it came from a clock that has since been corrected.
    public mutating func recordRequest(at now: Date) {
        guard let last = lastRequestAt else { lastRequestAt = now; return }
        lastRequestAt = last.timeIntervalSince(now) > maximumWait ? now : Swift.max(last, now)
    }

    public mutating func recordSuccess() {
        strikes = 0
        openUntil = nil
    }

    /// `jitter` is 0…1; tests pass a fixed value, the app a random one.
    /// A `Retry-After` of zero or less is treated as absent: this endpoint sends 0.
    @discardableResult
    public mutating func recordRateLimit(retryAfter: TimeInterval?, now: Date,
                                         jitter: Double = Double.random(in: 0..<1)) -> Date {
        strikes += 1
        let exponential = min(cap, base * pow(2, Double(min(strikes - 1, 32))))
        let jittered = exponential * (1 + max(0, min(1, jitter)) * max(0, jitterFraction))
        var hinted: TimeInterval = 0
        if let retryAfter, retryAfter.isFinite { hinted = max(0, retryAfter) }
        let ceiling = now.addingTimeInterval(maximumWait)
        let until = now.addingTimeInterval(min(maximumWait, max(hinted, jittered)))
        // Never shortens a wait already running, and never outruns the ceiling.
        let effective = min(max(until, openUntil ?? until), ceiling)
        openUntil = effective
        return effective
    }
}

// MARK: - Persistence

extension RateLimitBudget {
    /// The part worth keeping across a relaunch; the tunables stay in code.
    public struct State: Codable, Equatable, Sendable {
        public var strikes: Int
        public var openUntil: Date?
        public var lastRequestAt: Date?

        public init(strikes: Int, openUntil: Date?, lastRequestAt: Date?) {
            self.strikes = strikes
            self.openUntil = openUntil
            self.lastRequestAt = lastRequestAt
        }
    }

    public var state: State {
        State(strikes: strikes, openUntil: openUntil, lastRequestAt: lastRequestAt)
    }

    /// Restores a saved state. Dates further ahead than this budget could ever
    /// produce are clamped, so a wrong clock cannot lock the app out for good.
    public mutating func restore(_ state: State, now: Date) {
        strikes = max(0, state.strikes)
        let longest = now.addingTimeInterval(maximumWait)
        openUntil = state.openUntil.map { min($0, longest) }
        lastRequestAt = state.lastRequestAt.map { min($0, now) }
    }
}
