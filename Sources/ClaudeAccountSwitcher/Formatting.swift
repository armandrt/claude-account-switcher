import Foundation
import SwitcherCore

enum Format {
    static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    /// "resets in 3 h 12 m", from `resets_at`, never from a local timer.
    static func countdown(to date: Date, now: Date = Date()) -> String {
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "resetting now" }
        let hours = Int(seconds) / 3600
        let minutes = (Int(seconds) % 3600) / 60
        if hours >= 24 {
            let days = hours / 24
            return "resets in \(days) d \(hours % 24) h"
        }
        if hours > 0 { return "resets in \(hours) h \(minutes) m" }
        return "resets in \(minutes) m"
    }

    /// Quota LEFT as "64%", or "?%" with no reading.
    static func used(_ percentUsed: Double?) -> String {
        MenuBarLabel.remaining(from: percentUsed).map { "\(100 - $0)%" } ?? "?%"
    }

    /// One token for the right of a row: "47 m", "3 h", "2 d".
    static func short(to date: Date?, now: Date = Date()) -> String {
        guard let date else { return "—" }
        let seconds = date.timeIntervalSince(now)
        if seconds <= 0 { return "now" }
        // Under a minute is still a minute away: "0 m" reads as a window that is already back.
        if seconds < 3600 { return "\(max(1, Int(seconds / 60))) m" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h" }
        return "\(Int(seconds / 86_400)) d"
    }

    static func time(_ date: Date?) -> String {
        guard let date else { return "never" }
        return clock.string(from: date)
    }
}
