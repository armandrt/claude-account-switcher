import Foundation
import Testing
@testable import SwitcherCore

@Suite("Quota bars")
struct QuotaBarsTests {
    @Test("two labelled bars, always, in the same order, as quota used")
    func twoBars() {
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyAll, percent: 69, severity: .normal,
                       resetsAt: Date(timeIntervalSince1970: 2_000)),
            UsageLimit(kind: .session, percent: 36, severity: .normal,
                       resetsAt: Date(timeIntervalSince1970: 1_000)),
        ])
        let bars = QuotaBars.make(from: snapshot)
        #expect(bars.map(\.label) == ["Session", "Week"])
        #expect(bars.map(\.text) == ["36%", "69%"])
        #expect(bars[0].fraction == 0.64)
        #expect(bars[1].fraction == 0.31)
        // The track fills with what is used; the colour is judged by what is left.
        #expect(bars[0].filled == 0.36)
        #expect(bars[1].filled == 0.69)
        #expect(bars.contains { $0.label.contains("5h") || $0.label.contains("wk") } == false)
        #expect(bars[0].resetsAt == Date(timeIntervalSince1970: 1_000))
        #expect(bars.allSatisfy { $0.tone == .normal })
    }

    @Test("a bar is neutral unless its own window is in trouble")
    func tonePerBar() {
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 10, severity: .normal),
            UsageLimit(kind: .weeklyAll, percent: 96, severity: .critical),
        ])
        let bars = QuotaBars.make(from: snapshot)
        #expect(bars[0].tone == .normal)
        #expect(bars[1].tone == .red)

        // The server's judgement wins over ours, per limit.
        let warned = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 75, severity: .warning),
            UsageLimit(kind: .weeklyAll, percent: 75, severity: .normal),
        ])
        let judged = QuotaBars.make(from: warned)
        #expect(judged[0].tone == .amber)
        #expect(judged[1].tone == .normal)
    }

    @Test("a used-up model is a third bar with its own name on it")
    func modelBar() {
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 0),
            UsageLimit(kind: .weeklyAll, percent: 0),
            UsageLimit(kind: .weeklyScoped, percent: 100, severity: .critical,
                       modelDisplayName: "Fable"),
        ])
        let bars = QuotaBars.make(from: snapshot)
        #expect(bars.count == 3)
        #expect(bars[2].label == "Fable")
        #expect(bars[2].text == "100%")
        #expect(bars[2].fraction == 0)
        #expect(bars[2].isModel)
        #expect(bars[2].tone == .red)
        #expect(bars[0].tone == .normal)
        #expect(bars[1].tone == .normal)
    }

    @Test("several models show the tightest and a count")
    func severalModels() {
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyScoped, percent: 100, modelDisplayName: "Fable"),
            UsageLimit(kind: .weeklyScoped, percent: 100, modelDisplayName: "Opus"),
            UsageLimit(kind: .weeklyScoped, percent: 100, modelDisplayName: "Sonnet"),
        ])
        #expect(QuotaBars.modelBar(from: snapshot)?.label == "Fable +2")

        // A model is shown as soon as the endpoint reports it, not only once spent:
        // 12% used is a bar at 88%, which is what Claude Code's own /usage shows.
        let inUse = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyScoped, percent: 12, severity: .normal, modelDisplayName: "Fable"),
        ])
        let bar = QuotaBars.modelBar(from: inUse)
        #expect(bar?.label == "Fable")
        #expect(bar?.text == "12%")
        #expect(bar?.fraction == 0.88)
        #expect(bar?.isModel == true)

        let tightestLeads = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyScoped, percent: 12, modelDisplayName: "Fable"),
            UsageLimit(kind: .weeklyScoped, percent: 70, modelDisplayName: "Opus"),
        ])
        #expect(QuotaBars.modelBar(from: tightestLeads)?.label == "Opus +1")
        #expect(QuotaBars.make(from: inUse).count == 3)
    }

    @Test("no reading is an empty track and a dash, never an invented bar")
    func noReading() {
        let bars = QuotaBars.make(from: nil)
        #expect(bars.map(\.label) == ["Session", "Week"])
        #expect(bars.map(\.text) == ["—", "—"])
        #expect(bars.allSatisfy { $0.fraction == nil })
        #expect(bars.allSatisfy { $0.tone == .normal })

        let half = QuotaBars.make(from: UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 40),
        ]))
        #expect(half[0].text == "40%")
        #expect(half[1].text == "—")
        #expect(half[1].fraction == nil)
    }

    @Test("the legacy fields fill the bars when limits[] is gone")
    func legacyFallback() throws {
        let snapshot = try UsageDecoder.decode(Data("""
        {"five_hour":{"utilization":34.0},"seven_day":{"utilization":94.0}}
        """.utf8))
        let bars = QuotaBars.make(from: snapshot)
        #expect(bars.map(\.text) == ["34%", "94%"])
        #expect(bars[0].tone == .normal)
        #expect(bars[1].tone == .red)
    }

    @Test("a reading past 100% used is an empty bar, not a negative one")
    func clamping() {
        let bars = QuotaBars.make(from: UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyAll, percent: 140),
        ]))
        #expect(bars[1].fraction == 0)
        #expect(bars[1].text == "100%")
    }

    @Test("the recorded response gives the expected row")
    func realResponse() throws {
        let snapshot = try UsageDecoder.decode(try Fixture.usageResponse())
        let bars = QuotaBars.make(from: snapshot)
        #expect(bars.map(\.label) == ["Session", "Week", "Fable"])
        #expect(bars.map(\.text) == ["17%", "69%", "100%"])
        #expect(bars[0].tone == .normal)
        #expect(bars[1].tone == .normal)
        #expect(bars[2].tone == .red)
    }
}
