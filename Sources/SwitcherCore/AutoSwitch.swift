import Foundation

/// How often the app may switch on its own, and how many failed switches stop it.
public struct AutoSwitchLimits: Equatable, Sendable {
    public var maxPerWindow: Int
    public var window: TimeInterval
    public var failuresBeforeStop: Int

    public init(maxPerWindow: Int = 4, window: TimeInterval = 3600, failuresBeforeStop: Int = 2) {
        self.maxPerWindow = maxPerWindow
        self.window = window
        self.failuresBeforeStop = failuresBeforeStop
    }
}

/// What the app is doing when the policy speaks.  Any of these blocks an automatic switch.
public struct AutoSwitchConditions: Equatable, Sendable {
    public var isSweeping: Bool
    public var isBusy: Bool
    public var isConfirming: Bool

    public init(isSweeping: Bool = false, isBusy: Bool = false, isConfirming: Bool = false) {
        self.isSweeping = isSweeping
        self.isBusy = isBusy
        self.isConfirming = isConfirming
    }

    var blocker: String? {
        if isSweeping { return "Refresh all is running" }
        if isBusy { return "another action is running" }
        if isConfirming { return "a panel is waiting for an answer" }
        return nil
    }
}

/// What the app has already done by itself: the switches inside the cap's window,
/// and the run of failures that turns automatic switching off.
public struct AutoSwitchState: Equatable, Sendable {
    public var limits: AutoSwitchLimits
    public private(set) var switches: [Date] = []
    public private(set) var consecutiveFailures = 0
    /// Set once failures stopped it; only re-arming clears it.
    public private(set) var isStopped = false

    public init(limits: AutoSwitchLimits = AutoSwitchLimits()) {
        self.limits = limits
    }

    public func count(now: Date) -> Int {
        switches.filter { now.timeIntervalSince($0) < limits.window }.count
    }

    public func isCapped(now: Date) -> Bool { count(now: now) >= limits.maxPerWindow }

    /// Counted when the switch starts, so one that fails still uses up its turn.
    public mutating func recordSwitch(at date: Date) {
        switches.append(date)
        switches.removeAll { date.timeIntervalSince($0) >= limits.window }
    }

    public mutating func recordSuccess() { consecutiveFailures = 0 }

    /// True when this failure is the one that stops automatic switching.
    @discardableResult
    public mutating func recordFailure() -> Bool {
        consecutiveFailures += 1
        guard !isStopped, consecutiveFailures >= limits.failuresBeforeStop else { return false }
        isStopped = true
        return true
    }

    /// Choosing a mode again is deliberate, so it clears what the failures left behind.
    public mutating func rearm() {
        consecutiveFailures = 0
        isStopped = false
    }
}

/// The only path from a policy decision to a real switch.  Pure: it is told the
/// time, what the app is doing and what it has already done, and answers once.
public struct AutoSwitchGate: Sendable {
    public enum Refusal: Equatable, Sendable {
        case manual
        case stopped
        case staying
        case busy(String)
        case tooSoon(TimeInterval)
        case capped(Int)
        case notSwitchable(String)

        public var text: String {
            switch self {
            case .manual: return "Manual mode switches nothing on its own"
            case .stopped: return "automatic switching is off after failed switches"
            case .staying: return "nothing to switch to"
            case .busy(let what): return what
            case .tooSoon(let left):
                return "another switch is allowed in \(max(1, Int((left / 60).rounded(.up)))) min"
            case .capped(let count):
                return "\(count) automatic switches in the last hour is the cap"
            case .notSwitchable(let name): return "\(name) cannot take over right now"
            }
        }
    }

    public enum Verdict: Equatable, Sendable {
        case act(String)
        case hold(Refusal)

        public var target: String? {
            if case .act(let name) = self { return name }
            return nil
        }
    }

    public let config: PolicyConfig

    public init(config: PolicyConfig = PolicyConfig()) {
        self.config = config
    }

    /// The cool-off applies to every switch, the owner's clicks included: two
    /// credential rewrites close together is the failure mode worth fearing here.
    ///
    /// It has exactly one exception, and it is PLAN §4.3's own: "at most once every
    /// 15 min, **unless the current account can't continue**". Waiting out a
    /// cool-off on an account that is already refusing every request buys nothing —
    /// a session limit lasts hours and a weekly one days, so there is no flapping to
    /// damp, only fifteen minutes of a Claude Code that does not work. The churn the
    /// cool-off exists to bound is still bounded: the four-an-hour cap, the busy
    /// conditions, the stop-after-failures latch and the re-check of the target all
    /// apply to a blocked account exactly as they do to any other.
    public func verdict(for decision: PolicyDecision, mode: SwitchMode, accounts: [PolicyAccount],
                        active: String?, conditions: AutoSwitchConditions, state: AutoSwitchState,
                        now: Date, lastSwitchAt: Date?) -> Verdict {
        guard mode != .manual else { return .hold(.manual) }
        guard !state.isStopped else { return .hold(.stopped) }
        guard let target = decision.target else { return .hold(.staying) }
        if let blocker = conditions.blocker { return .hold(.busy(blocker)) }
        if let lastSwitchAt, !activeCannotContinue(accounts: accounts, active: active) {
            let since = now.timeIntervalSince(lastSwitchAt)
            // A stamp far in the future is a clock that moved, not a recent switch;
            // honouring it would turn automatic switching off until it caught up.
            if abs(since) < config.minimumInterval {
                return .hold(.tooSoon(config.minimumInterval - max(0, since)))
            }
        }
        if state.isCapped(now: now) { return .hold(.capped(state.count(now: now))) }
        guard let account = accounts.first(where: { $0.name == target }),
              account.name != active,
              account.isUsable,
              !account.isStuck,
              account.isEligible(config)
        else { return .hold(.notSwitchable(target)) }
        return .act(target)
    }

    /// The exception above, read from the numbers rather than from the decision's
    /// prose. An `active` that names nothing in the list is not evidence that the
    /// account in use is blocked, so it keeps the cool-off; no active account at all
    /// is no work to protect, so it does not.
    func activeCannotContinue(accounts: [PolicyAccount], active: String?) -> Bool {
        guard let active else { return true }
        guard let account = accounts.first(where: { $0.name == active }) else { return false }
        return account.isStuck
    }
}
