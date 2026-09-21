import Foundation

/// How urgent the label looks, read only from the windows that stop all work.
public enum LabelTone: String, Equatable, Comparable, Sendable {
    case normal
    case amber
    case red

    var rank: Int {
        switch self {
        case .normal: return 0
        case .amber: return 1
        case .red: return 2
        }
    }

    public static func < (lhs: LabelTone, rhs: LabelTone) -> Bool { lhs.rank < rhs.rank }

    /// The server's own bands; nil for a severity we do not recognise.
    public static func forSeverity(_ severity: Severity) -> LabelTone? {
        switch severity {
        case .normal: return .normal
        case .warning: return .amber
        case .critical: return .red
        case .unknown: return nil
        }
    }

    /// Our fallback: 25% or more left normal, 10–25% amber, below 10% red.
    public static func forRemaining(_ remaining: Int?) -> LabelTone {
        guard let remaining else { return .normal }
        if remaining < 10 { return .red }
        if remaining < 25 { return .amber }
        return .normal
    }

    /// The server's severity when it sent one, our thresholds otherwise.
    public static func of(_ limit: UsageLimit) -> LabelTone {
        forSeverity(limit.severity) ?? forRemaining(MenuBarLabel.remaining(from: limit.percent))
    }
}

/// Which judgement decided the colour.
public enum ToneSource: String, Equatable, Sendable {
    case severity
    case thresholds
    /// No numbers at all.
    case none
}

/// The readout: the account and how much quota is LEFT in each window, e.g.
/// `perso2 5h 75% wk 28% ⊘Fable`.  `body` carries the tone; `marker` (the
/// blocked model and the age) is drawn dimmed.
public struct MenuBarLabel: Equatable, Sendable {
    public var body: String
    public var marker: String
    public var tone: LabelTone
    public var toneSource: ToneSource

    public var text: String { body + marker }

    public init(body: String, marker: String = "", tone: LabelTone = .normal,
                toneSource: ToneSource = .none) {
        self.body = body
        self.marker = marker
        self.tone = tone
        self.toneSource = toneSource
    }

    public static let noAccount = MenuBarLabel(body: "no account")

    /// Percent LEFT, clamped to 0…100.
    public static func remaining(from percentUsed: Double?) -> Int? {
        guard let percentUsed, percentUsed.isFinite else { return nil }
        return Int(min(100, max(0, 100 - percentUsed)).rounded())
    }

    /// A nil snapshot shows as `<account> ?`, never a fabricated number.
    /// `age` is appended when the numbers are cached or stale.
    public static func make(account: String?, snapshot: UsageSnapshot?,
                            age: TimeInterval? = nil) -> MenuBarLabel {
        let prefix = account.map { "\($0) " } ?? ""
        guard let snapshot else { return MenuBarLabel(body: "\(prefix)?") }

        let session = remaining(from: snapshot.sessionPercent)
        let weekly = remaining(from: snapshot.weeklyPercent)
        // Percent USED, as Claude Code's own /usage shows it; the colour still
        // comes from what is left.
        let body = "\(prefix)5h \(usedText(session)) wk \(usedText(weekly))"

        let (tone, source) = self.tone(for: snapshot, session: session, weekly: weekly)

        var marker = marker(for: snapshot)
        if let age { marker += " \(ageText(age))" }
        return MenuBarLabel(body: body, marker: marker, tone: tone, toneSource: source)
    }

    /// Worst blocking window wins, each judged by the server's severity when
    /// it sent one.  A model-scoped limit never votes: it blocks one model, not the account.
    static func tone(for snapshot: UsageSnapshot,
                     session: Int?, weekly: Int?) -> (LabelTone, ToneSource) {
        let blocking = snapshot.limits.filter { $0.kind.blocksEverything }
        guard !blocking.isEmpty else {
            // Legacy five_hour / seven_day carry no severity.
            return (LabelTone.forRemaining([session, weekly].compactMap { $0 }.min()), .thresholds)
        }
        let judged = blocking.map { limit -> (LabelTone, ToneSource) in
            if let tone = LabelTone.forSeverity(limit.severity) { return (tone, .severity) }
            return (LabelTone.forRemaining(remaining(from: limit.percent)), .thresholds)
        }
        return judged.max { $0.0 < $1.0 } ?? (.normal, .thresholds)
    }

    /// "12s ago", "4m ago", "3h ago", "2d ago".
    public static func ageText(_ age: TimeInterval) -> String {
        let seconds = max(0, age)
        if seconds < 60 { return "\(Int(seconds))s ago" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 172_800 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86_400))d ago"
    }

    /// A model-scoped limit appears only once it blocks.
    static func marker(for snapshot: UsageSnapshot) -> String {
        let blocked = snapshot.scopedLimits.filter { ($0.percent ?? 0) >= 100 }
        guard let first = blocked.first else { return "" }
        let name = first.modelDisplayName ?? first.kind.raw
        let extra = blocked.count > 1 ? "+\(blocked.count - 1)" : ""
        return " ⊘\(name)\(extra)"
    }

    static func text(_ remaining: Int?) -> String {
        remaining.map { "\($0)%" } ?? "?%"
    }

    static func usedText(_ remaining: Int?) -> String {
        remaining.map { "\(100 - $0)%" } ?? "?%"
    }
}
