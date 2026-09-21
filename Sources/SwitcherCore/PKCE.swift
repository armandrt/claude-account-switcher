import CryptoKit
import Foundation
import Security

/// The PKCE verifier/challenge pair and the `state` nonce for one sign-in.
///
/// The OAuth client is public (no secret in the binary), so the verifier is the
/// only thing binding a code to this process. It stays in memory for one login
/// and is never logged or persisted; `description` hides it.
public struct PKCE: Sendable {
    public let verifier: String
    public let challenge: String
    public let method = "S256"
    public let state: String
    /// When the pair was minted. A code is good for about a minute, so a pair
    /// older than `lifetime` belongs to a sign-in nobody is waiting on any more.
    public let createdAt: Date

    /// Well past any real trip through a browser, well short of leaving a
    /// verifier usable for an afternoon.
    public static let lifetime: TimeInterval = 900

    public init(verifier: String? = nil, state: String? = nil, createdAt: Date = Date()) {
        let verifier = verifier ?? Self.randomURLSafe(bytes: 32)
        self.verifier = verifier
        self.challenge = Self.challenge(for: verifier)
        self.state = state ?? Self.randomURLSafe(bytes: 32)
        self.createdAt = createdAt
    }

    public func isStale(now: Date = Date()) -> Bool {
        now.timeIntervalSince(createdAt) > Self.lifetime
    }

    /// True when a callback echoed this sign-in's state.
    public func matches(state echoed: String?) -> Bool {
        guard let echoed else { return false }
        return Self.equal(echoed, state)
    }

    /// Compares two secrets without stopping at the first difference: any local
    /// process can post to the loopback listener and time the answer.
    public static func equal(_ left: String, _ right: String) -> Bool {
        let one = Array(left.utf8), other = Array(right.utf8)
        guard one.count == other.count else { return false }
        var difference: UInt8 = 0
        for index in one.indices { difference |= one[index] ^ other[index] }
        return difference == 0
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    /// 32 random bytes as 43 base64url characters, the length Claude Code uses.
    public static func randomURLSafe(bytes count: Int) -> String {
        var bytes = [UInt8](repeating: 0, count: count)
        if SecRandomCopyBytes(kSecRandomDefault, count, &bytes) != errSecSuccess {
            // SystemRandomNumberGenerator is arc4random here, not a PRNG with a seed.
            for index in bytes.indices { bytes[index] = UInt8.random(in: .min ... .max) }
        }
        return base64URL(Data(bytes))
    }

    /// base64url without padding (RFC 7636 §4.2).
    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension PKCE: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String { "PKCE(state: \(state))" }
    public var debugDescription: String { description }
}
