import Foundation

public enum SwitchError: Error, Equatable, CustomStringConvertible {
    case busy(String)
    case badName(String)
    case noSuchSlot(String)
    /// The slot is there but unusable: truncated JSON, no access token.
    case slotUnusable(String, String)
    case liveUnreadable(String)
    case configFailed(String)
    /// Saving the live credentials into the slot being left failed; nothing else was attempted.
    case writeBackFailed(String, String)
    /// The live keychain item could not be written.  `rolledBack`: was `.claude.json` put back.
    case keychainFailed(String, rolledBack: Bool)
    /// The marker could not be written.  A stale marker would make the next switch save the
    /// new account's credentials into the old account's slot, so the switch is undone.
    case markerFailed(String, rolledBack: Bool)
    /// The world moved between the dry run the user confirmed and the switch.
    case changed(String)
    /// The marker names one account, the live credentials belong to another, and no slot
    /// holds that other account.
    case markerStale(String, liveEmail: String, storedEmail: String)

    public var description: String {
        switch self {
        case .busy(let why): return "a switch is already running: \(why)"
        case .badName(let name): return "\"\(name)\" is not a usable slot name (letters, digits, . _ -)"
        case .noSuchSlot(let name): return "no slot named \"\(name)\""
        case .slotUnusable(let name, let why): return "slot \"\(name)\" cannot be loaded: \(why)"
        case .liveUnreadable(let why): return "cannot read the live credentials: \(why)"
        case .configFailed(let why): return why
        case .writeBackFailed(let name, let why):
            return "could not save the live credentials back into \"\(name)\" (\(why)) — nothing was switched"
        case .keychainFailed(let why, let rolledBack):
            return "the live keychain item was not written (\(why))"
                + (rolledBack ? " — .claude.json was put back"
                              : " — .claude.json or the live credentials may not have been put back")
        case .markerFailed(let why, let rolledBack):
            // Never an instruction to type something; the panel can do this.
            return "the active-login marker was not written (\(why))"
                + (rolledBack
                    ? " — the switch was undone"
                    : " — the marker still names the previous account; store the current login"
                        + " under its own name with + before switching again")
        case .changed(let why): return "the accounts moved since that was shown: \(why)"
        case .markerStale(let name, let liveEmail, let storedEmail):
            return "the live login is \(liveEmail), but the marker says \"\(name)\", which holds "
                + "\(storedEmail) — nothing was switched. Store the current login under its own name "
                + "with + first, so it is not lost"
        }
    }
}

/// One end of a switch, in the words the confirmation shows.
public struct SwitchEndpoint: Equatable, Sendable {
    public var name: String
    public var email: String?
    public var planTier: String?

    public init(name: String, email: String? = nil, planTier: String? = nil) {
        self.name = name
        self.email = email
        self.planTier = planTier
    }

    public var describedEmail: String { email ?? "email unknown" }
}

/// One thing a switch will do, or has done.
public struct SwitchStep: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var done: Bool

    public init(title: String, detail: String, done: Bool = false) {
        self.title = title
        self.detail = detail
        self.done = done
    }
}

/// What a switch would do, or did.
public struct SwitchPlan: Equatable, Sendable {
    public var from: SwitchEndpoint?
    public var to: SwitchEndpoint
    public var steps: [SwitchStep]
    public var warnings: [String]
    /// False for a dry run.
    public var performed: Bool
    public var backupURL: URL?
    public var prunedBackups: Int

    public init(from: SwitchEndpoint?, to: SwitchEndpoint, steps: [SwitchStep] = [],
                warnings: [String] = [], performed: Bool = false,
                backupURL: URL? = nil, prunedBackups: Int = 0) {
        self.from = from
        self.to = to
        self.steps = steps
        self.warnings = warnings
        self.performed = performed
        self.backupURL = backupURL
        self.prunedBackups = prunedBackups
    }

    /// "perso2 (a@b) → pro (c@d)".
    public var headline: String {
        let left = from.map { "\($0.name) (\($0.describedEmail))" } ?? "nothing recorded as active"
        return "\(left) → \(to.name) (\(to.describedEmail))"
    }

    /// True when the target is already the live login: only its snapshot (and a stale
    /// marker) is refreshed; the config and the live item are not touched.
    public var isNoOp: Bool { from?.name == to.name }
}

/// What a capture would write, or wrote.
public struct CapturePlan: Equatable, Sendable {
    public var name: String
    public var service: String
    /// The login being snapshotted, read from `.claude.json`.
    public var liveEmail: String?
    /// The account the slot held before, when it could be read.
    public var replacingEmail: String?
    public var slotExists: Bool
    public var byteCount: Int
    public var warnings: [String]
    public var performed: Bool
    public var marksActive: Bool

    public init(name: String, service: String, liveEmail: String? = nil,
                replacingEmail: String? = nil, slotExists: Bool = false, byteCount: Int = 0,
                warnings: [String] = [], performed: Bool = false, marksActive: Bool = true) {
        self.name = name
        self.service = service
        self.liveEmail = liveEmail
        self.replacingEmail = replacingEmail
        self.slotExists = slotExists
        self.byteCount = byteCount
        self.warnings = warnings
        self.performed = performed
        self.marksActive = marksActive
    }

    public var headline: String {
        "store the login for \(liveEmail ?? "an unknown account") as \"\(name)\""
    }
}
