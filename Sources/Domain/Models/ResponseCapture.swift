import Foundation

/// The shared boundary between observed traffic and persistent, shareable fixtures.
public enum ResponseCapture {
    public static let maxBodyBytes = 5 * 1024 * 1024

    public static func body(_ log: RequestLog) throws -> String? {
        try validate(log)
        if let captured = log.capturedResponseBody {
            do { return try captured.text() }
            catch { throw ControlError.invalid("The complete response is no longer available. Send the request again to capture it.") }
        }
        return log.responseBody
    }

    public static func validate(_ log: RequestLog) throws {
        guard log.outcome != .proxyFailure else {
            throw ControlError.invalid("The backend did not return a complete response.")
        }
        guard log.failureLabel == nil, log.responseStatusCode != nil else {
            throw ControlError.invalid("This request has no HTTP response to capture. Add a connection-drop or timeout step to reproduce a transport failure.")
        }
        guard log.requestBodyTruncated != true else {
            throw ControlError.invalid("The request preview is incomplete, so its operation cannot be captured safely.")
        }
        guard !log.responseBodyTruncated || log.capturedResponseBody != nil else {
            throw ControlError.invalid("The complete response is unavailable or exceeds the 5 MiB capture limit. Send the request again or save a smaller response.")
        }
        guard (log.capturedResponseBody?.byteCount ?? log.responseBody?.utf8.count ?? 0) <= maxBodyBytes else {
            throw ControlError.invalid("This response exceeds the 5 MiB capture limit.")
        }
        if log.outcome == .passthrough {
            guard log.responseStatusCode != 304 else {
                throw ControlError.invalid("A 304 response uses the client's cached body. Capture a full backend response instead.")
            }
            guard log.responseStatusCode != 206,
                  !log.responseHeaders.contains(where: { $0.key.lowercased() == "content-range" }) else {
                throw ControlError.invalid("A partial response cannot be saved as a complete mock. Capture a response without a Range request.")
            }
            // Diagnose encoding before UTF-8: compressed JSON is not a binary media type,
            // even though its wire bytes cannot be interpreted as UTF-8.
            guard !log.responseHeaders.contains(where: {
                $0.key.lowercased() == "content-encoding"
                    && $0.value.split(separator: ",").contains {
                        $0.trimmingCharacters(in: .whitespaces).lowercased() != "identity"
                    }
            }) else {
                throw ControlError.invalid("This response is compressed. It was forwarded unchanged, but cannot be saved as a text mock. Request an uncompressed response (Accept-Encoding: identity) and capture again.")
            }
            let type = log.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            guard isTextMediaType(type) else {
                throw ControlError.invalid("Only text responses can be captured. Binary responses are forwarded unchanged.")
            }
            let mediaType = type.lowercased().split(separator: ";").first?.trimmingCharacters(in: .whitespaces) ?? ""
            if (mediaType == "application/json" || mediaType.hasSuffix("+json")),
               log.method != .head, log.responseStatusCode != 204, log.responseStatusCode != 205 {
                guard log.capturedResponseBody != nil || !(log.responseBody ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw ControlError.invalid("This JSON response has no body. Capture a complete JSON response instead.")
                }
            }
        }
        guard log.responseBodyIsBinary != true else {
            throw ControlError.invalid("Binary or non-UTF-8 responses cannot be saved as text mocks.")
        }
    }

    public static func isTextMediaType(_ value: String) -> Bool {
        let type = value.lowercased().split(separator: ";", maxSplits: 1)
            .first?.trimmingCharacters(in: .whitespaces) ?? ""
        return type.isEmpty || type.hasPrefix("text/") || type == "application/json"
            || type.hasSuffix("+json") || type == "application/xml" || type.hasSuffix("+xml")
            || type == "application/javascript" || type == "application/x-www-form-urlencoded"
    }

    public static func headers(_ headers: [String: String]) -> [String: String] {
        let transport: Set<String> = ["connection", "keep-alive", "transfer-encoding", "te", "trailer",
            "upgrade", "proxy-authenticate", "proxy-authorization", "content-length", "content-encoding",
            "content-range", "date", "age", "server"]
        // These describe the upstream's network, rate-limit window, or reporting service at
        // capture time. Replaying them from localhost gives clients false state and can send
        // browser network reports to the upstream's reporting endpoint.
        let transient: Set<String> = [
            "alt-svc", "cf-cache-status", "cf-ray", "nel", "report-to", "server-timing",
            "strict-transport-security", "via", "x-cache", "x-correlation-id", "x-request-id",
        ]
        let nominated = Set(headers.filter { $0.key.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        return headers.filter {
            let name = $0.key.lowercased()
            return !transport.contains(name) && !transient.contains(name)
                && !name.hasPrefix("x-ratelimit-") && !nominated.contains(name)
                && !RequestLog.isSensitiveHeader($0.key) && !$0.key.hasPrefix(":")
        }
    }
}
