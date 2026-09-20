import AsyncHTTPClient
import Domain
import Foundation
import Vapor

/// Forward bytes with backpressure; keep only a bounded preview for the request log.
enum ProxyForwarder {
    static func target(base: String, requestURI: String) -> URL? {
        guard var target = URLComponents(string: base),
              let scheme = target.scheme?.lowercased(), ["http", "https"].contains(scheme),
              target.host != nil, target.user == nil, target.password == nil,
              target.query == nil, target.fragment == nil,
              let incoming = URLComponents(string: requestURI) else { return nil }
        let prefix = target.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let route = incoming.percentEncodedPath
        target.percentEncodedPath = (prefix.isEmpty ? "" : "/" + prefix) + (route.hasPrefix("/") ? route : "/" + route)
        target.percentEncodedQuery = incoming.percentEncodedQuery
        return target.url
    }

    static func endToEndHeaders(_ source: HTTPHeaders, request: Bool = false) -> HTTPHeaders {
        var excluded: Set<String> = ["connection", "keep-alive", "transfer-encoding", "te", "trailer",
            "upgrade", "proxy-authenticate", "proxy-authorization", "content-length"]
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
        logContinuation: AsyncStream<RequestLog>.Continuation
    ) async -> Response {
        let started = ContinuousClock.now
        let (requestBody, requestBodyTruncated) = RequestLog.cappedBody(incoming.body)
        @Sendable func log(status: Int, headers: HTTPHeaders, preview: Data, truncated: Bool, failure: String? = nil) {
            let text = String(data: preview, encoding: .utf8)
            let elapsed = started.duration(to: .now).components
            logContinuation.yield(RequestLog(
                method: incoming.method, path: request.url.string, backendID: incoming.backendID, projectID: projectID,
                backendName: backendName, listenerPort: listenerPort,
                upstreamURL: target(base: upstreamURL, requestURI: request.url.string)?.absoluteString,
                durationMs: Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000),
                responseBodyIsBinary: text == nil,
                requestHeaders: incoming.headers, requestBody: requestBody, requestBodyTruncated: requestBodyTruncated,
                responseStatusCode: status,
                responseHeaders: Dictionary(headers.map { ($0.name, $0.value) }, uniquingKeysWith: { first, last in first + ", " + last }),
                responseBody: text, responseBodyTruncated: truncated,
                failureLabel: failure == nil ? nil : "backend-unavailable", outcome: failure == nil ? .passthrough : .proxyFailure
            ))
        }
        func failure(_ message: String) -> Response {
            log(status: 502, headers: [:], preview: Data(message.utf8), truncated: false, failure: message)
            return Response(status: .badGateway, body: .init(string: message))
        }
        guard let url = target(base: upstreamURL, requestURI: request.url.string) else {
            return failure("Invalid real backend URL.")
        }
        let host = url.host?.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]")) ?? ""
        if ["127.0.0.1", "localhost", "::1"].contains(host),
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
            let headers = endToEndHeaders(upstream.headers)
            let status = Int(upstream.status.code)
            if request.method == .HEAD || status == 204 || status == 304 {
                log(status: status, headers: headers, preview: Data(), truncated: false)
                return Response(status: upstream.status, headers: headers)
            }
            return Response(status: upstream.status, headers: headers, body: .init(managedAsyncStream: { writer in
                var preview = Data()
                var truncated = false
                do {
                    for try await chunk in upstream.body {
                        try Task.checkCancellation()
                        let available = max(0, RequestLog.maxLoggedBodyBytes - preview.count)
                        preview.append(contentsOf: chunk.readableBytesView.prefix(available))
                        truncated = truncated || chunk.readableBytes > available
                        try await writer.write(.buffer(chunk))
                    }
                    log(status: status, headers: headers, preview: preview, truncated: truncated)
                } catch {
                    log(status: status, headers: headers, preview: preview, truncated: true, failure: "The backend response did not complete.")
                    throw error
                }
            }))
        } catch {
            return failure("Could not reach the real backend: \(error.localizedDescription)")
        }
    }
}
