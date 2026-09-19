import Foundation

/// The shared boundary between observed traffic and persistent, shareable fixtures.
public enum ResponseCapture {
    public static func validate(_ log: RequestLog) throws {
        guard log.outcome != .proxyFailure else {
            throw ControlError.invalid("The backend did not return a complete response.")
        }
        guard log.requestBodyTruncated != true else {
            throw ControlError.invalid("The request preview is incomplete, so its operation cannot be captured safely.")
        }
        guard !log.responseBodyTruncated else {
            throw ControlError.invalid("This response exceeds the capture limit. Save a complete response instead.")
        }
        guard log.responseBodyIsBinary != true else {
            throw ControlError.invalid("Binary or non-UTF-8 responses cannot be saved as text mocks.")
        }
        if log.outcome == .passthrough {
            let type = log.responseHeaders.first { $0.key.lowercased() == "content-type" }?.value ?? ""
            guard isTextMediaType(type),
                  !log.responseHeaders.contains(where: { $0.key.lowercased() == "content-encoding" && $0.value.lowercased() != "identity" }) else {
                throw ControlError.invalid("Only decoded text responses can be captured. Binary and compressed responses are forwarded unchanged.")
            }
        }
    }

    public static func isTextMediaType(_ value: String) -> Bool {
        let type = value.lowercased().split(separator: ";").first.map(String.init) ?? ""
        return type.isEmpty || type.hasPrefix("text/") || type == "application/json"
            || type.hasSuffix("+json") || type == "application/xml" || type.hasSuffix("+xml")
            || type == "application/javascript" || type == "application/x-www-form-urlencoded"
    }

    public static func headers(_ headers: [String: String]) -> [String: String] {
        let transport: Set<String> = ["connection", "keep-alive", "transfer-encoding", "te", "trailer",
            "upgrade", "proxy-authenticate", "proxy-authorization", "content-length", "content-encoding",
            "content-range", "date", "age", "server"]
        let nominated = Set(headers.filter { $0.key.lowercased() == "connection" }
            .flatMap { $0.value.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } })
        return headers.filter {
            !transport.contains($0.key.lowercased()) && !nominated.contains($0.key.lowercased())
                && !RequestLog.isSensitiveHeader($0.key) && !$0.key.hasPrefix(":")
        }
    }
}
