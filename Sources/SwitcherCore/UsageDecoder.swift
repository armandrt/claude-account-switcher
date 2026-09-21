import Foundation

/// Hand-rolled decoder for an undocumented endpoint. Nothing here throws on a
/// field it does not recognise; only a response with no usable numbers at all
/// is reported as "shape changed". Anything it cannot vouch for is dropped to
/// "unknown" with a note — never rounded into a number the UI would draw.
public enum UsageDecoder {
    /// More entries than this is not a longer response, it is a different one.
    static let maximumLimits = 50
    /// Notes ride along into the on-disk cache; a pathological response must not
    /// be able to grow it without end.
    static let maximumNotes = 12
    /// A window resets within days. Outside this band around the reading, the
    /// value is a sentinel or a changed unit rather than a reset time: far in the
    /// past it would have the rollover rule call a used window empty, far ahead
    /// it makes every countdown and the balance arithmetic meaningless.
    static let earliestReset: TimeInterval = -30 * 86_400
    static let latestReset: TimeInterval = 60 * 86_400

    public static func decode(_ data: Data, fetchedAt: Date = Date()) throws -> UsageSnapshot {
        guard let any = try? JSONSerialization.jsonObject(with: data),
              let root = any as? [String: Any] else {
            throw UsageError.shapeChanged("response is not a JSON object (\(data.count) bytes)")
        }

        var notes: [String] = []
        var limits: [UsageLimit] = []

        if let array = root["limits"] as? [Any] {
            if array.isEmpty {
                notes.append("limits[] is empty — falling back to five_hour/seven_day")
            }
            if array.count > maximumLimits {
                notes.append("limits[] holds \(array.count) entries — only the first \(maximumLimits) were read")
            }
            for element in array.prefix(maximumLimits) {
                guard let object = element as? [String: Any] else {
                    notes.append("skipped a limits[] entry that is not an object")
                    continue
                }
                if let limit = limit(from: object, fetchedAt: fetchedAt, notes: &notes) {
                    limits.append(limit)
                }
            }
            limits = merged(limits, notes: &notes)
        } else if let other = root["limits"], !(other is NSNull) {
            notes.append("limits is \(type(of: other)), not an array — falling back to five_hour/seven_day")
        } else {
            notes.append("limits[] missing — falling back to five_hour/seven_day")
        }

        let fiveHour = window(root["five_hour"], named: "five_hour", fetchedAt: fetchedAt, notes: &notes)
        let sevenDay = window(root["seven_day"], named: "seven_day", fetchedAt: fetchedAt, notes: &notes)

        if limits.isEmpty, fiveHour == nil, sevenDay == nil {
            throw UsageError.shapeChanged("no usable limits and no five_hour/seven_day")
        }
        if notes.count > maximumNotes {
            notes = Array(notes.prefix(maximumNotes)) + ["\(notes.count - maximumNotes) more notes"]
        }
        return UsageSnapshot(limits: limits, fiveHour: fiveHour, sevenDay: sevenDay,
                             fetchedAt: fetchedAt, notes: notes)
    }

    static func limit(from object: [String: Any], fetchedAt: Date,
                      notes: inout [String]) -> UsageLimit? {
        guard let rawKind = object["kind"] as? String else {
            notes.append("skipped a limits[] entry with no kind")
            return nil
        }
        let kind = LimitKind(raw: rawKind)
        if case .unknown = kind { notes.append("new limit kind \"\(rawKind.prefix(40))\" — shown as-is") }

        var model: String?
        var surface: String?
        if let scope = object["scope"] as? [String: Any] {
            model = (scope["model"] as? [String: Any])?["display_name"] as? String
            surface = (scope["surface"] as? [String: Any])?["display_name"] as? String
                ?? scope["surface"] as? String
        }
        let named = model.map { "\(rawKind.prefix(40)) · \($0)" } ?? String(rawKind.prefix(40))
        let used = percent(object["percent"], of: named, notes: &notes)
        let resets = resetDate(object["resets_at"], of: named, fetchedAt: fetchedAt, notes: &notes)
        return UsageLimit(kind: kind,
                          group: object["group"] as? String,
                          percent: used,
                          severity: Severity(raw: object["severity"] as? String),
                          resetsAt: resets,
                          modelDisplayName: model,
                          surface: surface,
                          isActive: object["is_active"] as? Bool ?? false)
    }

    static func window(_ value: Any?, named name: String, fetchedAt: Date,
                       notes: inout [String]) -> LegacyWindow? {
        guard let object = value as? [String: Any] else { return nil }
        let utilization = percent(object["utilization"], of: name, notes: &notes)
        let resets = resetDate(object["resets_at"], of: name, fetchedAt: fetchedAt, notes: &notes)
        if utilization == nil && resets == nil { return nil }
        return LegacyWindow(utilization: utilization, resetsAt: resets)
    }

    /// Two entries for the same window is a shape nobody has seen, and reading the
    /// first one is picking between two numbers at random. Keep the worse number,
    /// the worse severity and the earlier reset: never the rosier of the two.
    static func merged(_ limits: [UsageLimit], notes: inout [String]) -> [UsageLimit] {
        var out: [UsageLimit] = []
        var seen: [String: Int] = [:]
        for limit in limits {
            guard let at = seen[limit.id] else {
                seen[limit.id] = out.count
                out.append(limit)
                continue
            }
            notes.append("limits[] repeats \(limit.title) — kept the worse of the two")
            out[at] = worse(out[at], limit)
        }
        return out
    }

    static func worse(_ first: UsageLimit, _ second: UsageLimit) -> UsageLimit {
        var out = first
        out.percent = [first.percent, second.percent].compactMap { $0 }.max()
        out.severity = Swift.max(first.severity, second.severity)
        out.resetsAt = [first.resetsAt, second.resetsAt].compactMap { $0 }.min()
        out.isActive = first.isActive || second.isActive
        out.modelDisplayName = first.modelDisplayName ?? second.modelDisplayName
        out.surface = first.surface ?? second.surface
        return out
    }

    /// A percentage outside 0–100 is not a number this app can draw. Noise at the
    /// edges is clamped to the edge; anything further out becomes unknown, because
    /// a fabricated 0 reads as a full account and sends work to it.
    static func percent(_ value: Any?, of what: String, notes: inout [String]) -> Double? {
        guard let value, !(value is NSNull) else { return nil }
        guard let raw = double(value) else {
            notes.append("\(what): percent is not a number — shown as unknown")
            return nil
        }
        if raw >= 0, raw <= 100 { return raw }
        if raw > 100, raw <= 100.5 { return 100 }
        if raw < 0, raw >= -0.5 { return 0 }
        notes.append("\(what): percent \(String(format: "%g", raw)) is outside 0–100 — shown as unknown")
        return nil
    }

    static func resetDate(_ value: Any?, of what: String, fetchedAt: Date,
                          notes: inout [String]) -> Date? {
        guard let value, !(value is NSNull) else { return nil }
        guard let date = date(value) else {
            notes.append("\(what): resets_at is not a date we know — countdown hidden")
            return nil
        }
        let days = date.timeIntervalSince(fetchedAt) / 86_400
        guard days >= earliestReset / 86_400, days <= latestReset / 86_400 else {
            notes.append("\(what): resets_at is \(Int(days.rounded())) days from the reading — dropped")
            return nil
        }
        return date
    }

    /// JSON booleans arrive as NSNumber too; they are not percentages.
    static func double(_ value: Any?) -> Double? {
        let number: Double?
        switch value {
        case let n as NSNumber where CFGetTypeID(n) != CFBooleanGetTypeID(): number = n.doubleValue
        case let s as String: number = Double(s)
        default: number = nil
        }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    /// Accepts `2026-09-17T18:20:00.955735+00:00` and the plain form without fractions.
    public static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        for formatter in formatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    private static let formatters: [ISO8601DateFormatter] = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return [withFraction, plain]
    }()
}
