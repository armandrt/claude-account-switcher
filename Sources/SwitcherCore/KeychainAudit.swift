import Foundation

/// A line per keychain operation, so a password prompt can be traced to the call that caused it.
///
/// Service names, operations and outcomes only — never a payload, a token or an email. Kept to
/// the last few hundred lines. Always on: the prompt this exists to explain appears while the
/// owner is using the app, not while anyone is watching a terminal.
public enum KeychainAudit {
    public static let url = UsageCache.defaultDirectory.appendingPathComponent("keychain.log")
    private static let limit = 400
    private static let lock = NSLock()

    public static func record(_ operation: String, service: String, outcome: String) {
        let line = "\(stamp()) \(operation) \(service) → \(outcome)\n"
        lock.lock()
        defer { lock.unlock() }
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        } else {
            try? Data(line.utf8).write(to: url)
        }
        trim()
    }

    /// A `security` call that takes this long was almost certainly waiting behind a dialog:
    /// the work itself is milliseconds.
    static let dialogThreshold: TimeInterval = 1.5

    public static func outcome(exit code: Int32, since began: Date, service: String = "") -> String {
        let seconds = Date().timeIntervalSince(began)
        let took = String(format: "%.2fs", seconds)
        guard seconds >= dialogThreshold else { return "exit \(code) in \(took)" }
        if !service.isEmpty { prompts.note(service) }
        return "exit \(code) after \(took) — PROMPTED: this item's partition list does not"
            + " name apple-tool:, so every security call on it is questioned until it is rewritten"
    }

    /// Items macOS put a dialog in front of since this launch.
    ///
    /// A dialog on a `security` call means one thing: the item's ACL partition list does
    /// not name `apple-tool:`, the partition `/usr/bin/security` runs under.  Answering
    /// "Always Allow" adds it, but only to that item, and only once the keychain file has
    /// been rewritten — every check already in flight asks its own question first, which
    /// is why one item can produce dozens of dialogs at once.  Anything recorded here is
    /// still carrying a foreign partition list and has to be written again *by* `security`
    /// for the list to be replaced for good.
    private final class PromptRecord: @unchecked Sendable {
        private let lock = NSLock()
        private var services: Set<String> = []
        func note(_ service: String) { lock.withLock { _ = services.insert(service) } }
        func has(_ service: String) -> Bool { lock.withLock { services.contains(service) } }
        func clear(_ service: String) { lock.withLock { _ = services.remove(service) } }
        func all() -> [String] { lock.withLock { services.sorted() } }
    }
    private static let prompts = PromptRecord()

    public static func note(prompted service: String) { prompts.note(service) }
    public static func didPrompt(_ service: String) -> Bool { prompts.has(service) }
    public static func clearPrompt(_ service: String) { prompts.clear(service) }
    /// For the panel and for a report: every item still known to prompt.
    public static func promptedServices() -> [String] { prompts.all() }

    /// Framework calls reach the keychain as this build rather than as `apple-tool:`, so they
    /// are marked: they are the ones whose refusal means the item was created by something else.
    public static func recordFramework(_ operation: String, service: String, outcome: String) {
        record("FRAMEWORK/\(operation)", service: service, outcome: outcome)
    }

    private static func trim() {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > limit * 2 else { return }
        let kept = lines.suffix(limit).joined(separator: "\n")
        try? Data(kept.utf8).write(to: url, options: .atomic)
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
