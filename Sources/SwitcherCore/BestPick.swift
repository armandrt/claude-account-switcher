import Foundation

/// The account to use right now.
///
/// Any account that can still run is a candidate — 97% used is still usable, and
/// what is left is meant to be spent, not saved. Among them the one whose weekly
/// window resets soonest comes first: whatever it has left is lost at that reset,
/// so it is milked before the others. A used-up model-scoped limit changes nothing
/// here: the other models still run there, and the row's own bar says which is out.
public enum BestPick {
    public struct Pick: Equatable, Sendable {
        public var name: String
        /// When the week that decided it resets; nil when the endpoint gave none.
        public var weeklyResetsAt: Date?
    }

    public static func choose(_ accounts: [PolicyAccount], now: Date) -> Pick? {
        let open = accounts.filter(\.isOpen)
        guard let best = open.min(by: { sooner($0, $1, now: now) }) else { return nil }
        return Pick(name: best.name, weeklyResetsAt: best.weeklyResetsAt)
    }

    /// Soonest weekly reset first; a reset the endpoint did not give is treated as a
    /// whole week away. Then the one with less left, so it is finished rather than
    /// left with a remainder; then the listed order, so a drag decides a tie.
    static func sooner(_ a: PolicyAccount, _ b: PolicyAccount, now: Date) -> Bool {
        let ra = a.hoursUntilWeeklyReset(now: now) ?? PolicyAccount.unknownResetHorizonHours
        let rb = b.hoursUntilWeeklyReset(now: now) ?? PolicyAccount.unknownResetHorizonHours
        if ra != rb { return ra < rb }
        if a.weeklyRemaining != b.weeklyRemaining { return a.weeklyRemaining < b.weeklyRemaining }
        return a.order < b.order
    }
}

extension PolicyAccount {
    /// Work can run here now: the credentials are good, something has been read,
    /// and neither window that stops everything is used up.
    public var isOpen: Bool {
        isUsable && hasReading && (sessionPercent ?? 0) < 100 && (weeklyPercent ?? 0) < 100
    }
}
