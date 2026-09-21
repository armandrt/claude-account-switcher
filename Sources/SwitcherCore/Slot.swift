import Foundation

public enum CredentialHealth: Equatable, Sendable {
    case ok
    /// Access token expired; the refresh token can still fix it.
    case expired
    /// Refresh token gone or past `refreshTokenExpiresAt`: only a new login fixes this.
    case needsRelogin
    /// The stored payload could not be parsed.
    case corrupt(String)
    /// The keychain item could not be read at all.
    case unreadable(String)

    public var label: String {
        switch self {
        case .ok: return "ok"
        case .expired: return "expired"
        case .needsRelogin: return "needs re-login"
        case .corrupt: return "corrupt"
        case .unreadable: return "unreadable"
        }
    }

    public var detail: String? {
        switch self {
        case .corrupt(let why), .unreadable(let why): return why
        default: return nil
        }
    }

    public var isUsable: Bool {
        switch self {
        case .ok, .expired: return true
        default: return false
        }
    }
}

public struct Slot: Identifiable, Equatable, Sendable {
    public var name: String
    public var isActive: Bool
    public var health: CredentialHealth
    public var credentials: OAuthCredentials?
    public var account: OAuthAccount?
    public var payload: CredentialPayload?
    public var byteCount: Int
    /// True when the numbers come from the live item rather than the slot snapshot.
    public var usesLiveCredentials: Bool

    public var id: String { name }
    public var planTier: String? { account?.planTier ?? credentials?.rateLimitTier }
    public var email: String? { account?.emailAddress }

    public init(name: String, isActive: Bool, health: CredentialHealth,
                credentials: OAuthCredentials? = nil, account: OAuthAccount? = nil,
                payload: CredentialPayload? = nil, byteCount: Int = 0,
                usesLiveCredentials: Bool = false) {
        self.name = name
        self.isActive = isActive
        self.health = health
        self.credentials = credentials
        self.account = account
        self.payload = payload
        self.byteCount = byteCount
        self.usesLiveCredentials = usesLiveCredentials
    }
}
