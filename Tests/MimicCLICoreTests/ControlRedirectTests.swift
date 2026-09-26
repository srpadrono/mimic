import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Testing
import Domain
@testable import MimicCLICore

@Suite("Control client redirects", .timeLimit(.minutes(1)))
struct ControlRedirectTests {
    private static let token = "literal-control-token"

    @Test("A command never follows a redirect with its token", arguments: [301, 302, 303, 307, 308])
    func commandRedirect(status: Int) async throws {
        let destination = try OneRequestServer(body: #"{"ok":true,"result":{}}"#)
        let source = try OneRequestServer(redirect: status, to: destination.url)
        defer { source.stop(); destination.stop() }

        let client = try ControlClient(baseURL: source.url, timeout: 3, token: Self.token)
        do {
            _ = try await client.send(.ping)
            Issue.record("A redirected control reply was accepted")
        } catch let failure as CLIFailure {
            guard case let .commandFailed(error) = failure else {
                Issue.record("Expected the original HTTP redirect, got \(failure)")
                return
            }
            #expect(error.code == "http.\(status)")
        }

        #expect(source.request?.contains("X-Mimic-Token: \(Self.token)") == true)
        #expect(destination.request == nil, "The destination received a redirected control request")
    }

    @Test("A health check never follows a redirect with its token", arguments: [301, 302, 303, 307, 308])
    func healthRedirect(status: Int) async throws {
        let destination = try OneRequestServer(body: "healthy")
        let source = try OneRequestServer(redirect: status, to: destination.url)
        defer { source.stop(); destination.stop() }

        let client = try ControlClient(baseURL: source.url, timeout: 3, token: Self.token)
        #expect(await client.isReachable() == false)
        #expect(source.request?.contains("X-Mimic-Token: \(Self.token)") == true)
        #expect(destination.request == nil, "The destination received a redirected health check")
    }

    @Test("Cancelling a command interrupts a real pending HTTP exchange")
    func cancellationStopsPendingRequest() async throws {
        let server = try OneRequestServer(holdsResponse: true)
        defer { server.stop() }
        let client = try ControlClient(baseURL: server.url, timeout: 5, token: Self.token)
        let task = Task { try await client.send(.ping) }
        defer { task.cancel() }
        let received = await server.waitForRequest()
        #expect(received, "The literal HTTP request did not reach the disposable listener")
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(server.request?.contains("X-Mimic-Token: literal-control-token") == true)
    }

    @Test("A health check respects a subsecond client timeout against a stalled listener")
    func healthTimeoutIsBounded() async throws {
        let server = try OneRequestServer(holdsResponse: true)
        defer { server.stop() }
        let client = try ControlClient(baseURL: server.url, timeout: 0.2)
        let start = ContinuousClock.now
        #expect(await client.isReachable() == false)
        #expect(start.duration(to: .now) < .seconds(1.5))
        #expect(server.request?.hasPrefix("GET /v1/health HTTP/1.1\r\n") == true)
    }
}

/// A disposable real HTTP listener. The second listener records any redirected request, including
/// its headers. Injecting ControlHTTPExchange would skip URLSession's redirect handling entirely.
private final class OneRequestServer: @unchecked Sendable {
    enum Failure: Error { case socket, bind, address, listen, options }

    let url: URL
    private let listener: Int32
    private let response: String?
    private let group = DispatchGroup()
    private let requestReady = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var recordedRequest: String?
    private var activeConnection: Int32?
    private var stopped = false

    var request: String? {
        lock.lock()
        defer { lock.unlock() }
        return recordedRequest
    }

    convenience init(body: String) throws {
        try self.init(status: 200, headers: [], body: body)
    }

    convenience init(redirect status: Int, to destination: URL) throws {
        try self.init(status: status, headers: ["Location: \(destination.absoluteString)"], body: "")
    }

    convenience init(holdsResponse: Bool) throws {
        try self.init(status: 200, headers: [], body: "", responds: !holdsResponse)
    }

    private init(status: Int, headers: [String], body: String, responds: Bool = true) throws {
        let descriptor = Self.makeSocket()
        guard descriptor >= 0 else { throw Failure.socket }

        var address = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Self.bindSocket(descriptor, $0)
            }
        }
        guard bound == 0 else { Self.closeSocket(descriptor); throw Failure.bind }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0 else { Self.closeSocket(descriptor); throw Failure.address }
        guard listen(descriptor, 1) == 0 else { Self.closeSocket(descriptor); throw Failure.listen }

        let port = UInt16(bigEndian: actual.sin_port)
        self.url = URL(string: "http://127.0.0.1:\(port)")!
        self.listener = descriptor
        let reply = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Redirect")\r\n"
            + (headers + ["Content-Length: \(body.utf8.count)", "Connection: close"])
                .joined(separator: "\r\n")
            + "\r\n\r\n" + body
        self.response = responds ? reply : nil

        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            guard begin(connection) else { Self.closeSocket(connection); return }
            defer { finish(connection) }
            do {
                try Self.configure(connection)
            } catch {
                Issue.record("Could not configure the disposable listener: \(error)")
                return
            }
            guard let request = Self.readRequest(connection) else { return }
            lock.lock()
            recordedRequest = request
            lock.unlock()
            requestReady.signal()

            guard let response else {
                // The timeout/cancellation fixtures keep the connection open until the client
                // closes it, with a socket timeout as a fallback and stop() able to interrupt it.
                var byte: UInt8 = 0
                _ = Self.receive(connection, &byte, 1)
                return
            }

            let bytes = Array(response.utf8)
            bytes.withUnsafeBytes { raw in
                var sent = 0
                while sent < raw.count {
                    let count = Self.sendBytes(connection, raw.baseAddress!.advanced(by: sent), raw.count - sent)
                    guard count > 0 else { break }
                    sent += count
                }
            }
        }
    }

    func waitForRequest() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { [self] in
                continuation.resume(returning: requestReady.wait(timeout: .now() + 3) == .success)
            }
        }
    }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        if let activeConnection { Self.shutdownSocket(activeConnection) }
        lock.unlock()
        // Wake a destination listener that correctly received no redirected request.
        let wake = Self.makeSocket()
        if wake >= 0 {
            var address = Self.loopback(port: UInt16(url.port!))
            withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = Self.connectSocket(wake, $0)
                }
            }
            Self.closeSocket(wake)
        }
        if group.wait(timeout: .now() + 5) != .success {
            Issue.record("The disposable HTTP listener did not stop within five seconds")
        }
        Self.shutdownSocket(listener)
        Self.closeSocket(listener)
    }

    private func begin(_ connection: Int32) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !stopped else { return false }
        activeConnection = connection
        return true
    }

    private func finish(_ connection: Int32) {
        lock.lock()
        defer { lock.unlock() }
        activeConnection = nil
        Self.closeSocket(connection)
    }

    private static func configure(_ socket: Int32) throws {
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        for option in [SO_RCVTIMEO, SO_SNDTIMEO] {
            guard setsockopt(socket, SOL_SOCKET, option, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
                throw Failure.options
            }
        }
        #if canImport(Darwin)
        var enabled: Int32 = 1
        guard setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw Failure.options
        }
        #endif
    }

    /// URLSession knows each test request's Data body length. Read that complete request across
    /// arbitrary TCP chunks before responding; one recv can stop halfway through a header or body.
    private static func readRequest(_ socket: Int32) -> String? {
        let limit = 65_536
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        var request = Data()
        var expectedCount: Int?
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while request.count < limit, ContinuousClock.now < deadline {
            let received = buffer.withUnsafeMutableBytes { bytes in
                Self.receive(socket, bytes.baseAddress!, min(bytes.count, limit - request.count))
            }
            guard received > 0 else { return nil }
            request.append(contentsOf: buffer.prefix(received))
            if expectedCount == nil, let separator = request.range(of: Data("\r\n\r\n".utf8)) {
                let headers = String(decoding: request[..<separator.lowerBound], as: UTF8.self)
                let lengthHeader = headers.components(separatedBy: "\r\n").dropFirst().first {
                    $0.split(separator: ":", maxSplits: 1).first?.lowercased() == "content-length"
                }
                let bodyCount: Int
                if let lengthHeader {
                    let fields = lengthHeader.split(separator: ":", maxSplits: 1)
                    guard fields.count == 2, let value = Int(fields[1]
                        .trimmingCharacters(in: .whitespaces)), value >= 0 else { return nil }
                    bodyCount = value
                } else {
                    bodyCount = 0
                }
                guard bodyCount <= limit - separator.upperBound else { return nil }
                expectedCount = separator.upperBound + bodyCount
            }
            if let expectedCount, request.count >= expectedCount {
                return String(decoding: request.prefix(expectedCount), as: UTF8.self)
            }
        }
        return nil
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return address
    }

    private static func makeSocket() -> Int32 {
        #if canImport(Darwin)
        Darwin.socket(AF_INET, SOCK_STREAM, 0)
        #else
        Glibc.socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
    }

    private static func bindSocket(_ socket: Int32, _ address: UnsafePointer<sockaddr>) -> Int32 {
        #if canImport(Darwin)
        Darwin.bind(socket, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        #else
        Glibc.bind(socket, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
    }

    private static func connectSocket(_ socket: Int32, _ address: UnsafePointer<sockaddr>) -> Int32 {
        #if canImport(Darwin)
        Darwin.connect(socket, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        #else
        Glibc.connect(socket, address, socklen_t(MemoryLayout<sockaddr_in>.size))
        #endif
    }

    private static func receive(_ socket: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.recv(socket, buffer, count, 0)
        #else
        Glibc.recv(socket, buffer, count, 0)
        #endif
    }

    private static func sendBytes(_ socket: Int32, _ buffer: UnsafeRawPointer, _ count: Int) -> Int {
        #if canImport(Darwin)
        Darwin.send(socket, buffer, count, 0)
        #else
        Glibc.send(socket, buffer, count, Int32(MSG_NOSIGNAL))
        #endif
    }

    private static func shutdownSocket(_ socket: Int32) {
        #if canImport(Darwin)
        _ = Darwin.shutdown(socket, SHUT_RDWR)
        #else
        _ = Glibc.shutdown(socket, Int32(SHUT_RDWR))
        #endif
    }

    private static func closeSocket(_ socket: Int32) {
        #if canImport(Darwin)
        _ = Darwin.close(socket)
        #else
        _ = Glibc.close(socket)
        #endif
    }
}
