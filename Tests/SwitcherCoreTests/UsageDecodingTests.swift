import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage decoding")
struct UsageDecodingTests {
    /// When the fixture was captured (its own `seven_day_breakdown.as_of`).  The
    /// decoder judges a `resets_at` against the time of the reading, so the recorded
    /// response is decoded at the moment it was recorded rather than at whatever
    /// today happens to be — otherwise these tests would start failing by the calendar.
    static let capturedAt = Date(timeIntervalSince1970: 1_789_655_851)

    @Test("the captured response decodes to three limits")
    func realResponse() throws {
        let snapshot = try UsageDecoder.decode(try Fixture.usageResponse(), fetchedAt: Self.capturedAt)
        #expect(snapshot.limits.count == 3)
        #expect(snapshot.sessionPercent == 17)
        #expect(snapshot.weeklyPercent == 69)

        let scoped = try #require(snapshot.scopedLimits.first)
        #expect(scoped.kind == .weeklyScoped)
        #expect(scoped.modelDisplayName == "Fable")
        #expect(scoped.percent == 100)
        #expect(scoped.severity == .critical)
        #expect(scoped.isActive)

        // A model-scoped 100% colours the icon but does not set its number.
        #expect(snapshot.tightest?.kind == .weeklyAll)
        #expect(snapshot.tightest?.percent == 69)
        #expect(snapshot.severity == .critical)
        #expect(snapshot.isBlocked == false)
        #expect(snapshot.notes.isEmpty)
    }

    @Test("reset times parse, including the +00:00 offset and microseconds")
    func resets() throws {
        let snapshot = try UsageDecoder.decode(try Fixture.usageResponse(), fetchedAt: Self.capturedAt)
        let weekly = try #require(snapshot.weeklyResetsAt)
        #expect(abs(weekly.timeIntervalSince1970 - 1789948800.955756) < 0.01)
        #expect(UsageDecoder.date("2026-09-17T18:20:00Z") != nil)
        #expect(UsageDecoder.date("not a date") == nil)
        #expect(UsageDecoder.date(nil) == nil)
    }

    @Test("an unknown kind is kept, noted, and never fatal")
    func unknownKind() throws {
        let json = """
        {"limits":[{"kind":"session","percent":10,"severity":"normal"},
                   {"kind":"monthly_quartz","group":"monthly","percent":42,
                    "severity":"warning","scope":{"model":{"display_name":"Fable"}}}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))
        #expect(snapshot.limits.count == 2)
        let unknown = try #require(snapshot.limits.last)
        #expect(unknown.kind == .unknown("monthly_quartz"))
        #expect(unknown.title == "monthly_quartz · Fable")
        #expect(unknown.percent == 42)
        #expect(snapshot.notes.contains { $0.contains("monthly_quartz") })
        #expect(snapshot.tightest?.kind == .session)
    }

    @Test("junk entries are skipped, not thrown")
    func junkEntries() throws {
        let json = """
        {"limits":["nope",{"group":"weekly"},{"kind":"weekly_all","percent":"88"}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))
        #expect(snapshot.limits.count == 1)
        #expect(snapshot.weeklyPercent == 88)
        #expect(snapshot.notes.count == 2)
    }

    @Test("a boolean or non-finite percent is a missing number, not a fabricated one")
    func oddNumbers() throws {
        let json = """
        {"limits":[{"kind":"session","percent":true},{"kind":"weekly_all","percent":"NaN"}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))
        #expect(snapshot.limits.count == 2)
        #expect(snapshot.sessionPercent == nil)
        #expect(snapshot.weeklyPercent == nil)
        #expect(snapshot.tightest == nil)
    }

    @Test("legacy five_hour/seven_day carry the numbers when limits[] disappears")
    func legacyFallback() throws {
        let json = """
        {"five_hour":{"utilization":34.0,"resets_at":"2026-09-17T14:00:00.1+00:00"},
         "seven_day":{"utilization":94.0,"resets_at":"2026-09-17T19:59:00.1+00:00"}}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))
        #expect(snapshot.limits.isEmpty)
        #expect(snapshot.sessionPercent == 34)
        #expect(snapshot.weeklyPercent == 94)
        #expect(snapshot.notes.contains { $0.contains("limits[] missing") })
    }

    @Test("a null or mistyped limits falls back instead of failing")
    func nullLimits() throws {
        let null = try UsageDecoder.decode(Data("""
        {"limits":null,"seven_day":{"utilization":52.0,"resets_at":"2026-09-21T00:00:00Z"}}
        """.utf8))
        #expect(null.limits.isEmpty)
        #expect(null.weeklyPercent == 52)

        let mistyped = try UsageDecoder.decode(Data("""
        {"limits":"soon","five_hour":{"utilization":3}}
        """.utf8))
        #expect(mistyped.sessionPercent == 3)
        #expect(mistyped.notes.contains { $0.contains("not an array") })
    }

    @Test("a response with nothing usable is a shape change, not a crash")
    func shapeChange() {
        #expect(throws: UsageError.shapeChanged("response is not a JSON object (7 bytes)")) {
            try UsageDecoder.decode(Data("<html>!".utf8))
        }
        #expect(throws: (any Error).self) {
            try UsageDecoder.decode(Data("{\"limits\":\"soon\"}".utf8))
        }
        #expect(throws: (any Error).self) {
            try UsageDecoder.decode(Data("{\"member_dashboard_available\":false}".utf8))
        }
    }

    @Test("a percentage outside 0-100 is unknown, never a number on a bar")
    func percentOutOfRange() throws {
        let json = """
        {"limits":[{"kind":"session","percent":-5,"severity":"normal"},
                   {"kind":"weekly_all","percent":140,"severity":"critical"},
                   {"kind":"weekly_scoped","percent":100.0001,
                    "scope":{"model":{"display_name":"Fable"}}}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8), fetchedAt: Self.capturedAt)
        // -5% used reads as 105% left: an account with nothing on it, flattered.
        #expect(snapshot.sessionPercent == nil)
        // 140% used is not "blocked", it is a field that stopped meaning percent.
        #expect(snapshot.weeklyPercent == nil)
        #expect(snapshot.isBlocked == false)
        #expect(snapshot.limits.count == 3)
        // Float noise at the edge is the edge, not a shape change.
        #expect(snapshot.scopedLimits.first?.percent == 100)
        #expect(snapshot.notes.count == 2)
        #expect(snapshot.notes.allSatisfy { $0.contains("outside 0–100") })
    }

    @Test("a repeated limit is merged down to the worse of the two")
    func duplicateLimits() throws {
        let json = """
        {"limits":[{"kind":"weekly_all","group":"weekly","percent":10,"severity":"normal",
                    "resets_at":"2026-09-21T00:00:00Z"},
                   {"kind":"weekly_all","group":"weekly","percent":95,"severity":"critical",
                    "resets_at":"2026-09-20T00:00:00Z"}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8), fetchedAt: Self.capturedAt)
        #expect(snapshot.limits.count == 1)
        // Reading the first entry would have been a coin toss between 10 and 95.
        #expect(snapshot.weeklyPercent == 95)
        #expect(snapshot.limit(.weeklyAll)?.severity == .critical)
        #expect(snapshot.weeklyResetsAt == UsageDecoder.date("2026-09-20T00:00:00Z"))
        #expect(snapshot.notes.contains { $0.contains("repeats") })

        // Two models under one kind are two limits, not a duplicate.
        let scoped = try UsageDecoder.decode(Data("""
        {"limits":[{"kind":"weekly_scoped","percent":100,"scope":{"model":{"display_name":"Fable"}}},
                   {"kind":"weekly_scoped","percent":5,"scope":{"model":{"display_name":"Opus"}}}]}
        """.utf8), fetchedAt: Self.capturedAt)
        #expect(scoped.limits.count == 2)
        #expect(scoped.notes.isEmpty)
    }

    @Test("a snapshot that already holds a duplicate is read by its worse half")
    func duplicateInAnOldCache() {
        // Written by a build whose decoder did not merge them yet.
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 4),
            UsageLimit(kind: .session, percent: 96),
        ])
        #expect(snapshot.sessionPercent == 96)
    }

    @Test("a reset time nothing could mean is dropped, and the percentage survives it")
    func implausibleResets() throws {
        let json = """
        {"limits":[{"kind":"session","percent":40,"resets_at":"1970-01-01T00:00:00Z"},
                   {"kind":"weekly_all","percent":50,"resets_at":"3000-01-01T00:00:00Z"},
                   {"kind":"weekly_scoped","percent":60,"resets_at":42,
                    "scope":{"model":{"display_name":"Fable"}}}]}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8), fetchedAt: Self.capturedAt)
        // An epoch-zero sentinel would have the rollover rule call a 40%-used window
        // empty; a year-3000 one makes every countdown and every urgency meaningless.
        #expect(snapshot.sessionPercent == 40)
        #expect(snapshot.sessionResetsAt == nil)
        #expect(snapshot.weeklyPercent == 50)
        #expect(snapshot.weeklyResetsAt == nil)
        #expect(snapshot.scopedLimits.first?.percent == 60)
        #expect(snapshot.scopedLimits.first?.resetsAt == nil)
        #expect(snapshot.notes.count == 3)

        // A reset that is merely a little behind the reading is real: windows roll.
        let justRolled = try UsageDecoder.decode(Data("""
        {"limits":[{"kind":"session","percent":40,"resets_at":"2026-09-17T14:30:00Z"}]}
        """.utf8), fetchedAt: Self.capturedAt)
        #expect(justRolled.sessionResetsAt != nil)
    }

    @Test("an empty limits[] says so and falls back")
    func emptyLimits() throws {
        let snapshot = try UsageDecoder.decode(Data("""
        {"limits":[],"five_hour":{"utilization":12.0}}
        """.utf8), fetchedAt: Self.capturedAt)
        #expect(snapshot.sessionPercent == 12)
        #expect(snapshot.notes.contains { $0.contains("empty") })
        #expect(throws: (any Error).self) {
            try UsageDecoder.decode(Data("{\"limits\":[]}".utf8))
        }
    }

    @Test("a response that grew a thousand entries cannot grow the cache with it")
    func floodOfEntries() throws {
        let junk = Array(repeating: "{\"group\":\"weekly\"}", count: 200).joined(separator: ",")
        let snapshot = try UsageDecoder.decode(
            Data("{\"limits\":[\(junk)],\"five_hour\":{\"utilization\":5}}".utf8),
            fetchedAt: Self.capturedAt)
        #expect(snapshot.sessionPercent == 5)
        #expect(snapshot.notes.count == UsageDecoder.maximumNotes + 1)
        #expect(snapshot.notes.last?.contains("more notes") == true)

        let many = (0..<200).map {
            "{\"kind\":\"weekly_scoped\",\"percent\":1,\"scope\":{\"model\":{\"display_name\":\"m\($0)\"}}}"
        }.joined(separator: ",")
        let capped = try UsageDecoder.decode(Data("{\"limits\":[\(many)]}".utf8),
                                             fetchedAt: Self.capturedAt)
        #expect(capped.limits.count == UsageDecoder.maximumLimits)
        #expect(capped.notes.contains { $0.contains("200 entries") })
    }

    @Test("a legacy window is held to the same range as a limit")
    func legacyRange() throws {
        let snapshot = try UsageDecoder.decode(Data("""
        {"five_hour":{"utilization":-3},"seven_day":{"utilization":52.0,
         "resets_at":"1970-01-01T00:00:00Z"}}
        """.utf8), fetchedAt: Self.capturedAt)
        #expect(snapshot.sessionPercent == nil)
        #expect(snapshot.weeklyPercent == 52)
        #expect(snapshot.weeklyResetsAt == nil)
    }
}
