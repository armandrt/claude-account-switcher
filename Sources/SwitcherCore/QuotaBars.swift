import Foundation

/// One labelled micro-bar in a row: a word, a track, and a number.
public struct QuotaBar: Identifiable, Equatable, Sendable {
    /// "Session", "Week", or the model's own name.
    public var label: String
    /// Quota LEFT, 0…1: what the colour is judged by.  nil is no usable reading.
    public var fraction: Double?
    /// Quota USED, 0…1: how far the track is filled.  The same convention as
    /// Claude Code's own /usage, so the two can be read side by side.
    public var filled: Double? { fraction.map { 1 - $0 } }
    /// "36%" used, or "—".
    public var text: String
    /// Judged per limit, so a bar is neutral unless ITS window is in trouble.
    public var tone: LabelTone
    public var resetsAt: Date?
    /// True for the bar that says a model is used up.
    public var isModel: Bool

    public var id: String { label }

    public init(label: String, fraction: Double?, text: String, tone: LabelTone = .normal,
                resetsAt: Date? = nil, isModel: Bool = false) {
        self.label = label
        self.fraction = fraction
        self.text = text
        self.tone = tone
        self.resetsAt = resetsAt
        self.isModel = isModel
    }
}

public enum QuotaBars {
    public static let sessionLabel = "Session"
    public static let weekLabel = "Week"

    /// Always Session then Week, even with no reading, so columns line up; plus
    /// one more when a model is used up.
    public static func make(from snapshot: UsageSnapshot?) -> [QuotaBar] {
        var bars = [
            bar(labelled: sessionLabel, limit: snapshot?.limit(.session),
                legacyPercent: snapshot?.fiveHour?.utilization,
                legacyReset: snapshot?.fiveHour?.resetsAt),
            bar(labelled: weekLabel, limit: snapshot?.limit(.weeklyAll),
                legacyPercent: snapshot?.sevenDay?.utilization,
                legacyReset: snapshot?.sevenDay?.resetsAt),
        ]
        if let model = modelBar(from: snapshot) { bars.append(model) }
        return bars
    }

    /// The bar for a model-scoped window, named after the model: `Fable  ▇▇░░░░  88%`.
    ///
    /// Shown whenever the endpoint reports one, not only once it is spent — Claude
    /// Code's own /usage lists it alongside the session and the week, and a limit
    /// that only appears at 0% is one the owner cannot watch approaching. The
    /// tightest model leads; others are counted.
    public static func modelBar(from snapshot: UsageSnapshot?) -> QuotaBar? {
        let scoped = (snapshot?.scopedLimits ?? []).filter { $0.kind == .weeklyScoped || $0.percent != nil }
        guard let worst = scoped.max(by: { ($0.percent ?? -1) < ($1.percent ?? -1) }) else { return nil }
        let name = worst.modelDisplayName ?? worst.kind.raw
        let extra = scoped.count > 1 ? " +\(scoped.count - 1)" : ""
        return QuotaBar(label: name + extra, fraction: fraction(worst.percent),
                        text: text(worst.percent), tone: LabelTone.of(worst),
                        resetsAt: worst.resetsAt, isModel: true)
    }

    private static func bar(labelled label: String, limit: UsageLimit?,
                            legacyPercent: Double?, legacyReset: Date?) -> QuotaBar {
        if let limit {
            return QuotaBar(label: label, fraction: fraction(limit.percent),
                            text: text(limit.percent), tone: LabelTone.of(limit),
                            resetsAt: limit.resetsAt)
        }
        // Legacy fields carry no severity, so our thresholds decide.
        return QuotaBar(label: label, fraction: fraction(legacyPercent),
                        text: text(legacyPercent),
                        tone: LabelTone.forRemaining(MenuBarLabel.remaining(from: legacyPercent)),
                        resetsAt: legacyReset)
    }

    public static func fraction(_ percentUsed: Double?) -> Double? {
        MenuBarLabel.remaining(from: percentUsed).map { Double($0) / 100 }
    }

    /// The percentage USED, as Claude Code shows it.
    public static func text(_ percentUsed: Double?) -> String {
        MenuBarLabel.remaining(from: percentUsed).map { "\(100 - $0)%" } ?? "—"
    }
}
