import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif

/// A deliberately dumb HTTP/1.1 client: one connection, one request, read until the server closes.
///
/// `URLSession` is the wrong instrument for asserting on transport failures — it transparently
/// retries failed idempotent requests, so a dropped connection can silently become a second request
/// and a successful response. This client makes exactly one request and reports exactly what came
/// back, which is what a test about torn connections needs to observe.
enum RawHTTPClient {

    struct Response {
        let raw: String
        /// `true` when the server closed without completing the message — no terminating chunk for a
        /// chunked body, and no complete body for a declared length.
        let isTruncated: Bool
        /// Nothing at all arrived before the read deadline.
        let isEmpty: Bool
        /// Whether the peer actually closed the connection, rather than the read timing out.
        let didClose: Bool

        var statusLine: String {
            raw.split(separator: "\r\n", maxSplits: 1).first.map(String.init) ?? ""
        }
    }

    /// Sends `method path` and reads until EOF or `timeout`, whichever comes first.
    static func send(
        method: String,
        path: String,
        port: Int,
        additionalHeaders: [(String, String)] = [],
        bodyPrefix: Data = Data(),
        timeout: TimeInterval = 5
    ) throws -> Response {
        let socketFD = try open(method: method, path: path, port: port,
            additionalHeaders: additionalHeaders, bodyPrefix: bodyPrefix, connection: "close")
        defer { PlatformSocket.close(socketFD) }
        return receive(on: socketFD, timeout: timeout)
    }

    /// Leaves an incomplete upload connected so a wire test can inspect the server's deadline.
    /// The caller owns and must close the returned descriptor.
    static func open(
        method: String,
        path: String,
        port: Int,
        additionalHeaders: [(String, String)] = [],
        bodyPrefix: Data = Data(),
        connection: String = "keep-alive"
    ) throws -> Int32 {
        let socketFD = PlatformSocket.make()
        guard socketFD >= 0 else { throw Failure.socketUnavailable }
        do {
            var address = PlatformSocket.loopbackAddress(port: UInt16(port))
            let connected = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    PlatformSocket.connect(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connected == 0 else { throw Failure.connectFailed(errno) }

            let extraLines = additionalHeaders.map { "\($0.0): \($0.1)\r\n" }.joined()
            let request = "\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: \(connection)\r\n\(extraLines)\r\n"
            try request.withCString { pointer in
                var remaining = strlen(pointer)
                var cursor = pointer
                while remaining > 0 {
                    let written = PlatformSocket.send(socketFD, cursor, remaining)
                    guard written > 0 else { throw Failure.writeFailed(errno) }
                    cursor = cursor.advanced(by: written)
                    remaining -= written
                }
            }
            try bodyPrefix.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var remaining = raw.count
                var cursor = base
                while remaining > 0 {
                    let written = PlatformSocket.send(socketFD, cursor, remaining)
                    guard written > 0 else { throw Failure.writeFailed(errno) }
                    cursor = cursor.advanced(by: written)
                    remaining -= written
                }
            }

            return socketFD
        } catch {
            PlatformSocket.close(socketFD)
            throw error
        }
    }

    /// Reads a response on a socket kept open by `open`. The caller still owns the descriptor.
    static func receive(on socketFD: Int32, timeout: TimeInterval) -> Response {
        PlatformSocket.setReceiveTimeout(socketFD, seconds: timeout)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var closedCleanly = false
        while true {
            let count = PlatformSocket.receive(socketFD, &buffer, buffer.count)
            if count > 0 {
                received.append(contentsOf: buffer[0..<count])
                continue
            }
            // 0 == orderly shutdown; negative == error or the receive timeout elapsed.
            closedCleanly = count == 0
            break
        }

        let raw = String(decoding: received, as: UTF8.self)
        return Response(
            raw: raw,
            isTruncated: closedCleanly && !isComplete(raw),
            isEmpty: received.isEmpty,
            didClose: closedCleanly
        )
    }

    /// A chunked message ends with a zero-length chunk; a length-declared message ends when the body
    /// reaches `Content-Length`. Anything else is a message the server abandoned.
    private static func isComplete(_ raw: String) -> Bool {
        guard let separator = raw.range(of: "\r\n\r\n") else { return false }
        let head = raw[raw.startIndex..<separator.lowerBound].lowercased()
        let body = String(raw[separator.upperBound...])

        if head.contains("transfer-encoding: chunked") {
            return body.hasSuffix("0\r\n\r\n")
        }
        if let range = head.range(of: "content-length:") {
            let value = head[range.upperBound...]
                .prefix { $0 != "\r" }
                .trimmingCharacters(in: .whitespaces)
            return body.utf8.count >= (Int(value) ?? 0)
        }
        return true
    }

    enum Failure: Error {
        case socketUnavailable
        case connectFailed(Int32)
        case writeFailed(Int32)
    }
}
