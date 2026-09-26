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
        return receive(on: socketFD, timeout: timeout, method: method)
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
    static func receive(on socketFD: Int32, timeout: TimeInterval, method: String? = nil) -> Response {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        var closedCleanly = false
        while true {
            let remaining = deadline - ProcessInfo.processInfo.systemUptime
            guard remaining > 0 else { break }
            PlatformSocket.setReceiveTimeout(socketFD, seconds: max(remaining, 0.001))
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
            isTruncated: closedCleanly && !isComplete(received, method: method),
            isEmpty: received.isEmpty,
            didClose: closedCleanly
        )
    }

    /// Checks wire framing, not a lossy text rendering. Invalid UTF-8 must not inflate a short
    /// binary body into the advertised byte count. Bodyless responses follow RFC 9112 section 6.3.
    static func isComplete(_ data: Data, method: String? = nil) -> Bool {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let lines = String(decoding: data[..<separator.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let statusParts = (lines.first ?? "").split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else { return false }
        let body = Data(data[separator.upperBound...])
        if (100..<200).contains(status), status != 101 {
            // An informational response must be followed by the final response.
            return isComplete(body, method: method)
        }
        if method?.uppercased() == "HEAD" || status == 101 || status == 204 || status == 304 { return true }

        var headers: [String: [String]] = [:]
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return false }
            headers[parts[0].lowercased(), default: []].append(parts[1].trimmingCharacters(in: .whitespaces))
        }
        if let transfer = headers["transfer-encoding"] {
            let codings = transfer.joined(separator: ",").split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            return codings.last == "chunked" ? completeChunks(body) : true
        }
        if let lengths = headers["content-length"] {
            let values = lengths.flatMap { $0.split(separator: ",", omittingEmptySubsequences: false) }
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = values.first, !first.isEmpty,
                  first.utf8.allSatisfy({ (48...57).contains($0) }),
                  values.allSatisfy({ $0 == first }), let length = Int(first) else { return false }
            return body.count >= length
        }
        return true // Close-delimited response; the caller only asks after EOF.
    }

    private static func completeChunks(_ body: Data) -> Bool {
        let crlf = Data("\r\n".utf8)
        var cursor = body.startIndex
        while let line = body.range(of: crlf, in: cursor..<body.endIndex) {
            let text = String(decoding: body[cursor..<line.lowerBound], as: UTF8.self)
            let sizeText = text.split(separator: ";", maxSplits: 1, omittingEmptySubsequences: false)[0]
                .trimmingCharacters(in: .whitespaces)
            guard !sizeText.isEmpty, sizeText.utf8.allSatisfy({
                (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
            }), let size = Int(sizeText, radix: 16) else { return false }
            cursor = line.upperBound
            if size == 0 {
                // Consume optional trailers through the final empty line.
                while let trailer = body.range(of: crlf, in: cursor..<body.endIndex) {
                    if trailer.lowerBound == cursor { return true }
                    guard body[cursor..<trailer.lowerBound].contains(UInt8(ascii: ":")) else { return false }
                    cursor = trailer.upperBound
                }
                return false
            }
            guard size <= body.endIndex - cursor else { return false }
            cursor += size
            guard body.endIndex - cursor >= 2, body[cursor] == 13, body[cursor + 1] == 10 else { return false }
            cursor += 2
        }
        return false
    }

    enum Failure: Error {
        case socketUnavailable
        case connectFailed(Int32)
        case writeFailed(Int32)
    }
}
