import Foundation

/// Nothing in this app prints a token; anything that could hold one goes through here.
public enum Redact {
    /// Length and the last 4 characters, enough to tell two readings apart in a log.
    public static func token(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "<none>" }
        let tail = value.count >= 4 ? String(value.suffix(4)) : "?"
        return "<\(value.count) chars …\(tail)>"
    }

    public static func blob(_ data: Data?) -> String {
        guard let data else { return "<none>" }
        return "<\(data.count) bytes>"
    }

    /// Emails are shown in the UI but never in logs.
    public static func email(_ value: String?) -> String {
        guard let value, let at = value.firstIndex(of: "@") else { return "<none>" }
        let user = value[value.startIndex..<at]
        let head = user.prefix(1)
        return "\(head)***\(value[at...])"
    }
}
