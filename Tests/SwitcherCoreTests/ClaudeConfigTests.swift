import Foundation
import Testing
@testable import SwitcherCore

/// A switch has business with one key of `~/.claude.json`; these tests are about the others.
@Suite("Claude config")
struct ClaudeConfigTests {
    static let document = Data("""
    {
      "numStartups": 8,
      "tip": "a } and a \\" and a , inside a string",
      "oauthAccount": {"emailAddress": "old@example.com", "nested": {"a": [1, 2, {"b": "}"}]}},
      "float": 0.5,
      "big": 1758123456789,
      "trailing": null
    }
    """.utf8)

    @Test("the span of one top-level value is found past braces hiding in strings")
    func findsTheValue() throws {
        let range = try JSONSplice.valueRange(of: "oauthAccount", in: Self.document)
        let text = String(data: Self.document.subdata(in: range), encoding: .utf8)
        #expect(text?.hasPrefix("{\"emailAddress\"") == true)
        #expect(text?.hasSuffix("[1, 2, {\"b\": \"}\"}]}}") == true)

        #expect(try JSONSplice.valueRange(of: "numStartups", in: Self.document).count == 1)
        #expect(try JSONSplice.valueRange(of: "float", in: Self.document).count == 3)
        #expect(try JSONSplice.valueRange(of: "trailing", in: Self.document).count == 4)
        #expect(throws: JSONSplice.SpliceError.keyNotFound("nope")) {
            try JSONSplice.valueRange(of: "nope", in: Self.document)
        }
    }

    @Test("replacing a value leaves every other byte exactly where it was")
    func replaceKeepsTheRest() throws {
        let replaced = try JSONSplice.replace("oauthAccount", in: Self.document,
                                              with: Data(#"{"emailAddress":"new@example.com"}"#.utf8))
        let text = try #require(String(data: replaced, encoding: .utf8))
        #expect(text.contains("  \"numStartups\": 8,\n"))
        #expect(text.contains("\"big\": 1758123456789"))
        #expect(text.contains("\"float\": 0.5"))
        #expect(text.contains("a } and a \\\" and a , inside a string"))
        #expect(text.contains("old@example.com") == false)
        let json = try #require(try JSONSerialization.jsonObject(with: replaced) as? [String: Any])
        #expect(json.count == 6)
    }

    @Test("a document that is not an object, or is cut off, is refused")
    func refusesRubbish() {
        #expect(throws: JSONSplice.SpliceError.notAnObject) {
            try JSONSplice.valueRange(of: "a", in: Data("[1,2]".utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONSplice.valueRange(of: "a", in: Data(#"{"a": {"b": "#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONSplice.valueRange(of: "a", in: Data(#"{"a" 1}"#.utf8))
        }
    }

    @Test("the config is written atomically, 0600, and read back before it counts")
    func writesAndVerifies() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".claude.json")
        try Self.document.write(to: url)
        let config = ClaudeConfig(url: url)

        try config.replaceOAuthAccount(with: Data(#"{"emailAddress":"new@example.com"}"#.utf8),
                                       in: Self.document)
        let account = try #require(config.decodedAccount(in: try Data(contentsOf: url)))
        #expect(account.emailAddress == "new@example.com")

        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == 0o600)
        let stragglers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.contains(".new.") }
        #expect(stragglers.isEmpty)

        #expect(throws: (any Error).self) {
            try config.replaceOAuthAccount(with: Data("\"nope\"".utf8), in: Self.document)
        }
    }

    @Test("a config with no oauthAccount at all gets one")
    func addsTheKey() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".claude.json")
        let original = Data(#"{"numStartups":1}"#.utf8)
        try original.write(to: url)

        let config = ClaudeConfig(url: url)
        try config.replaceOAuthAccount(with: Data(#"{"emailAddress":"new@example.com"}"#.utf8),
                                       in: original)
        let json = try #require(try JSONSerialization.jsonObject(with: try Data(contentsOf: url))
            as? [String: Any])
        #expect(json["numStartups"] as? Int == 1)
        #expect((json["oauthAccount"] as? [String: Any])?["emailAddress"] as? String == "new@example.com")
    }

    @Test("backups keep the newest ten and two in one second do not collide")
    func backupsAndPruning() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-config-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent(".claude.json")
        try Self.document.write(to: url)
        let config = ClaudeConfig(url: url)
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try config.backup(Data("one".utf8), now: now)
        let second = try config.backup(Data("two".utf8), now: now)
        #expect(first != second)
        #expect(second.lastPathComponent.hasSuffix("-1"))
        #expect(try String(contentsOf: first, encoding: .utf8) == "one")

        for day in 1...12 {
            try Data("old".utf8).write(to: directory
                .appendingPathComponent(".claude.json.bak.202609\(String(format: "%02d", day))000000"))
        }
        #expect(config.backups().count == 14)
        let removed = config.pruneBackups(keeping: 10)
        #expect(removed.count == 4)
        let kept = config.backups().map(\.lastPathComponent)
        #expect(kept.count == 10)
        #expect(kept.contains(".claude.json.bak.20260912000000"))
        #expect(kept.contains(".claude.json.bak.20260901000000") == false)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
