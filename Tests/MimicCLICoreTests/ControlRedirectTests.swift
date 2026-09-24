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

@Suite("Control client redirects")
struct ControlRedirectTests {
    private static let token = "literal-control-token"

    @Test("A command never follows a redirect with its token", arguments: [302, 307])
    func commandRedirect(status: Int) async throws {
        let destination = try OneRequestServer(body: #"{"ok":true,"result":{}}"#)
        let source = try OneRequestServer(redirect: status, to: destination.url)
        defer { source.stop(); destination.stop() }

        let client = ControlClient(baseURL: source.url, timeout: 3, token: Self.token)
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

    @Test("A health check never follows a redirect with its token", arguments: [302, 307])
    func healthRedirect(status: Int) async throws {
        let destination = try OneRequestServer(body: "healthy")
        let source = try OneRequestServer(redirect: status, to: destination.url)
        defer { source.stop(); destination.stop() }

        let client = ControlClient(baseURL: source.url, timeout: 3, token: Self.token)
        #expect(await client.isReachable() == false)
        #expect(source.request?.contains("X-Mimic-Token: \(Self.token)") == true)
        #expect(destination.request == nil, "The destination received a redirected health check")
    }
}

/// A disposable real HTTP listener. The second listener records any redirected request, including
/// its headers. Injecting ControlHTTPExchange would skip URLSession's redirect handling entirely.
private final class OneRequestServer: @unchecked Sendable {
    enum Failure: Error { case socket, bind, address, listen }

    let url: URL
    private let listener: Int32
    private let response: String
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var recordedRequest: String?

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

    private init(status: Int, headers: [String], body: String) throws {
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
        self.response = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Redirect")\r\n"
            + (headers + ["Content-Length: \(body.utf8.count)", "Connection: close"])
                .joined(separator: "\r\n")
            + "\r\n\r\n" + body

        group.enter()
        DispatchQueue.global().async { [self] in
            defer { group.leave() }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { return }
            defer { Self.closeSocket(connection) }

            var buffer = [UInt8](repeating: 0, count: 4_096)
            let count = buffer.withUnsafeMutableBytes { bytes in
                Self.receive(connection, bytes.baseAddress!, bytes.count)
            }
            guard count > 0 else { return }
            lock.lock()
            recordedRequest = String(decoding: buffer.prefix(count), as: UTF8.self)
            lock.unlock()

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

    func stop() {
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
        group.wait()
        Self.closeSocket(listener)
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
        Glibc.send(socket, buffer, count, 0)
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
