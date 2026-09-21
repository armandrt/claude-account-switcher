import Foundation

public struct PolicyDecision: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case stay
        case switchTo(String)
    }

    public var action: Action
    /// The whole sentence.
    public var reason: String
    /// Two or three words for the log line: "session limit".
    public var cause: String

    public init(action: Action, reason: String, cause: String = "") {
        self.action = action
        self.reason = reason
        self.cause = cause
    }

    public var target: String? {
        if case .switchTo(let name) = action { return name }
        return nil
    }

    public static func stay(_ reason: String, cause: String = "") -> PolicyDecision {
        PolicyDecision(action: .stay, reason: reason, cause: cause)
    }

    public static func move(to name: String, _ reason: String, cause: String = "") -> PolicyDecision {
        PolicyDecision(action: .switchTo(name), reason: reason, cause: cause)
    }
}

/// Pure: same inputs, same answer, no clock of its own and no I/O.
public struct PolicyEngine: Sendable {
    public let config: PolicyConfig

    public init(config: PolicyConfig = PolicyConfig()) {
        self.config = config
    }

    public func evaluate(mode: SwitchMode, accounts: [PolicyAccount], active: String?,
                         now: Date, lastSwitchAt: Date? = nil) -> PolicyDecision {
        guard mode != .manual else {
            return .stay("manual mode: nothing switches on its own", cause: "manual")
        }
        guard !accounts.isEmpty else { return .stay("no accounts", cause: "no accounts") }

        let activeAccount = accounts.first { $0.name == active }
        let candidates = accounts.filter { $0.name != active && $0.isEligible(config) }
        let best = bestCandidate(candidates, now: now)

        // Stuck right now: the minimum interval does not apply.
        if let activeAccount, activeAccount.isStuck {
            guard let best else {
                return .stay("\(activeAccount.name) is out of quota and no other account is eligible",
                             cause: "nowhere to go")
            }
            return .move(to: best.name, "\(activeAccount.name) \(stuckReason(activeAccount)), \(best.name) has \(weeklyLeft(best))",
                         cause: shortCause(activeAccount))
        }
        guard let activeAccount else {
            guard let best else { return .stay("no active account and none eligible", cause: "nowhere to go") }
            return .move(to: best.name, "no active account; \(best.name) has the most quota at risk",
                         cause: "no active account")
        }
        guard mode == .balance else {
            return .stay("\(activeAccount.name) can still run", cause: "still running")
        }
        return balance(activeAccount, best: best, now: now, lastSwitchAt: lastSwitchAt)
    }

    func balance(_ activeAccount: PolicyAccount, best: PolicyAccount?,
                 now: Date, lastSwitchAt: Date?) -> PolicyDecision {
        guard let best else { return .stay("no other account is eligible", cause: "nowhere to go") }
        // Balance is an optimisation. With a weekly number missing on either side it
        // would be rewriting credentials on a default value, so it waits for a real
        // reading; Failover still covers an account that cannot continue at all.
        guard best.hasWeeklyReading else {
            return .stay("nothing has been read for \(best.name) yet, so there is nothing to balance against",
                         cause: "no reading")
        }
        let activeCanClaimWork = activeAccount.isEligible(config)
        guard activeAccount.hasWeeklyReading || !activeCanClaimWork else {
            return .stay("nothing has been read for \(activeAccount.name) yet, so there is nothing to compare",
                         cause: "no reading")
        }
        // `abs`, so a stamp from a clock that has since moved back cannot hold
        // Balance still for as long as the clock is wrong.
        if let lastSwitchAt, abs(now.timeIntervalSince(lastSwitchAt)) < config.minimumInterval {
            let wait = Int((config.minimumInterval - max(0, now.timeIntervalSince(lastSwitchAt))) / 60) + 1
            return .stay("switched less than \(Int(config.minimumInterval / 60)) min ago (\(wait) min to go)",
                         cause: "too soon")
        }
        // An active account that is no longer eligible has no claim on new work.
        let activeUrgency = activeCanClaimWork ? activeAccount.urgency(now: now) : 0
        let bestUrgency = best.urgency(now: now)
        guard bestUrgency > activeUrgency * (1 + config.hysteresis) else {
            return .stay("\(activeAccount.name) at \(rate(activeUrgency)) still beats \(best.name) at \(rate(bestUrgency)) within \(Int(config.hysteresis * 100))%",
                         cause: "hysteresis")
        }
        return .move(to: best.name,
                     "\(best.name) burns \(rate(bestUrgency)) against \(activeAccount.name) at \(rate(activeUrgency))",
                     cause: "balance")
    }

    /// Highest urgency wins, but an account nobody has read never outranks one that
    /// has been measured, however flattering its defaults look. The listed order
    /// breaks what is left, so a drag decides a tie.
    func bestCandidate(_ candidates: [PolicyAccount], now: Date) -> PolicyAccount? {
        candidates.max { left, right in
            if left.hasWeeklyReading != right.hasWeeklyReading { return !left.hasWeeklyReading }
            let a = left.urgency(now: now), b = right.urgency(now: now)
            if a == b { return left.order > right.order }
            return a < b
        }
    }

    func stuckReason(_ account: PolicyAccount) -> String {
        if !account.isUsable { return "cannot log in" }
        if (account.sessionPercent ?? 0) >= 100 { return "hit its session limit" }
        if (account.weeklyPercent ?? 0) >= 100 { return "hit its weekly limit" }
        if account.blockedForModelInUse { return "hit the limit for the model in use" }
        return "cannot continue"
    }

    func shortCause(_ account: PolicyAccount) -> String {
        if !account.isUsable { return "credentials" }
        if (account.sessionPercent ?? 0) >= 100 { return "session limit" }
        if (account.weeklyPercent ?? 0) >= 100 { return "weekly limit" }
        if account.blockedForModelInUse { return "model limit" }
        return "blocked"
    }

    /// Never prints a percentage for an account that has none: the defaults behind
    /// `weeklyRemaining` would read as a measurement in the log and the notification.
    func weeklyLeft(_ account: PolicyAccount) -> String {
        account.hasWeeklyReading
            ? "\(Int(account.weeklyRemaining.rounded()))% weekly left"
            : "no weekly reading yet"
    }
    func rate(_ value: Double) -> String { String(format: "%.2f %%/h", value) }
}
