import Foundation

/// One reading of `/api/oauth/usage`. `limits[]` is the source of truth;
/// `five_hour` / `seven_day` are the fallback for the day it changes shape.
public struct UsageSnapshot: Equatable, Codable, Sendable {
    public var limits: [UsageLimit]
    public var fiveHour: LegacyWindow?
    public var sevenDay: LegacyWindow?
    public var fetchedAt: Date
    /// Anything unexpected that was kept rather than dropped, for the UI to show.
    public var notes: [String]

    public init(limits: [UsageLimit], fiveHour: LegacyWindow? = nil, sevenDay: LegacyWindow? = nil,
                fetchedAt: Date = Date(), notes: [String] = []) {
        self.limits = limits
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.fetchedAt = fetchedAt
        self.notes = notes
    }

    /// The worst entry of that kind. A response that repeats a window (or a cache
    /// written before the decoder merged them) must not be read by whichever copy
    /// happened to come first: that is a coin toss between two numbers, and the
    /// rosier one is the one that costs quota.
    public func limit(_ kind: LimitKind) -> UsageLimit? {
        let matching = limits.filter { $0.kind == kind }
        guard matching.count > 1 else { return matching.first }
        return matching.max { ($0.percent ?? -1) < ($1.percent ?? -1) }
    }

    /// This reading brought up to `now`: every window whose reset has passed is
    /// counted as empty again. Nothing here contacts the network — the reset
    /// times came with the reading, so the arithmetic is already known.
    public func asOf(_ now: Date) -> UsageSnapshot {
        guard limits.contains(where: { $0.hasReset(by: now) })
                || (fiveHour?.hasReset(by: now) ?? false)
                || (sevenDay?.hasReset(by: now) ?? false) else { return self }
        var rolled = self
        rolled.limits = limits.map { $0.asOf(now) }
        rolled.fiveHour = fiveHour?.asOf(now)
        rolled.sevenDay = sevenDay?.asOf(now)
        return rolled
    }

    public var sessionPercent: Double? { limit(.session)?.percent ?? fiveHour?.utilization }
    public var weeklyPercent: Double? { limit(.weeklyAll)?.percent ?? sevenDay?.utilization }
    public var weeklyResetsAt: Date? { limit(.weeklyAll)?.resetsAt ?? sevenDay?.resetsAt }
    public var sessionResetsAt: Date? { limit(.session)?.resetsAt ?? fiveHour?.resetsAt }
    public var scopedLimits: [UsageLimit] { limits.filter { !$0.kind.blocksEverything } }

    /// The tightest limit that stops *all* work; a model-scoped 100% colours the
    /// icon but does not set its number.
    public var tightest: UsageLimit? {
        limits.filter { $0.kind.blocksEverything && $0.percent != nil }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
    }

    public var severity: Severity {
        limits.map(\.severity).max() ?? .unknown
    }

    public var isBlocked: Bool {
        limits.contains { $0.kind.blocksEverything && ($0.percent ?? 0) >= 100 }
    }
}

public enum UsageError: Error, Equatable, CustomStringConvertible {
    case unauthorized
    case scopeInsufficient
    /// Carries `Retry-After` when the endpoint gave a usable one.
    case rateLimited(TimeInterval?)
    case http(Int, String)
    case shapeChanged(String)
    case transport(String)

    public var description: String {
        switch self {
        case .unauthorized: return "token rejected (401)"
        case .scopeInsufficient: return "token has no user:profile scope (403)"
        case .rateLimited(let after):
            return "rate limited (429)" + (after.map { ", retry in \(Int($0)) s" } ?? "")
        case .http(let code, let body): return "HTTP \(code): \(body)"
        case .shapeChanged(let why): return "shape changed: \(why)"
        case .transport(let why): return "network: \(why)"
        }
    }

    /// Banner text shown instead of wrong numbers.
    public var bannerText: String {
        switch self {
        case .shapeChanged: return "usage shape changed — numbers hidden"
        case .rateLimited: return "rate limited — showing the last reading"
        default: return description
        }
    }
}
