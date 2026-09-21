import Foundation
import Testing
@testable import SwitcherCore

@Suite("Rate limit budget")
struct RateLimitBudgetTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a fresh budget allows the first request")
    func startsOpen() {
        var budget = RateLimitBudget()
        #expect(budget.allows(Self.now))
        budget.recordRequest(at: Self.now)
        #expect(budget.allows(Self.now.addingTimeInterval(29)) == false)
        #expect(budget.allows(Self.now.addingTimeInterval(30)))
    }

    @Test("backoff doubles per 429 and stops at the cap")
    func exponential() {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0.2)
        let waits = (1...6).map { _ -> TimeInterval in
            let until = budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
            return until.timeIntervalSince(Self.now)
        }
        #expect(waits == [120, 240, 480, 900, 900, 900])
        #expect(budget.allows(Self.now.addingTimeInterval(899)) == false)
        #expect(budget.allows(Self.now.addingTimeInterval(901)))
    }

    @Test("jitter only ever adds, and never more than the fraction")
    func jitter() {
        for jitter in [0.0, 0.5, 1.0] {
            var budget = RateLimitBudget(base: 100, cap: 900, jitterFraction: 0.2)
            let wait = budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: jitter)
                .timeIntervalSince(Self.now)
            #expect(wait >= 100)
            #expect(wait <= 120)
            #expect(abs(wait - 100 * (1 + jitter * 0.2)) < 0.001)
        }
    }

    @Test("Retry-After wins when it says something, and 0 says nothing")
    func retryAfter() {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(budget.recordRateLimit(retryAfter: 300, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 300)

        // The endpoint really answers `Retry-After: 0`; the exponential floor applies instead.
        var second = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(second.recordRateLimit(retryAfter: 0, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 120)

        var third = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(third.recordRateLimit(retryAfter: 5, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 120)
    }

    @Test("a success clears the strikes")
    func successResets() {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        #expect(budget.strikes == 2)
        budget.recordSuccess()
        #expect(budget.strikes == 0)
        #expect(budget.allows(Self.now.addingTimeInterval(31)))
        #expect(budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 120)
    }

    @Test("a later 429 never shortens a wait already running")
    func neverShortens() {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        let long = budget.recordRateLimit(retryAfter: 600, now: Self.now, jitter: 0)
        let short = budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        #expect(short == long)
        #expect(budget.waitTime(now: Self.now) == 600)

        budget.recordSuccess()
        #expect(budget.waitTime(now: Self.now.addingTimeInterval(31)) == 0)
    }

    @Test("three accounts share one allowance")
    func sharedAcrossAccounts() {
        var budget = RateLimitBudget(minimumSpacing: 30)
        var clock = Self.now
        var sent = 0
        // Ten passes ten seconds apart: the floor lets one through every 30 s.
        for _ in 0..<10 {
            if budget.allows(clock) {
                budget.recordRequest(at: clock)
                sent += 1
            }
            clock = clock.addingTimeInterval(10)
        }
        #expect(sent == 4)
    }

    @Test("a request stamp never moves the floor backwards")
    func monotonicRequests() {
        var budget = RateLimitBudget(minimumSpacing: 30)
        budget.recordRequest(at: Self.now)
        budget.recordRequest(at: Self.now.addingTimeInterval(-600))
        #expect(budget.lastRequestAt == Self.now)
        #expect(budget.allows(Self.now.addingTimeInterval(29)) == false)
    }

    @Test("a restart keeps the backoff: state round-trips and nonsense is clamped")
    func persistedState() throws {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        budget.recordRequest(at: Self.now)
        budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        let encoded = try JSONEncoder().encode(budget.state)
        let state = try JSONDecoder().decode(RateLimitBudget.State.self, from: encoded)

        var relaunched = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        let later = Self.now.addingTimeInterval(60)
        relaunched.restore(state, now: later)
        #expect(relaunched.strikes == 2)
        #expect(relaunched.waitTime(now: later) == 180)
        // The next 429 is strike three, not a fresh start from the base.
        let third = Self.now.addingTimeInterval(240)
        #expect(relaunched.recordRateLimit(retryAfter: nil, now: third, jitter: 0)
            .timeIntervalSince(third) == 480)

        var clamped = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        clamped.restore(.init(strikes: 1, openUntil: Self.now.addingTimeInterval(86_400),
                              lastRequestAt: Self.now.addingTimeInterval(86_400)), now: Self.now)
        #expect(clamped.waitTime(now: Self.now) == 900)
    }

    @Test("a Retry-After nobody could honour cannot park the app")
    func absurdRetryAfter() {
        // A day-long hint from a middlebox, capped at the longest wait the ladder
        // itself could ask for. Truncating it costs one request, not a burst: if the
        // endpoint is still angry, that request is a 429 and the ladder re-arms.
        var day = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(day.recordRateLimit(retryAfter: 86_400, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 900)
        #expect(day.waitTime(now: Self.now) == 900)

        // `TimeInterval("inf")` and `TimeInterval("nan")` both parse; neither is a wait.
        var infinite = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(infinite.recordRateLimit(retryAfter: .infinity, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 120)
        var notANumber = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0)
        #expect(notANumber.recordRateLimit(retryAfter: .nan, now: Self.now, jitter: 0)
            .timeIntervalSince(Self.now) == 120)
        #expect(notANumber.waitTime(now: Self.now) == 120)
    }

    @Test("a clock that jumped backwards does not lock the app out for good")
    func clockJumpsBackwards() {
        var budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0, minimumSpacing: 30)
        budget.recordRateLimit(retryAfter: nil, now: Self.now, jitter: 0)
        budget.recordRequest(at: Self.now)

        // The machine wakes with its clock an hour behind: both deadlines now sit
        // further ahead than any wait this budget could ever have set.
        let rewound = Self.now.addingTimeInterval(-3600)
        #expect(budget.waitTime(now: rewound) == 0)
        #expect(budget.allows(rewound))
        // A small step back is still a real wait: that deadline is plausible.
        #expect(budget.allows(Self.now.addingTimeInterval(-60)) == false)

        // The next request re-stamps the floor against the clock in force now.
        budget.recordRequest(at: rewound)
        #expect(budget.lastRequestAt == rewound)
        #expect(budget.allows(rewound.addingTimeInterval(29)) == false)
        #expect(budget.allows(rewound.addingTimeInterval(31)))
    }

    @Test("a clock that jumped forwards does not hold the floor open forever")
    func clockJumpsForwards() {
        var budget = RateLimitBudget(minimumSpacing: 30)
        budget.recordRequest(at: Self.now.addingTimeInterval(365 * 86_400))
        // Back on the real clock, that stamp is not a request anybody made.
        budget.recordRequest(at: Self.now)
        #expect(budget.lastRequestAt == Self.now)
        #expect(budget.allows(Self.now.addingTimeInterval(31)))
    }

    @Test("the longest wait is the top of the ladder, whatever it is told")
    func maximumWaitIsTheCeiling() {
        let budget = RateLimitBudget(base: 120, cap: 900, jitterFraction: 0.2)
        #expect(budget.maximumWait == 1080)
        // The floor alone is the ceiling when there is no ladder to speak of.
        #expect(RateLimitBudget(base: 0, cap: 0, jitterFraction: 0,
                                minimumSpacing: 30).maximumWait == 30)
    }
}
