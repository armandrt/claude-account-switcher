import Foundation
import Security

/// Writes generic passwords through `/usr/bin/security`, the same tool Claude Code's own
/// shell helpers use.
///
/// Not Security.framework, and the reason matters.  Every keychain item carries a *partition
/// list*: the set of code identities that may reach it without being questioned.  macOS fills
/// it in from whoever creates the item — `cdhash:<this build>` for an app, `apple-tool:` for
/// `/usr/bin/security`, `apple:` for `codesign` — and a client outside the list gets the
/// "enter your keychain password" dialog, every time, until someone answers "Always Allow".
/// `security` is the one identity that everything here shares: this app's reads, `claude-acct`,
/// and Claude Code, which shells out to `security` on every launch.  So an item created by
/// `SecItemAdd` is an item all three of them will be asked about; an item created by `security`
/// is an item none of them are.  Nothing in this app may create a keychain item any other way.
///
/// An update (`-U`) keeps the list the item already has, so it neither breaks nor fixes one:
/// only deleting and writing again replaces it.
///
/// The payload is passed as an argument, never through `security -i`, whose input line limit
/// is what truncated a 3,955-byte slot into unusable JSON.
///
/// Anything outside `servicePrefix` is refused, and so is the live item unless the caller named
/// it in `writableLiveService`: only the switch may write Claude Code's own credentials.
public struct SystemKeychainWriter: KeychainWriting {
    public static let liveService = "Claude Code-credentials"
    /// `security` is a system tool and could in principle be absent; its path is fixed.
    static let tool = "/usr/bin/security"

    public let servicePrefix: String
    public let account: String
    /// nil for every writer but the switch's.
    public let writableLiveService: String?

    public init(servicePrefix: String, account: String = NSUserName(),
                writableLiveService: String? = nil) {
        self.servicePrefix = servicePrefix
        self.account = account
        self.writableLiveService = writableLiveService
    }

    func check(_ service: String) throws {
        if let writableLiveService, service == writableLiveService { return }
        if service == Self.liveService {
            throw KeychainError.refused("the live credentials item is never written by this app")
        }
        guard !servicePrefix.isEmpty, service.hasPrefix(servicePrefix) else {
            throw KeychainError.refused("service \"\(service)\" is outside the write prefix \"\(servicePrefix)\"")
        }
    }

    /// Bytes an argument can carry: UTF-8, no NUL.  An argument stops at the first NUL, so
    /// `security` would store a truncated payload and exit 0 — the way a slot died once.
    static func isCarriable(_ data: Data) -> Bool {
        !data.isEmpty && !data.contains(0) && String(data: data, encoding: .utf8) != nil
    }

    public func write(_ data: Data, service: String, label: String) throws {
        try check(service)
        guard let text = String(data: data, encoding: .utf8) else {
            throw KeychainError.refused("payload for \"\(service)\" is not UTF-8")
        }
        guard !data.contains(0) else {
            throw KeychainError.refused(
                "payload for \"\(service)\" contains a NUL byte, which an argument cannot carry")
        }
        // -U updates in place when the item exists and creates it when it does not, so one
        // call covers both. An empty label leaves the item's own alone.
        var arguments = ["add-generic-password", "-U", "-a", account, "-s", service]
        if !label.isEmpty { arguments += ["-l", label] }
        arguments += ["-w", text]
        try Self.run(arguments, service: service)
    }

    public func delete(service: String) throws {
        try check(service)
        do {
            try Self.run(["delete-generic-password", "-a", account, "-s", service], service: service)
        } catch KeychainError.itemNotFound {
            // Already gone is the state the caller wanted.
        }
    }

    /// Runs `security` and turns its exit code into the errors the rest of the app handles.
    ///
    /// The payload appears in this process's argument list for as long as the call takes.
    /// On a single-user Mac that is a narrow window, and the alternative — `security -i` —
    /// is what silently truncated a slot and cost an account.
    static func run(_ arguments: [String], service: String) throws {
        let finished: (message: String, status: Int32) = try KeychainGate.serialised {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: tool)
            task.arguments = arguments
            let errors = Pipe()
            task.standardOutput = Pipe()
            task.standardError = errors
            let began = Date()
            do { try task.run() } catch { throw KeychainError.cliFailed(-1, "\(service): \(error)") }
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            task.waitUntilExit()
            KeychainAudit.record("cli/\(arguments.first ?? "?")", service: service,
                                 outcome: KeychainAudit.outcome(exit: task.terminationStatus,
                                                                since: began, service: service))
            return (message: text, status: task.terminationStatus)
        }
        guard finished.status != 0 else { return }
        if finished.status == 44 { throw KeychainError.itemNotFound(service) }
        throw KeychainError.cliFailed(
            finished.status,
            "\(service): \(finished.message.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
}

// MARK: - Repairing items an earlier build created

extension SystemKeychainWriter {
    /// Delete, write, read back — the only order that replaces an item's partition list, and
    /// the only one that can drop an item.  The bytes go back if any step fails, so a rewrite
    /// that cannot finish is a no-op rather than a lost account.
    static func rewrite(data: Data,
                        delete: () -> Void,
                        write: (Data) throws -> Void,
                        readBack: () throws -> Data,
                        restore: (Data) -> Void) throws {
        delete()
        do {
            try write(data)
            let back = try readBack()
            guard matches(back, data) else {
                throw KeychainError.refused(
                    "the rewritten item came back as \(back.count) bytes, not the \(data.count) written")
            }
        } catch {
            restore(data)
            throw error
        }
    }

    /// `security` prints the secret with a newline, so the reader trims them; the comparison
    /// has to trim the same way or a payload that ends in one could never be proved.
    static func matches(_ readBack: Data, _ written: Data) -> Bool {
        func trimmed(_ data: Data) -> Data {
            var bytes = data
            while let last = bytes.last, last == 0x0a || last == 0x0d { bytes.removeLast() }
            return bytes
        }
        return trimmed(readBack) == trimmed(written)
    }

    /// Rewrites an item through `security` so its partition list becomes `apple-tool:`.
    ///
    /// This is the only thing that makes one dialog the last one.  An item whose list names
    /// some build's cdhash — earlier versions of this app created slots with `SecItemAdd`, and
    /// the live item too — asks again on every access by every tool, and "Always Allow" only
    /// adds the missing partition to that one item, in a file rewrite that the checks already
    /// in flight do not wait for.  Written again *by* `security`, the item is never asked
    /// about again, by anything.  Deleting is what replaces the list; an update would keep it.
    /// Safe only because the caller holds the bytes, and they go back if the rewrite fails.
    public func normaliseAccess(service: String, data: Data, label: String) throws {
        try check(service)
        // Checked before the delete: `write` refuses these, and by then the item is gone.
        guard Self.isCarriable(data) else {
            throw KeychainError.refused(
                "\"\(service)\" holds bytes `security` cannot carry, so it is left as it is")
        }
        try Self.rewrite(
            data: data,
            delete: {
                _ = try? Self.run(["delete-generic-password", "-a", account, "-s", service],
                                  service: service)
            },
            write: { try self.write($0, service: service, label: label) },
            readBack: { try SystemKeychainReader(account: account).data(forService: service) },
            restore: { Self.restoreThroughSecurity(service: service, account: account,
                                                   data: $0, label: label) })
    }

    /// Puts the bytes back after a failed rewrite, through `security` like every other write.
    ///
    /// It used to be `SecItemAdd`, and that was the bug: an item created by this app carries a
    /// partition list naming this build alone — no `apple-tool:` — so afterwards *every*
    /// `security` call on it raises a keychain dialog: this app's own reads, `claude-acct`'s,
    /// and Claude Code's, which shells out to `security` on every launch.  `-U` covers both
    /// creating the item and overwriting whatever the half-finished write left behind.
    static func restoreThroughSecurity(service: String, account: String, data: Data, label: String) {
        guard let text = String(data: data, encoding: .utf8) else { return }
        var arguments = ["add-generic-password", "-U", "-a", account, "-s", service]
        if !label.isEmpty { arguments += ["-l", label] }
        arguments += ["-w", text]
        _ = try? run(arguments, service: service)
    }

    /// Reads an item this app created, without `security`.
    ///
    /// Only ever called for repair, and only once per item per launch.  A framework read of an
    /// item this build did not create is the one call in the app that could raise a keychain
    /// dialog, so user interaction is turned off around it: `kSecUseAuthenticationUIFail`
    /// governs items that authenticate with UI, *not* a legacy access list or a partition list,
    /// and `SecKeychainSetUserInteractionAllowed(false)` is the switch that actually applies to
    /// those — it turns the dialog into `errSecInteractionRequired`, which is a nil here.
    ///
    /// Process-wide while it is off, which is why it is put back immediately; the only other
    /// framework call in the app enumerates attributes and never wanted a dialog anyway.
    public static func readOwnItem(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUIFail,
        ]
        return KeychainGate.serialised { () -> Data? in
            _ = SecKeychainSetUserInteractionAllowed(false)
            defer { _ = SecKeychainSetUserInteractionAllowed(true) }

            var out: CFTypeRef?
            KeychainAudit.recordFramework("read", service: service, outcome: "starting, no UI")
            let status = SecItemCopyMatching(query as CFDictionary, &out)
            KeychainAudit.recordFramework("read", service: service, outcome: "status \(status)")
            guard status == errSecSuccess else { return nil }
            return out as? Data
        }
    }
}
