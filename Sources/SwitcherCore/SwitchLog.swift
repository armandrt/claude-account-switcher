import Foundation

/// One line in the panel's switch log: "12:04 would switch perso2 → pro: session limit".
public struct SwitchLogEntry: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable {
        /// Failover or Balance wanted to move and something held it back.
        case wouldSwitch
        case switched
        case captured
        case refreshed
        case failed
        case note
    }

    public var at: Date
    public var kind: Kind
    public var text: String
    public var id: String { "\(at.timeIntervalSince1970)|\(kind.rawValue)|\(text)" }

    public init(at: Date, kind: Kind, text: String) {
        self.at = at
        self.kind = kind
        self.text = text
    }
}

/// The log: newest first, capped.  A repeated policy decision is recorded once, not on
/// every poll, so it cannot bury the lines that matter.
public struct SwitchLog: Equatable, Sendable {
    public private(set) var entries: [SwitchLogEntry] = []
    public var limit: Int

    public init(limit: Int = 50) {
        self.limit = limit
    }

    public mutating func add(_ kind: SwitchLogEntry.Kind, _ text: String, at: Date = Date()) {
        entries.insert(SwitchLogEntry(at: at, kind: kind, text: text), at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    /// Records a decision that wanted to move accounts and did not: a decision to
    /// stay is not logged, and a switch that happened writes its own line.
    /// Returns true when a line was added.
    @discardableResult
    public mutating func record(_ decision: PolicyDecision, from active: String?,
                                held: String? = nil, at: Date = Date()) -> Bool {
        guard let target = decision.target else { return false }
        let text = "would switch \(active ?? "nothing") → \(target)"
            + (decision.cause.isEmpty ? "" : ": \(decision.cause)")
            + (held.map { " — \($0)" } ?? "")
        if let last = entries.first, last.kind == .wouldSwitch, last.text == text { return false }
        add(.wouldSwitch, text, at: at)
        return true
    }
}
