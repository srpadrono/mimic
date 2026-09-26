import AsyncHTTPClient
import Domain
import Foundation
import Vapor

/// Forward bytes with backpressure; keep only a bounded preview for the request log.
enum ProxyForwarder {
    static func target(base: String, requestURI: String) -> URL? {
        // Vapor currently collapses leading slashes on live requests. Also accept direct
        // origin-form input defensively, without parsing its first path segment as an authority.
        let requestTarget = requestURI.hasPrefix("/") ? "http://mimic.invalid" + requestURI : requestURI
        guard var target = URLComponents(string: base),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme),
              target.host != nil, target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil,
              let incoming = URLComponents(string: requestTarget) else { return nil }
        let prefix = target.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = incoming.percentEncodedPath
        target.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix) + (route.hasPrefix("/") ? route : "/" + route)
        target.percentEncodedQuery = incoming.percentEncodedQuery
        return target.url
    }

    static func endToEndHeaders(
        _ source: HTTPHeaders, request: Bool = false, preservingContentLength: Bool = false
    ) -> HTTPHeaders {
        var excluded: Set<String> = ["connection", "keep-alive", "transfer-encoding", "te", "trailer",
            "upgrade", "proxy-authenticate", "proxy-authorization", "proxy-connection"]
        if !preservingContentLength { excluded.insert("content-length") }
        if request { excluded.insert("host") }
        for value in source["connection"] {
            excluded.formUnion(value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        }
        var result = HTTPHeaders()
        for header in source where !excluded.contains(header.name.lowercased()) {
            if EndpointValidator.isValidHeader(name: header.name, value: header.value) {
                result.add(name: header.name, value: header.value)
            }
        }
        return result
    }

    static func forward(
        _ request: Request, to upstreamURL: String, localPorts: Set<Int>,
        incoming: IncomingRequest, projectID: UUID?, backendName: String, listenerPort: Int,
        logContinuation: AsyncStream<RequestLog>.Continuation, logGate: RequestLogGate,
        lease: RequestLogLease
    ) async -> Response {
        let started = ContinuousClock.now
        // The handler acquired this slot before resolving routes. The response writer retains
        // it; if the writer never runs, deinit returns the slot.
        @Sendable func log(status: Int, headers: HTTPHeaders, preview: Data, truncated: Bool, failure: String? = nil) {
            // Streamed responses keep their slot until the last byte or an error. Do not depend
            // on Vapor releasing the response closure promptly on a keep-alive connection.
            defer { lease.release() }
            // A response can publish at most once even if a framework callback is repeated.
            guard lease.transferToConsumer() else { return }
            let (requestBody, requestBodyTruncated) = RequestLog.cappedBody(incoming.body)
            let text = previewText(preview, truncated: truncated)
            let (displayBody, displayTruncated) = RequestLog.cappedBody(text)
            // Only complete UTF-8 text can become a fixture; keep large payloads off the log heap.
            let captured: CapturedResponseBody?
            if !truncated, failure == nil, text != nil, preview.count > RequestLog.maxLoggedBodyBytes,
               ResponseCapture.isTextMediaType(headers.first(name: "content-type") ?? ""),
               headers["content-encoding"].flatMap({ $0.split(separator: ",") })
                .allSatisfy({ $0.trimmingCharacters(in: .whitespaces).lowercased() == "identity" }) {
                captured = try? CapturedResponseFile.capture(preview)
            } else {
                captured = nil
            }
            let elapsed = started.duration(to: .now).components
            let result = logContinuation.yield(RequestLog(
                method: incoming.method, path: request.url.string, backendID: incoming.backendID, projectID: projectID,
                backendName: backendName, listenerPort: listenerPort,
                upstreamURL: target(base: upstreamURL, requestURI: request.url.string)?.absoluteString,
                durationMs: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
                responseBodyIsBinary: text == nil,
                requestHeaders: incoming.headers, requestBody: requestBody, requestBodyTruncated: requestBodyTruncated,
                responseStatusCode: status,
                responseHeaders: Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, last in first + ", " + last }),
                responseBody: displayBody, responseBodyTruncated: truncated || displayTruncated,
                capturedResponseBody: captured,
                failureLabel: failure == nil ? nil : "backend-unavailable", outcome: failure == nil ? .passthrough : .proxyFailure
            ))
            if case .terminated = result {
                Task { await logGate.acknowledge() }
            }
        }
        func failure(_ message: String) -> Response {
            let response = Response(status: .badGateway, body: .init(string: message))
            log(status: 502, headers: response.headers,
                preview: request.method == .HEAD ? Data() : Data(message.utf8), truncated: false, failure: message)
            return response
        }
        guard let url = target(base: upstreamURL, requestURI: request.url.string) else {
            return failure("Invalid real backend URL.")
        }
        if EndpointValidator.isLoopbackHost(url.host ?? ""),
           localPorts.contains(url.port ?? (url.scheme == "https" ? 443 : 80)) {
            return failure("The real backend points back to a Mimic listener in this project.")
        }
        do {
            var outgoing = HTTPClientRequest(url: url.absoluteString)
            outgoing.method = request.method
            outgoing.headers = endToEndHeaders(request.headers, request: true)
            if let body = request.body.data { outgoing.body = .bytes(body) }
            // AsyncHTTPClient cancels this deadline timer when response headers arrive; streaming
            // bodies retain the idle read timeout without a fixed total-duration limit.
            let upstream = try await request.application.http.client.shared.execute(outgoing, timeout: .seconds(30))
            let status = Int(upstream.status.code)
            let headers = endToEndHeaders(
                upstream.headers, preservingContentLength: request.method == .HEAD && status != 204 && status != 304
            )
            if request.method == .HEAD || status == 204 || status == 205 || status == 304 {
                log(status: status, headers: headers, preview: Data(), truncated: false)
                let response = Response(status: upstream.status, headers: headers)
                if request.method == .HEAD || status == 204 || status == 304 {
                    // Vapor derives Content-Length: 0 from the empty body. A HEAD length refers
                    // to the representation; NIO removes framing headers entirely for 204/304.
                    response.headers = headers
                }
                return response
            }
            return Response(status: upstream.status, headers: headers, body: .init(managedAsyncStream: { writer in
                // This closure may never run if the downstream closes before streaming starts;
                // the captured lease then returns its slot on deinit. Every started writer below
                // transfers that slot to one complete or failed log.
                var preview = Data()
                var truncated = false
                do {
                    for try await chunk in upstream.body {
                        try Task.checkCancellation()
                        let available = max(0, ResponseCapture.maxBodyBytes - preview.count)
                        preview.append(contentsOf: chunk.readableBytesView.prefix(available))
                        truncated = truncated || chunk.readableBytes > available
                        try await writer.write(.buffer(chunk))
                    }
                    log(status: status, headers: headers, preview: preview, truncated: truncated)
                } catch {
                    log(status: status, headers: headers, preview: preview, truncated: true,
                        failure: "The backend response did not complete.")
                    throw error
                }
            }))
        } catch {
            return failure("Could not reach the real backend: \(error.localizedDescription)")
        }
    }

    /// A bounded prefix can stop halfway through a UTF-8 scalar. Only a truncated prefix may
    /// discard up to three trailing bytes; complete invalid UTF-8 still reports binary content.
    private static func previewText(_ data: Data, truncated: Bool) -> String? {
        if let text = String(data: data, encoding: .utf8) { return text }
        guard truncated else { return nil }
        for dropped in 1...min(3, data.count) {
            let tail = Array(data.suffix(dropped))
            let first = tail[0]
            let width: Int
            switch first {
            case 0xC2...0xDF: width = 2
            case 0xE0...0xEF: width = 3
            case 0xF0...0xF4: width = 4
            default: continue
            }
            guard dropped < width, tail.dropFirst().allSatisfy({ (0x80...0xBF).contains($0) }) else { continue }
            if tail.count > 1 {
                // Reject already-invalid prefixes (overlong encodings, surrogates, or > U+10FFFF).
                let second = tail[1]
                if (first == 0xE0 && second < 0xA0) || (first == 0xED && second > 0x9F)
                    || (first == 0xF0 && second < 0x90) || (first == 0xF4 && second > 0x8F) { continue }
            }
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        return nil
    }
}
