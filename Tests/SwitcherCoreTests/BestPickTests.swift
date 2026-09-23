import Foundation
import Testing
@testable import SwitcherCore

@Suite("Best pick")
struct BestPickTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)
    static func inHours(_ hours: Double) -> Date { now.addingTimeInterval(hours * 3600) }

    @Test("97% used is still usable, and the week that ends first is milked first")
    func nearlyEmptyButSoonestWins() {
        let nearlyDone = PolicyAccount(name: "perso", order: 0, sessionPercent: 40, weeklyPercent: 97,
                                       weeklyResetsAt: Self.inHours(20))
        let fresh = PolicyAccount(name: "pro", order: 1, sessionPercent: 0, weeklyPercent: 0,
                                  weeklyResetsAt: Self.inHours(150))
        let pick = BestPick.choose([fresh, nearlyDone], now: Self.now)
        #expect(pick?.name == "perso")
        #expect(pick?.weeklyResetsAt == Self.inHours(20))
    }

    @Test("a used-up window closes the account, whatever its reset")
    func usedUpIsClosed() {
        let sessionOut = PolicyAccount(name: "a", sessionPercent: 100, weeklyPercent: 50,
                                       weeklyResetsAt: Self.inHours(1))
        let weekOut = PolicyAccount(name: "b", order: 1, sessionPercent: 10, weeklyPercent: 100,
                                    weeklyResetsAt: Self.inHours(2))
        let open = PolicyAccount(name: "c", order: 2, sessionPercent: 90, weeklyPercent: 99,
                                 weeklyResetsAt: Self.inHours(100))
        #expect(BestPick.choose([sessionOut, weekOut, open], now: Self.now)?.name == "c")
        #expect(BestPick.choose([sessionOut, weekOut], now: Self.now) == nil)
    }

    @Test("no reading, dead credentials, or nothing at all: no pick")
    func nothingToPickFrom() {
        let unread = PolicyAccount(name: "unread")
        let dead = PolicyAccount(name: "dead", sessionPercent: 0, weeklyPercent: 0, isUsable: false)
        #expect(BestPick.choose([unread, dead], now: Self.now) == nil)
        #expect(BestPick.choose([], now: Self.now) == nil)

        let read = PolicyAccount(name: "read", order: 2, sessionPercent: 50)
        #expect(BestPick.choose([unread, dead, read], now: Self.now)?.name == "read")
    }

    @Test("an unknown reset counts as a week away")
    func unknownResetIsFar() {
        let unknown = PolicyAccount(name: "unknown", order: 0, sessionPercent: 0, weeklyPercent: 10)
        let known = PolicyAccount(name: "known", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                  weeklyResetsAt: Self.inHours(167))
        #expect(BestPick.choose([unknown, known], now: Self.now)?.name == "known")

        let farther = PolicyAccount(name: "farther", order: 1, sessionPercent: 0, weeklyPercent: 10,
                                    weeklyResetsAt: Self.inHours(169))
        #expect(BestPick.choose([unknown, farther], now: Self.now)?.name == "unknown")
    }

    @Test("same reset: the one with less left is finished first, then the listed order")
    func tieBreaks() {
        let more = PolicyAccount(name: "more", order: 0, sessionPercent: 0, weeklyPercent: 20,
                                 weeklyResetsAt: Self.inHours(30))
        let less = PolicyAccount(name: "less", order: 1, sessionPercent: 0, weeklyPercent: 80,
                                 weeklyResetsAt: Self.inHours(30))
        #expect(BestPick.choose([more, less], now: Self.now)?.name == "less")

        let second = PolicyAccount(name: "second", order: 2, sessionPercent: 0, weeklyPercent: 80,
                                   weeklyResetsAt: Self.inHours(30))
        let first = PolicyAccount(name: "first", order: 1, sessionPercent: 0, weeklyPercent: 80,
                                  weeklyResetsAt: Self.inHours(30))
        #expect(BestPick.choose([second, first], now: Self.now)?.name == "first")
    }

    @Test("the live account can be the pick")
    func liveCanWin() {
        let live = PolicyAccount(name: "live", order: 0, sessionPercent: 30, weeklyPercent: 50,
                                 weeklyResetsAt: Self.inHours(10))
        let other = PolicyAccount(name: "other", order: 1, sessionPercent: 0, weeklyPercent: 0,
                                  weeklyResetsAt: Self.inHours(100))
        #expect(BestPick.choose([live, other], now: Self.now)?.name == "live")
    }
}
