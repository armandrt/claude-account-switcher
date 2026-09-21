import Foundation
import Testing
@testable import SwitcherCore

@Suite("Usage cache")
struct UsageCacheTests {
    static func temporaryCache() -> UsageCache {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-cache-\(UUID().uuidString)")
        return UsageCache(directory: directory)
    }

    @Test("a reading survives a round trip, unknown kinds included")
    func roundTrip() throws {
        let cache = Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.fileURL.deletingLastPathComponent()) }

        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let resets = Date(timeIntervalSince1970: 1_800_010_000)
        let snapshot = UsageSnapshot(
            limits: [
                UsageLimit(kind: .session, group: "session", percent: 25, severity: .normal,
                           resetsAt: resets),
                UsageLimit(kind: .weeklyScoped, percent: 100, severity: .critical,
                           modelDisplayName: "Fable", isActive: true),
                UsageLimit(kind: .unknown("monthly_quartz"), percent: 3),
            ],
            fiveHour: LegacyWindow(utilization: 25, resetsAt: resets),
            sevenDay: LegacyWindow(utilization: 71, resetsAt: resets),
            fetchedAt: fetchedAt,
            notes: ["new limit kind \"monthly_quartz\" — shown as-is"])

        try cache.save(["perso2": snapshot])
        let loaded = cache.load()
        #expect(loaded["perso2"] == snapshot)
        #expect(loaded["perso2"]?.limits.last?.kind == .unknown("monthly_quartz"))
        #expect(loaded["perso2"]?.fetchedAt == fetchedAt)
    }

    @Test("the file is 0600 in a 0700 directory and holds nothing secret")
    func permissionsAndContent() throws {
        let cache = Self.temporaryCache()
        let directoryURL = cache.fileURL.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directoryURL) }

        try cache.save(["perso2": UsageSnapshot(
            limits: [UsageLimit(kind: .weeklyAll, percent: 71, severity: .normal)])])
        try cache.save(["perso2": UsageSnapshot(
            limits: [UsageLimit(kind: .weeklyAll, percent: 72, severity: .normal)])])

        let manager = FileManager.default
        let file = try manager.attributesOfItem(atPath: cache.fileURL.path)
        let directory = try manager.attributesOfItem(atPath: directoryURL.path)
        #expect(file[.posixPermissions] as? NSNumber == 0o600)
        #expect(directory[.posixPermissions] as? NSNumber == 0o700)
        // No temporary left beside the file after a first write or an overwrite.
        #expect(try manager.contentsOfDirectory(atPath: directoryURL.path) == [cache.fileURL.lastPathComponent])

        let text = try String(contentsOf: cache.fileURL, encoding: .utf8).lowercased()
        for forbidden in ["token", "sk-ant", "@", "refresh", "oauth", "uuid"] {
            #expect(text.contains(forbidden) == false, "cache leaked \"\(forbidden)\"")
        }
    }

    @Test("a missing or corrupt cache is a miss, never a crash")
    func toleratesJunk() throws {
        let cache = Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.fileURL.deletingLastPathComponent()) }
        #expect(cache.load().isEmpty)

        try FileManager.default.createDirectory(at: cache.fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("half a fi".utf8).write(to: cache.fileURL)
        #expect(cache.load().isEmpty)

        try cache.save(["a": UsageSnapshot(limits: [])])
        #expect(cache.load()["a"] != nil)
    }

    @Test("a cache written by a later build is a miss, not a wrong number")
    func futureVersion() throws {
        let cache = Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.fileURL.deletingLastPathComponent()) }
        try cache.save(["perso2": UsageSnapshot(
            limits: [UsageLimit(kind: .session, percent: 10, severity: .normal)])])
        #expect(cache.load().count == 1)

        let written = try String(contentsOf: cache.fileURL, encoding: .utf8)
        let text = written
            .replacingOccurrences(of: "\"version\" : \(UsageCache.version)",
                                  with: "\"version\" : \(UsageCache.version + 1)")
            .replacingOccurrences(of: "\"version\":\(UsageCache.version)",
                                  with: "\"version\":\(UsageCache.version + 1)")
        #expect(text != written)
        try Data(text.utf8).write(to: cache.fileURL)
        // The same field names could mean something else by then; question marks are
        // honest and a stale number is not.
        #expect(cache.load().isEmpty)
    }

    @Test("what comes back from disk still obeys the reset rule")
    func cachedReadingsRollOver() throws {
        let cache = Self.temporaryCache()
        defer { try? FileManager.default.removeItem(at: cache.fileURL.deletingLastPathComponent()) }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = UsageSnapshot(limits: [
            UsageLimit(kind: .session, percent: 96, severity: .critical,
                       resetsAt: now.addingTimeInterval(-120)),
            UsageLimit(kind: .weeklyAll, percent: 96, severity: .critical,
                       resetsAt: now.addingTimeInterval(-8 * 86_400)),
        ], fetchedAt: now.addingTimeInterval(-9 * 86_400))
        try cache.save(["perso": snapshot])

        // The file keeps the reading as it was taken; the rolling happens on the way out.
        #expect(cache.load()["perso"] == snapshot)
        let rolled = try #require(cache.load()["perso"]).asOf(now)
        #expect(rolled.sessionPercent == 0)      // rolled over two minutes ago
        #expect(rolled.weeklyPercent == nil)     // rolled over eight days ago: unknown
    }
}
