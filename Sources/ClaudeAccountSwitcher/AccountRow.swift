import Foundation
import SwitcherCore

/// The labelled button a blocked row wears in the countdown's place.
enum RowFix: Equatable {
    case renew
    /// Tokens were rotated and the keychain refused them; they are in memory.
    case retrySave
    case login

    var title: String {
        switch self {
        case .renew: return "Renew"
        case .retrySave: return "Retry save"
        case .login: return "Log in"
        }
    }

    /// Amber only where something can be lost.
    var tone: LabelTone {
        switch self {
        case .renew: return .normal
        case .retrySave: return .amber
        case .login: return .amber
        }
    }

    var help: String {
        switch self {
        case .renew: return "Renew the access token"
        case .retrySave: return "Save the renewed tokens"
        case .login: return "Sign in again"
        }
    }
}

/// One slot plus whatever the last usage reading said about it, in "left" terms.
struct AccountRow: Identifiable {
    var slot: Slot
    var usage: UsageSnapshot?
    var problem: String?
    var fetchedAt: Date?
    /// When this process last asked the network about it, whatever the answer.
    var lastAttemptAt: Date?
    /// False while the numbers come from the on-disk cache.
    var isLive = false
    /// A `CAS_FAKE_ACCOUNTS` row: no keychain item behind it, every action refuses it.
    var isFake = false

    var id: String { slot.name }
    var name: String { slot.name }

    /// Live numbers older than this are labelled with their age too.
    static let staleAfter: TimeInterval = 300

    func age(now: Date = Date()) -> TimeInterval? {
        guard usage != nil, let fetchedAt else { return nil }
        let age = now.timeIntervalSince(fetchedAt)
        if !isLive { return max(0, age) }
        return age > Self.staleAfter ? age : nil
    }

    /// The reading with every elapsed window counted as full again, which is
    /// what the whole row is drawn from.
    func usage(now: Date = Date()) -> UsageSnapshot? { usage?.asOf(now) }

    /// True when a window reset after this reading was taken.
    ///
    /// Everything drawn from the reading is then an assumption — the window is
    /// empty *at* the reset, but the owner may have been working since — so the
    /// account is due a fresh read at once, and the bars say they are estimates.
    func awaitsPostResetReading(now: Date = Date()) -> Bool {
        guard let usage, let fetchedAt else { return false }
        let resets = usage.limits.compactMap(\.resetsAt)
            + [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].compactMap { $0 }
        return resets.contains { $0 > fetchedAt && $0 <= now }
    }

    /// The soonest reset still ahead, so the poll can wake for it.
    func nextReset(after now: Date = Date()) -> Date? {
        guard let usage else { return nil }
        let resets = usage.limits.compactMap(\.resetsAt)
            + [usage.fiveHour?.resetsAt, usage.sevenDay?.resetsAt].compactMap { $0 }
        return resets.filter { $0 > now }.min()
    }

    func label(now: Date = Date()) -> MenuBarLabel {
        MenuBarLabel.make(account: name, snapshot: usage(now: now), age: age(now: now))
    }

    var sessionRemaining: Int? { MenuBarLabel.remaining(from: usage()?.sessionPercent) }
    var weeklyRemaining: Int? { MenuBarLabel.remaining(from: usage()?.weeklyPercent) }

    /// The tighter of the two windows that stop all work.
    var tightestRemaining: Int? {
        [sessionRemaining, weeklyRemaining].compactMap { $0 }.min()
    }

    var tone: LabelTone { label().tone }

    /// The window under most pressure, counted from the rolled reading, so a
    /// window that has just refilled cannot take the countdown down with it:
    /// it has no reset time left, and the other window's is still known.
    var tightestReset: Date? {
        guard let snapshot = usage() else { return nil }
        let pressing = snapshot.limits
            .filter { $0.kind.blocksEverything && $0.resetsAt != nil }
            .max { ($0.percent ?? 0) < ($1.percent ?? 0) }
        if let resetsAt = pressing?.resetsAt { return resetsAt }
        return [snapshot.sessionResetsAt, snapshot.weeklyResetsAt].compactMap { $0 }.min()
    }

    var bars: [QuotaBar] { QuotaBars.make(from: usage()) }

    var hasModelBar: Bool { QuotaBars.modelBar(from: usage()) != nil }

    /// The one short thing on the right of a resting row.  A problem outranks a countdown.
    var secondary: String {
        if slot.health != .ok { return slot.health.label }
        guard usage != nil else { return "no reading" }
        return Format.short(to: tightestReset)
    }

    /// Set when the row's state, rather than its quota, is the problem.
    var secondaryTone: LabelTone? {
        switch slot.health {
        case .ok: return nil
        case .expired: return .amber
        case .needsRelogin, .corrupt, .unreadable: return .red
        }
    }

    /// The one fix a row that cannot show numbers offers.  A corrupt slot has
    /// nothing to renew, so it is never offered a renewal.
    func fix(hasUnstoredTokens: Bool) -> RowFix? {
        if hasUnstoredTokens { return .retrySave }
        guard !slot.isActive else { return nil }
        switch slot.health {
        case .expired: return .renew
        case .needsRelogin, .corrupt: return .login
        case .ok, .unreadable: return nil
        }
    }

    /// Why there are no numbers, in the words the dropdown shows.
    static func explain(_ slot: Slot) -> String? {
        switch slot.health {
        case .ok: return nil
        case .expired: return "access token expired"
        case .needsRelogin: return "the refresh token is dead"
        case .corrupt(let why): return "corrupt slot: \(why)"
        case .unreadable(let why): return "cannot read the keychain item: \(why)"
        }
    }
}

// MARK: - What the row draws

extension AccountRow {
    /// The letter in the badge, for a row that is not the live login.
    var initial: String {
        (name.first.map(String.init) ?? "?").uppercased()
    }

    /// Quota left in the tightest blocking window, 0…1, for the badge's ring.
    var tightestFraction: Double? {
        tightestRemaining.map { Double(100 - $0) / 100 }
    }

    /// The worse of the two blocking windows' judgements, for the badge.
    var barTone: LabelTone {
        bars.filter { !$0.isModel }.map(\.tone).max() ?? .normal
    }

    /// True while the numbers came from the cache, or are older than five minutes.
    var isStale: Bool { age() != nil }

    /// The window under most pressure, taken from the very bars the row draws,
    /// so the countdown on the right can never disagree with the gauges.
    var pressing: (label: String, resetsAt: Date)? {
        let windows = bars.filter { !$0.isModel && $0.resetsAt != nil }
        guard let worst = windows.min(by: { ($0.fraction ?? 1) < ($1.fraction ?? 1) }),
              let resetsAt = worst.resetsAt else { return nil }
        return (worst.label, resetsAt)
    }
}

/// One line of the disclosure: a word, sometimes a value, sometimes a sentence.
struct RowDetail {
    var text: String
    var value: String?
    var tone: LabelTone = .normal
    /// A sentence gets two lines' room; everything else is one.
    var wraps = false
}

extension AccountRow {
    /// Every exact number and the health problem, in the order they are shown.
    /// The list is fixed, so the height of the block is known before it opens.
    func details(hasUnstoredTokens: Bool) -> [RowDetail] {
        var lines: [RowDetail] = []
        if let email = slot.email {
            lines.append(RowDetail(text: email, value: slot.planTier))
        }
        lines.append(contentsOf: limitLines)
        if let age = age() {
            lines.append(RowDetail(text: "numbers", value: MenuBarLabel.ageText(age)))
        }
        if let problem = problem ?? AccountRow.explain(slot) {
            lines.append(RowDetail(text: problem, tone: secondaryTone ?? .normal, wraps: true))
        }
        if hasUnstoredTokens {
            lines.append(RowDetail(text: "renewed tokens are in memory only",
                                   tone: .amber, wraps: true))
        }
        return lines
    }

    /// Every limit as "17% used · 47 m".
    private var limitLines: [RowDetail] {
        guard let usage = usage() else { return [] }
        if usage.limits.isEmpty {
            return [RowDetail(text: "Session", value: Format.used(usage.sessionPercent)),
                    RowDetail(text: "Weekly", value: Format.used(usage.weeklyPercent))]
        }
        return usage.limits.map { limit in
            let reset = Format.short(to: limit.resetsAt)
            let left = (limit.percent ?? 0) >= 100
                ? "used up" : "\(Format.used(limit.percent)) used"
            return RowDetail(text: limit.title, value: "\(left) · \(reset)")
        }
    }
}
