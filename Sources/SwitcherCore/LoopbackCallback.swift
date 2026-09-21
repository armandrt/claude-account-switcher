import Darwin
import Foundation

/// One-shot loopback HTTP listener that catches the OAuth redirect.
///
/// Binds 127.0.0.1 only, answers the one request whose path and `state` match,
/// and closes. BSD sockets rather than a framework, so nothing prompts.
/// `start()` runs on the caller's thread; `wait()` blocks on a background one.
///
/// One listener serves one sign-in: once a wait has ended, `start()` and
/// `wait()` refuse rather than bind a second, different port behind a
/// `redirect_uri` the browser already holds.
public final class LoopbackCallback: @unchecked Sendable {
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case portTaken(Int)
        case cannotListen(String)
        case timedOut(TimeInterval)
        case cancelled
        /// This listener has already served its sign-in, or another thread is on it.
        case finished

        public var description: String {
            switch self {
            case .portTaken(let port):
                return "nothing could listen on localhost"
                    + (port > 0 ? " port \(port): it is already in use" : ": every port was refused")
            case .cannotListen(let why): return "could not listen on localhost: \(why)"
            case .timedOut(let seconds):
                return "the browser did not come back within \(Int(seconds / 60)) minutes"
            case .cancelled: return "cancelled"
            case .finished: return "that sign-in's listener is closed — start the sign-in again"
            }
        }
    }

    /// What the query string carried: a code, or a refusal.
    public struct Result: Equatable, Sendable {
        public var code: String?
        public var state: String?
        public var error: String?
        public var errorDescription: String?

        public init(code: String? = nil, state: String? = nil,
                    error: String? = nil, errorDescription: String? = nil) {
            self.code = code
            self.state = state
            self.error = error
            self.errorDescription = errorDescription
        }
    }

    /// 0 lets the OS pick, as Claude Code does; the registration accepts any loopback port.
    public let requestedPort: Int
    public let path: String
    public let timeout: TimeInterval
    /// Only a callback echoing this state ends the wait; anything else gets a 404.
    public let expectedState: String?
    /// The port the OS gave us, known once `start()` has run.
    public private(set) var port: Int = 0

    /// A browser that connects and sends nothing must not hold the wait open.
    static let firstByteTimeout: TimeInterval = 2
    /// Once bytes are arriving, a request line may still span several segments.
    static let requestTimeout: TimeInterval = 5
    static let maxRequestBytes = 65536

    private let lock = NSLock()
    private var listener: Int32 = -1
    private var cancelled = false
    private var waiting = false
    private var finished = false

    public init(port: Int = 0, path: String = "/callback", expectedState: String? = nil,
                timeout: TimeInterval = 300) {
        self.requestedPort = port
        self.path = path
        self.expectedState = expectedState
        self.timeout = timeout
    }

    deinit { closeListener() }

    /// Binds and listens. The port it returns goes into the `redirect_uri`.
    @discardableResult
    public func start() throws -> Int {
        try lock.withLock {
            if finished { throw Failure.finished }
            if listener < 0 { listener = try bind() }
            return port
        }
    }

    /// Asks the waiting thread to give up. Safe from any thread; the waiting
    /// thread closes the socket itself, so nothing polls a dead descriptor.
    public func cancel() {
        lock.withLock { cancelled = true }
    }

    private var isCancelled: Bool { lock.withLock { cancelled } }

    private func closeListener() {
        lock.withLock {
            if listener >= 0 { close(listener) }
            listener = -1
        }
    }

    /// Blocks until the browser comes back, the timeout passes or `cancel()` is
    /// called. A refused consent is returned as `error`, not thrown.
    public func wait() throws -> Result {
        let listener = try lock.withLock { () -> Int32 in
            if finished || waiting { throw Failure.finished }
            if cancelled { throw Failure.cancelled }
            if self.listener < 0 { self.listener = try bind() }
            waiting = true
            return self.listener
        }
        defer {
            lock.withLock { waiting = false; finished = true }
            closeListener()
        }
        let deadline = Date().addingTimeInterval(timeout)

        while true {
            if isCancelled { throw Failure.cancelled }
            guard Date() < deadline else { throw Failure.timedOut(timeout) }

            switch Self.readiness(of: listener, milliseconds: 1000) {
            case .timeout, .interrupted: continue
            case .error(let code): throw Failure.cannotListen("poll(): \(code)")
            case .ready: break
            }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else {
                let code = errno
                if code == EINTR || code == ECONNABORTED || code == EAGAIN { continue }
                throw Failure.cannotListen("accept(): \(code)")
            }
            defer { close(connection) }
            Self.setCloseOnExec(connection)
            var one: Int32 = 1
            setsockopt(connection, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

            guard let result = Self.parse(request: readRequest(connection), expectedPath: path),
                  Self.accepts(result, expectedState: expectedState) else {
                Self.send(connection, "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                continue
            }
            Self.send(connection, Self.page(for: result))
            return result
        }
    }

    private func bind() throws -> Int32 {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw Failure.cannotListen("socket(): \(errno)") }
        // The app spawns `security`; without this the child would inherit the
        // listening socket and could hold the port open after we let go of it.
        Self.setCloseOnExec(handle)
        // Non-blocking: `accept` can otherwise block after poll() said ready,
        // when the peer resets in between, and `cancel()` would go unnoticed.
        _ = fcntl(handle, F_SETFL, fcntl(handle, F_GETFL, 0) | O_NONBLOCK)

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(truncatingIfNeeded: requestedPort).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")   // never INADDR_ANY

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            close(handle)
            throw code == EADDRINUSE ? Failure.portTaken(requestedPort) : Failure.cannotListen("bind(): \(code)")
        }
        guard listen(handle, 8) == 0 else {
            let code = errno
            close(handle)
            throw Failure.cannotListen("listen(): \(code)")
        }

        var actual = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &size) }
        }
        guard named == 0 else {
            let code = errno
            close(handle)
            throw Failure.cannotListen("getsockname(): \(code)")
        }
        port = Int(UInt16(bigEndian: actual.sin_port))
        return handle
    }

    /// Reads until the headers end, 64 KB arrive, or the peer goes quiet: a
    /// request line may span segments, and a browser's speculative connection
    /// that never sends a byte must not hold up the real callback behind it.
    private func readRequest(_ connection: Int32) -> String {
        var buffer = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        let began = Date()
        while buffer.count < Self.maxRequestBytes, !Self.hasHeaderEnd(buffer) {
            let allowance = buffer.isEmpty ? Self.firstByteTimeout : Self.requestTimeout
            let left = allowance - Date().timeIntervalSince(began)
            guard left > 0 else { break }
            let readiness = Self.readiness(of: connection,
                                           milliseconds: Int32((min(left, 5) * 1000).rounded()))
            if case .interrupted = readiness { continue }
            guard case .ready = readiness else { break }

            let count = recv(connection, &chunk, chunk.count, 0)
            if count > 0 {
                buffer.append(contentsOf: chunk[0..<count])
                continue
            }
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            break                                   // 0 is EOF, anything else is a dead peer
        }
        return String(decoding: buffer, as: UTF8.self)
    }

    enum Readiness { case ready, timeout, interrupted, error(Int32) }

    /// `poll(2)` rather than `select(2)`: no FD_SETSIZE limit to overrun. EINTR
    /// is its own answer — treating it as a timeout abandons a request mid-flight.
    static func readiness(of descriptor: Int32, milliseconds: Int32,
                          events: Int32 = Int32(POLLIN)) -> Readiness {
        var fds = pollfd(fd: descriptor, events: Int16(events), revents: 0)
        let ready = poll(&fds, 1, milliseconds)
        if ready > 0 { return .ready }
        if ready == 0 { return .timeout }
        return errno == EINTR ? .interrupted : .error(errno)
    }

    static func setCloseOnExec(_ descriptor: Int32) {
        _ = fcntl(descriptor, F_SETFD, fcntl(descriptor, F_GETFD, 0) | FD_CLOEXEC)
    }

    private static func send(_ connection: Int32, _ text: String) {
        let bytes = Array(text.utf8)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBufferPointer {
                Darwin.send(connection, $0.baseAddress, $0.count, 0)
            }
            if count > 0 {
                sent += count
                continue
            }
            guard count < 0, errno == EINTR || errno == EAGAIN else { return }
            if errno == EAGAIN,
               case .error = readiness(of: connection, milliseconds: 500, events: Int32(POLLOUT)) {
                return
            }
        }
    }
}

extension LoopbackCallback {
    /// Scanned as bytes: a 64 KB request would otherwise be decoded to a String
    /// once per segment, and a split UTF-8 sequence decoded over and over.
    static func hasHeaderEnd(_ bytes: [UInt8]) -> Bool {
        guard bytes.count >= 4 else { return false }
        for index in 3..<bytes.count
        where bytes[index] == 0x0a && bytes[index - 1] == 0x0d
            && bytes[index - 2] == 0x0a && bytes[index - 3] == 0x0d {
            return true
        }
        return false
    }

    static func escaped(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// The query of a complete request line for `expectedPath`; nil for anything
    /// else (a favicon request, another path, a line still missing its CRLF).
    public static func parse(request: String, expectedPath: String) -> Result? {
        guard let lineEnd = request.range(of: "\r\n"),
              let target = request[..<lineEnd.lowerBound].split(separator: " ").dropFirst().first,
              let components = URLComponents(string: "http://localhost\(target)"),
              components.path == expectedPath else { return nil }
        let items = components.queryItems ?? []
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        return Result(code: value("code"), state: value("state"),
                      error: value("error"), errorDescription: value("error_description"))
    }

    /// A callback is this sign-in's when it echoes the state, compared in
    /// constant time. A refusal carrying no state at all is accepted too, since
    /// some servers omit it on errors — it carries no code to exchange.
    public static func accepts(_ result: Result, expectedState: String?) -> Bool {
        guard let expectedState else { return true }
        if let state = result.state { return PKCE.equal(state, expectedState) }
        return result.code == nil && result.error != nil
    }

    /// The page the browser lands on. It names no account and echoes nothing
    /// but an escaped error text, because it ends up in the browser's history.
    static func page(for result: Result) -> String {
        let ok = result.code != nil
        let title = ok ? "You are signed in." : "Sign-in did not finish."
        let body = ok
            ? "Close this tab and go back to Claude Account Switcher."
            : escaped(result.errorDescription ?? result.error ?? "No authorization code came back.")
        let html = """
        <!doctype html><meta charset="utf-8"><title>\(title)</title>
        <meta name="referrer" content="no-referrer">
        <style>body{font:15px -apple-system,system-ui,sans-serif;margin:16vh auto;max-width:28em;
        padding:0 1.5em;color:#111}h1{font-size:17px;margin:0 0 .5em}p{color:#555;margin:0}
        @media(prefers-color-scheme:dark){body{background:#1b1b1d;color:#eee}p{color:#aaa}}</style>
        <h1>\(title)</h1><p>\(body)</p>
        """
        return "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
            + "Content-Length: \(html.utf8.count)\r\nCache-Control: no-store\r\n"
            + "Referrer-Policy: no-referrer\r\nConnection: close\r\n\r\n"
            + html
    }
}
