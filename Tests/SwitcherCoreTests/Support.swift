import Foundation
import Testing
@testable import SwitcherCore

enum Fixture {
    static func data(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json",
                                                 subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// A real 200 response, redacted.
    static func usageResponse() throws -> Data { try data("usage-response") }
}

/// Serves canned replies; nothing in the test suite touches the network.  State is keyed
/// by URL path because suites run in parallel; an unarmed path gets a 599.
final class StubProtocol: URLProtocol {
    struct Reply: @unchecked Sendable {
        var status: Int = 200
        var body: Data = Data()
        var error: Error?
        /// Held open so a single-flight test can overlap two callers.
        var delay: TimeInterval = 0
    }

    struct Call: @unchecked Sendable {
        var request: URLRequest
        var body: Data
    }

    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var replies: [String: Reply] = [:]
        var calls: [String: [Call]] = [:]
    }

    private static let state = State()

    static func arm(_ reply: Reply, for path: String) {
        state.lock.withLock {
            state.replies[path] = reply
            state.calls[path] = []
        }
    }

    static func calls(for path: String) -> [Call] {
        state.lock.withLock { state.calls[path] ?? [] }
    }

    static func reset(_ path: String) { arm(Reply(status: 599), for: path) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    /// URLSession hands the protocol a body stream, not `httpBody`.
    private static func body(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        defer { buffer.deallocate() }
        while true {
            let read = stream.read(buffer, maxLength: 4096)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let call = Call(request: request, body: Self.body(of: request))
        let reply = Self.state.lock.withLock { () -> Reply in
            Self.state.calls[path, default: []].append(call)
            return Self.state.replies[path] ?? Reply(status: 599)
        }

        let finish = { [weak self] in
            guard let self else { return }
            if let error = reply.error {
                self.client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(url: self.request.url!, statusCode: reply.status,
                                           httpVersion: "HTTP/1.1", headerFields: nil)!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: reply.body)
            self.client?.urlProtocolDidFinishLoading(self)
        }
        if reply.delay > 0 {
            DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: finish)
        } else {
            finish()
        }
    }

    override func stopLoading() {}
}

enum StubPath {
    static let usage = UsageClient.endpoint.path
    static let token = TokenRefresher.defaultEndpoint.path
}

/// An in-memory keychain with injectable faults.
struct FakeKeychain: KeychainReading, KeychainWriting {
    final class Box: @unchecked Sendable {
        var items: [String: Data] = [:]
        var failures: [String: KeychainError] = [:]
        var writeFailures: [String: KeychainError] = [:]
        /// Fails once and then behaves.
        var writeFailuresOnce: [String: KeychainError] = [:]
        /// Accepts the write but stores something else, every time or once.
        var truncateWrites: Set<String> = []
        var truncateWritesOnce: Set<String> = []
        var writes: [(service: String, label: String, bytes: Int)] = []
        var deleteFailures: [String: KeychainError] = [:]
        /// "write:<service>" and "delete:<service>", in the order they happened.
        var operations: [String] = []
    }
    let box = Box()

    func services(withPrefix prefix: String) throws -> [String] {
        box.items.keys.filter { $0.hasPrefix(prefix) }.sorted()
    }

    func data(forService service: String) throws -> Data {
        if let failure = box.failures[service] { throw failure }
        guard let data = box.items[service] else { throw KeychainError.itemNotFound(service) }
        return data
    }

    func write(_ data: Data, service: String, label: String) throws {
        if let failure = box.writeFailuresOnce.removeValue(forKey: service) { throw failure }
        if let failure = box.writeFailures[service] { throw failure }
        box.writes.append((service, label, data.count))
        box.operations.append("write:" + service)
        let truncate = box.truncateWrites.contains(service) || box.truncateWritesOnce.remove(service) != nil
        box.items[service] = truncate ? data.prefix(20) : data
    }

    func delete(service: String) throws {
        if let failure = box.deleteFailures[service] { throw failure }
        box.operations.append("delete:" + service)
        box.items[service] = nil
    }
}

/// A whole switch inside a directory that goes away with the test: a `.claude.json`, an
/// active-login marker and a lock file.
struct TempWorld {
    let directory: URL
    let switcher: Switcher
    let keychain: FakeKeychain

    static let prefix = "CAS Test Login: "
    static let live = "CAS Test Live"

    static func config(email: String = "live@example.com", extras: String = "") -> Data {
        Data("""
        {
          "numStartups": 8,
          "installMethod": "native",
          "oauthAccount": {
            "emailAddress": "\(email)",
            "organizationRateLimitTier": "default_claude_max_20x",
            "accountUuid": "0000-live"
          },
          "mcpServers": {"ssim": {"command": "/usr/bin/env", "args": ["x"]}},
          "autoCompactWindowsCache": 0.5\(extras)
        }
        """.utf8)
    }

    init(activeName: String? = "perso2", items: [String: Data] = [:],
         config: Data? = nil, backupsKept: Int = 10) throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cas-switch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (config ?? Self.config()).write(to: directory.appendingPathComponent(".claude.json"))
        if let activeName {
            try Data((activeName + "\n").utf8)
                .write(to: directory.appendingPathComponent("active-login"))
        }
        keychain = FakeKeychain()
        keychain.box.items = items
        switcher = Switcher(
            reader: keychain, writer: keychain, loginPrefix: Self.prefix, liveService: Self.live,
            paths: Switcher.Paths(config: directory.appendingPathComponent(".claude.json"),
                                  activeLogin: directory.appendingPathComponent("active-login"),
                                  lock: directory.appendingPathComponent("switch.lock"),
                                  backupsKept: backupsKept))
    }

    var configURL: URL { directory.appendingPathComponent(".claude.json") }
    var markerURL: URL { directory.appendingPathComponent("active-login") }

    func configJSON() throws -> [String: Any] {
        let data = try Data(contentsOf: configURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func marker() -> String? {
        try? String(contentsOf: markerURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func backups() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        return names.filter { $0.hasPrefix(".claude.json.bak.") }.sorted()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
