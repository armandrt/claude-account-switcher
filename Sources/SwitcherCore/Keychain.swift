import Foundation
import Security

public enum KeychainError: Error, CustomStringConvertible {
    case itemNotFound(String)
    case interactionRequired(String)
    case refused(String)
    case status(OSStatus, String)
    case cliFailed(Int32, String)

    public var description: String {
        switch self {
        case .itemNotFound(let s): return "no keychain item for \(s)"
        case .interactionRequired(let s): return "keychain would need the user to approve access to \(s)"
        case .refused(let s): return "refused: \(s)"
        case .status(let st, let s): return "keychain error \(st) for \(s)"
        case .cliFailed(let code, let s): return "security(1) exited \(code) for \(s)"
        }
    }
}

/// One `security` process at a time, for the whole app.
///
/// macOS asks about an item once per *check in flight*, not once per item: an approval
/// only counts after the keychain file has been rewritten, and every check that started
/// before that gets its own dialog.  Two concurrent reads of the same unapproved item are
/// therefore two dialogs with the same words.  The calls take 20 ms, so serialising them
/// costs nothing and caps this app's share of the dialogs at one.
enum KeychainGate {
    private static let lock = NSLock()

    static func serialised<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}

public protocol KeychainReading: Sendable {
    /// Service names of every generic password whose service starts with `prefix`.
    func services(withPrefix prefix: String) throws -> [String]
    func data(forService service: String) throws -> Data
}

public protocol KeychainWriting: Sendable {
    func write(_ data: Data, service: String, label: String) throws
    func delete(service: String) throws
}

/// Reads generic passwords.  Enumeration goes through Security.framework asking for attributes
/// only, which needs no authorisation and never prompts.  Item data is read with
/// `security find-generic-password -w` and never through the framework: this app reaches the
/// keychain as `cdhash:<this build>` — its signing identity carries no team id, so the hash
/// changes with every rebuild — while `/usr/bin/security` is always `apple-tool:`, which is
/// also how Claude Code and `claude-acct` reach the same items.  One identity for every reader
/// is one question to answer, once.
public struct SystemKeychainReader: KeychainReading {
    public let account: String

    public init(account: String = NSUserName()) {
        self.account = account
    }

    public func services(withPrefix prefix: String) throws -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &out)
        KeychainAudit.recordFramework("enumerate", service: "(attributes only)", outcome: "status \(status)")
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = out as? [[String: Any]] else {
            throw KeychainError.status(status, "enumerate")
        }
        let names = items.compactMap { $0[kSecAttrService as String] as? String }
            .filter { $0.hasPrefix(prefix) }
        return Array(Set(names)).sorted()
    }
}

extension SystemKeychainReader {
    /// Item data, through `security` and nothing else.
    ///
    /// There is deliberately no Security.framework fallback: it is the call that prompts, and
    /// a failure here is reported to the caller instead, which shows it on the account's row.
    public func data(forService service: String) throws -> Data {
        try Self.readViaSecurityCLI(service: service, account: account)
    }

    static func readViaSecurityCLI(service: String, account: String) throws -> Data {
        var args = ["find-generic-password", "-s", service, "-w"]
        if !account.isEmpty { args.insert(contentsOf: ["-a", account], at: 1) }

        let finished: (data: Data, status: Int32) = try KeychainGate.serialised {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            task.arguments = args
            let pipe = Pipe(), errPipe = Pipe()
            task.standardOutput = pipe
            task.standardError = errPipe
            let began = Date()
            do { try task.run() } catch { throw KeychainError.cliFailed(-1, service) }
            let out = pipe.fileHandleForReading.readDataToEndOfFile()
            _ = errPipe.fileHandleForReading.readDataToEndOfFile()
            task.waitUntilExit()
            KeychainAudit.record("cli/read", service: service,
                                 outcome: KeychainAudit.outcome(exit: task.terminationStatus,
                                                                since: began, service: service))
            return (data: out, status: task.terminationStatus)
        }
        guard finished.status == 0 else {
            // 44 is errSecItemNotFound as security(1) reports it.
            if finished.status == 44 { throw KeychainError.itemNotFound(service) }
            throw KeychainError.cliFailed(finished.status, service)
        }
        // `-w` prints the secret plus a newline: as text when it is printable, as a hex
        // dump otherwise.
        var bytes = finished.data
        while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
        return decodeHexIfNeeded(bytes)
    }

    /// A payload here is always JSON, so it opens with `{` and can never be all hex digits.
    static func decodeHexIfNeeded(_ bytes: Data) -> Data {
        guard bytes.count >= 2, bytes.count % 2 == 0 else { return bytes }
        let isHex = bytes.allSatisfy { byte in
            (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
        }
        guard isHex, let text = String(data: bytes, encoding: .utf8) else { return bytes }
        var decoded = Data(capacity: bytes.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return bytes }
            decoded.append(byte)
            index = next
        }
        return decoded
    }
}
