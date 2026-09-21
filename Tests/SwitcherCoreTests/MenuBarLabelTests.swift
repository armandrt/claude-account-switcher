import Foundation
import Testing
@testable import SwitcherCore

@Suite("Menu bar label")
struct MenuBarLabelTests {
    /// Limits with no severity, so these exercise the threshold fallback.
    static func snapshot(session: Double?, weekly: Double?,
                         scoped: [(String, Double)] = []) -> UsageSnapshot {
        var limits: [UsageLimit] = []
        if let session { limits.append(UsageLimit(kind: .session, percent: session)) }
        if let weekly { limits.append(UsageLimit(kind: .weeklyAll, percent: weekly)) }
        for (name, percent) in scoped {
            limits.append(UsageLimit(kind: .weeklyScoped, percent: percent, modelDisplayName: name))
        }
        return UsageSnapshot(limits: limits)
    }

    @Test("both windows are always shown, as quota used")
    func bothWindows() {
        let label = MenuBarLabel.make(account: "perso2",
                                      snapshot: Self.snapshot(session: 25, weekly: 72))
        #expect(label.text == "perso2 5h 25% wk 72%")
        #expect(label.marker.isEmpty)
        #expect(label.tone == .normal)
    }

    @Test("an idle window still shows its 0%")
    func idleWindow() {
        let label = MenuBarLabel.make(account: "pro",
                                      snapshot: Self.snapshot(session: 0, weekly: 0))
        #expect(label.text == "pro 5h 0% wk 0%")
    }

    @Test("a blocked model is an aside, not the headline")
    func blockedModel() {
        let label = MenuBarLabel.make(
            account: "perso2",
            snapshot: Self.snapshot(session: 25, weekly: 72, scoped: [("Fable", 100)]))
        #expect(label.body == "perso2 5h 25% wk 72%")
        #expect(label.marker == " ⊘Fable")
        #expect(label.text == "perso2 5h 25% wk 72% ⊘Fable")
        #expect(label.tone == .normal)
    }

    @Test("a scoped limit below 100% stays out of the menu bar")
    func scopedNotBlocked() {
        let label = MenuBarLabel.make(
            account: "perso2",
            snapshot: Self.snapshot(session: 10, weekly: 20, scoped: [("Fable", 99)]))
        #expect(label.text == "perso2 5h 10% wk 20%")
        #expect(label.marker.isEmpty)
    }

    @Test("several blocked models show the first and a count")
    func severalBlockedModels() {
        let label = MenuBarLabel.make(
            account: "perso2",
            snapshot: Self.snapshot(session: 0, weekly: 0,
                                    scoped: [("Fable", 100), ("Opus", 100), ("Sonnet", 100)]))
        #expect(label.marker == " ⊘Fable+2")
    }

    @Test("colour comes only from the tighter of session and weekly")
    func tone() {
        // 25% left is still normal; 24% is amber; 9% is red.
        #expect(MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 75, weekly: 0)).tone == .normal)
        #expect(MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 76, weekly: 0)).tone == .amber)
        #expect(MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 90, weekly: 0)).tone == .amber)
        #expect(MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 91, weekly: 0)).tone == .red)
        #expect(MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 0, weekly: 95)).tone == .red)
        #expect(MenuBarLabel.make(account: "a",
                                  snapshot: Self.snapshot(session: 0, weekly: 0,
                                                          scoped: [("Fable", 100)])).tone == .normal)
        #expect(LabelTone.forRemaining(nil) == .normal)
    }

    @Test("the server's severity decides the colour when it sends one")
    func severityWins() {
        // 25% left: our thresholds say normal, the server says warning.  The server wins.
        let warned = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 41, severity: .normal),
            UsageLimit(kind: .weeklyAll, percent: 75, severity: .warning),
        ])
        let label = MenuBarLabel.make(account: "perso2", snapshot: warned)
        #expect(label.tone == .amber)
        #expect(label.toneSource == .severity)
        #expect(LabelTone.forRemaining(25) == .normal)

        let critical = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 99, severity: .critical),
            UsageLimit(kind: .weeklyAll, percent: 5, severity: .normal),
        ])
        #expect(MenuBarLabel.make(account: "a", snapshot: critical).tone == .red)

        // A server more relaxed than us is obeyed too.
        let relaxed = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyAll, percent: 97, severity: .normal),
        ])
        let relaxedLabel = MenuBarLabel.make(account: "a", snapshot: relaxed)
        #expect(relaxedLabel.tone == .normal)
        #expect(relaxedLabel.toneSource == .severity)
    }

    @Test("a blocked model never votes on the colour, whatever its severity")
    func scopedNeverVotes() {
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 10, severity: .normal),
            UsageLimit(kind: .weeklyAll, percent: 20, severity: .normal),
            UsageLimit(kind: .weeklyScoped, percent: 100, severity: .critical,
                       modelDisplayName: "Fable"),
        ])
        let label = MenuBarLabel.make(account: "perso2", snapshot: snapshot)
        #expect(label.text == "perso2 5h 10% wk 20% ⊘Fable")
        #expect(label.tone == .normal)
        #expect(label.toneSource == .severity)
    }

    @Test("an unknown or missing severity falls back to our thresholds")
    func fallsBackToThresholds() {
        let odd = UsageSnapshot(limits: [
            UsageLimit(kind: .weeklyAll, percent: 95, severity: Severity(raw: "vermilion")),
        ])
        let label = MenuBarLabel.make(account: "a", snapshot: odd)
        #expect(label.tone == .red)
        #expect(label.toneSource == .thresholds)

        // Legacy windows carry no severity; 12% left lands in our amber band.
        let legacy = UsageSnapshot(limits: [], fiveHour: LegacyWindow(utilization: 80),
                                   sevenDay: LegacyWindow(utilization: 88))
        let legacyLabel = MenuBarLabel.make(account: "a", snapshot: legacy)
        #expect(legacyLabel.tone == .amber)
        #expect(legacyLabel.toneSource == .thresholds)

        // Mixed: each limit judged its own way, the worse one wins.
        let mixed = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 96),
            UsageLimit(kind: .weeklyAll, percent: 10, severity: .normal),
        ])
        let mixedLabel = MenuBarLabel.make(account: "a", snapshot: mixed)
        #expect(mixedLabel.tone == .red)
        #expect(mixedLabel.toneSource == .thresholds)
        #expect(LabelTone.normal < LabelTone.amber)
        #expect(LabelTone.amber < LabelTone.red)
    }

    @Test("a reading over 100% used clamps to 100%")
    func clampsAbove100() {
        let label = MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 140, weekly: 100.4))
        #expect(label.text == "a 5h 100% wk 100%")
        #expect(label.tone == .red)
        #expect(MenuBarLabel.remaining(from: -5) == 100)
        #expect(MenuBarLabel.remaining(from: .nan) == nil)
        #expect(MenuBarLabel.remaining(from: nil) == nil)
    }

    @Test("a missing window shows ?%, never a made-up number")
    func missingWindow() {
        let noSession = MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: nil, weekly: 40))
        #expect(noSession.text == "a 5h ?% wk 40%")
        #expect(noSession.tone == .normal)

        let noWeekly = MenuBarLabel.make(account: "a", snapshot: Self.snapshot(session: 95, weekly: nil))
        #expect(noWeekly.text == "a 5h 95% wk ?%")
        #expect(noWeekly.tone == .red)

        let scopedOnly = MenuBarLabel.make(
            account: "a", snapshot: Self.snapshot(session: nil, weekly: nil, scoped: [("Fable", 100)]))
        #expect(scopedOnly.text == "a 5h ?% wk ?% ⊘Fable")
        #expect(scopedOnly.tone == .normal)
    }

    @Test("legacy five_hour/seven_day fill the windows when limits[] is gone")
    func legacyFallback() throws {
        let json = """
        {"five_hour":{"utilization":34.0},"seven_day":{"utilization":94.0}}
        """
        let snapshot = try UsageDecoder.decode(Data(json.utf8))
        let label = MenuBarLabel.make(account: "perso", snapshot: snapshot)
        #expect(label.text == "perso 5h 34% wk 94%")
        #expect(label.tone == .red)
    }

    @Test("a cached reading keeps its numbers and says how old it is")
    func staleness() {
        let snapshot = Self.snapshot(session: 25, weekly: 72)
        let label = MenuBarLabel.make(account: "perso2", snapshot: snapshot, age: 4 * 60)
        #expect(label.text == "perso2 5h 25% wk 72% 4m ago")
        #expect(label.body == "perso2 5h 25% wk 72%")
        #expect(label.marker == " 4m ago")
        #expect(label.tone == .normal)

        let both = MenuBarLabel.make(
            account: "perso2",
            snapshot: Self.snapshot(session: 25, weekly: 72, scoped: [("Fable", 100)]),
            age: 3600)
        #expect(both.text == "perso2 5h 25% wk 72% ⊘Fable 1h ago")
    }

    @Test("the account name comes off when there is no room for it")
    func withoutAccountName() {
        let snapshot = Self.snapshot(session: 25, weekly: 72, scoped: [("Fable", 100)])
        let named = MenuBarLabel.make(account: "perso2", snapshot: snapshot)
        let bare = MenuBarLabel.make(account: nil, snapshot: snapshot)
        #expect(bare.text == "5h 25% wk 72% ⊘Fable")
        #expect(named.text == "perso2 " + bare.text)
        #expect(bare.tone == named.tone)
        #expect(MenuBarLabel.make(account: nil, snapshot: nil).text == "?")
    }

    @Test("ages read short enough for a menu bar")
    func ageText() {
        #expect(MenuBarLabel.ageText(0) == "0s ago")
        #expect(MenuBarLabel.ageText(-5) == "0s ago")
        #expect(MenuBarLabel.ageText(59) == "59s ago")
        #expect(MenuBarLabel.ageText(60) == "1m ago")
        #expect(MenuBarLabel.ageText(4 * 60 + 30) == "4m ago")
        #expect(MenuBarLabel.ageText(3600) == "1h ago")
        #expect(MenuBarLabel.ageText(47 * 3600) == "47h ago")
        #expect(MenuBarLabel.ageText(48 * 3600) == "2d ago")
    }

    @Test("no reading at all shows a question mark, not numbers")
    func noReading() {
        #expect(MenuBarLabel.make(account: "perso2", snapshot: nil).text == "perso2 ?")
        #expect(MenuBarLabel.make(account: "perso2", snapshot: nil, age: 90).text == "perso2 ?")
        #expect(MenuBarLabel.make(account: "perso2", snapshot: nil).tone == .normal)
        #expect(MenuBarLabel.noAccount.text == "no account")
    }

    @Test("the recorded response renders the expected label")
    func realResponse() throws {
        let snapshot = try UsageDecoder.decode(try Fixture.usageResponse())
        let label = MenuBarLabel.make(account: "perso2", snapshot: snapshot)
        #expect(label.text == "perso2 5h 17% wk 69% ⊘Fable")
        // Session and weekly were both `normal`; only the Fable limit was critical.
        #expect(label.tone == .normal)
        #expect(label.toneSource == .severity)
    }
}
