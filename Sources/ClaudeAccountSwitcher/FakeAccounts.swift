import Foundation
import SwitcherCore

/// `CAS_FAKE_ACCOUNTS=20` fills the list with rows that look real and are not.
///
/// No keychain item is read or written for them, their credentials carry no
/// scope so the poller never asks the network, and every action refuses them.
enum FakeAccounts {
    static var requested: Int {
        ProcessInfo.processInfo.environment["CAS_FAKE_ACCOUNTS"].flatMap(Int.init) ?? 0
    }

    private static let names = [
        "perso", "perso2", "pro", "team-eu", "team-us", "client-acme", "sandbox",
        "billing-ops", "research", "design-review", "oncall", "data-platform",
        "growth", "support-escalations", "archive-2025", "contractor",
        "ml-experiments-long-name-that-will-not-fit", "demo", "spare", "backup",
    ]

    static func rows(_ count: Int, excluding taken: Set<String>, now: Date = Date()) -> [AccountRow] {
        var out: [AccountRow] = []
        var index = 0
        while out.count < count, index < 200 {
            let name = index < names.count ? names[index] : "spare-\(index)"
            index += 1
            guard !taken.contains(name) else { continue }
            out.append(row(name: name, seed: out.count, now: now))
        }
        return out
    }

    /// Deterministic per seed, so screenshots compare across launches.
    private static func row(name: String, seed: Int, now: Date) -> AccountRow {
        let health = healths[seed % healths.count]
        let credentials = OAuthCredentials(
            accessToken: "fake", refreshToken: "fake",
            expiresAt: now.addingTimeInterval(3600).timeIntervalSince1970 * 1000,
            refreshTokenExpiresAt: now.addingTimeInterval(86_400).timeIntervalSince1970 * 1000,
            scopes: [], subscriptionType: "max")
        let account = OAuthAccount(emailAddress: "\(name)@example.com",
                                   organizationRateLimitTier: tiers[seed % tiers.count])
        let slot = Slot(name: name, isActive: false, health: health,
                        credentials: credentials, account: account, byteCount: 4_096)

        var row = AccountRow(slot: slot, isFake: true)
        guard health.isUsable, seed % 7 != 3 else { return row }   // one in seven has no reading

        let session = Double((seed * 37) % 101)
        let weekly = Double((seed * 61) % 101)
        var limits = [
            UsageLimit(kind: .session, percent: session, severity: severity(for: session),
                       resetsAt: now.addingTimeInterval(Double((seed * 911) % 18_000) + 120)),
            UsageLimit(kind: .weeklyAll, percent: weekly, severity: severity(for: weekly),
                       resetsAt: now.addingTimeInterval(Double((seed * 7717) % 604_800) + 3600)),
        ]
        if seed % 4 == 0 {
            limits.append(UsageLimit(kind: .weeklyScoped, percent: 100, severity: .critical,
                                     resetsAt: now.addingTimeInterval(200_000),
                                     modelDisplayName: "Fable"))
        }
        row.usage = UsageSnapshot(limits: limits, fetchedAt: now.addingTimeInterval(-60))
        row.fetchedAt = row.usage?.fetchedAt
        row.isLive = true
        return row
    }

    private static func severity(for percentUsed: Double) -> Severity {
        if percentUsed >= 92 { return .critical }
        if percentUsed >= 78 { return .warning }
        return .normal
    }

    private static let tiers = ["default_claude_max_20x", "default_claude_max_5x", "default_claude_pro"]

    private static let healths: [CredentialHealth] = [
        .ok, .ok, .ok, .expired, .ok, .ok, .needsRelogin, .ok,
        .ok, .corrupt("not valid JSON (3955 bytes — looks truncated)"), .ok, .ok,
    ]
}
