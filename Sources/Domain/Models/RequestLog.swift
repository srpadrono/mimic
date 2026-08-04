import Foundation

public struct RequestLog: Identifiable, Codable, Sendable, Equatable {
    /// How much of a body the log keeps. Generous enough for any realistic mock payload, small
    /// enough that a thousand of them cannot exhaust memory.
    ///
    /// Applied to the *request* body as well as the response. It used to guard only the response,
    /// which left the real exposure open: a request body arrives up to the engine's 10 MB collect
    /// limit, and a thousand of those is ten gigabytes held live.
    public static let maxLoggedBodyBytes = 64 * 1024

    /// Header names whose values are replaced before a log entry is handed to anything but the local
    /// UI — see ``redactingCredentials()``.
    public static let sensitiveHeaderNames: Set<String> = [
        "authorization",
        "proxy-authorization",
        "cookie",
        "set-cookie",
        "x-api-key",
        "x-auth-token",
    ]

    public static let redactionPlaceholder = "[REDACTED]"

    /// Trims a body to the cap, reporting whether anything was dropped.
    public static func cappedBody(_ body: String?) -> (body: String?, truncated: Bool) {
        guard let body else { return (nil, false) }
        guard body.utf8.count > maxLoggedBodyBytes else { return (body, false) }
        // Truncating UTF-8 at a byte offset can split a multi-byte scalar; `String(decoding:)` would
        // silently substitute U+FFFD. Backing up to a scalar boundary keeps the kept prefix exact.
        var end = body.utf8.index(body.utf8.startIndex, offsetBy: maxLoggedBodyBytes)
        while end > body.utf8.startIndex, String(body.utf8[body.utf8.startIndex..<end]) == nil {
            end = body.utf8.index(before: end)
        }
        return (String(body.utf8[body.utf8.startIndex..<end]) ?? "", true)
    }

    public let id: UUID
    public let timestamp: Date
    public let method: HTTPMethod
    public let path: String
    public let requestHeaders: [String: String]
    public let requestBody: String?
    public let matchedEndpointID: UUID?
    public let matchedScenarioID: UUID?
    public let responseStatusCode: Int?
    /// Headers actually written back, including the `Content-Type` the server chose.
    public let responseHeaders: [String: String]
    /// Body actually written back, capped at ``maxLoggedBodyBytes``.
    ///
    /// Capped because the log holds a thousand entries and a mock may return megabytes; an
    /// uncapped log would quietly grow into a memory leak that only shows up under load.
    public let responseBody: String?
    /// `true` when ``responseBody`` was cut short, so the UI can say so rather than imply the mock
    /// returned less than it did.
    public let responseBodyTruncated: Bool
    /// Set when an active journey answered this request, so the log reads as a trace through the
    /// journey rather than a flat list of routes.
    public let matchedJourneyID: UUID?
    public let matchedJourneyStepID: UUID?
    /// Human-readable transport failure (`connection-drop`, `timeout(30000ms)`) when the request was
    /// failed rather than answered. `responseStatusCode` is `nil` in that case.
    public let failureLabel: String?
    /// What answered this request. `.unmatched` means Mimic had no configuration for it — the case
    /// worth spotting when a client is calling something you have not mocked yet.
    public let outcome: RequestOutcome

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        method: HTTPMethod,
        path: String,
        requestHeaders: [String: String] = [:],
        requestBody: String? = nil,
        matchedEndpointID: UUID? = nil,
        matchedScenarioID: UUID? = nil,
        responseStatusCode: Int? = nil,
        responseHeaders: [String: String] = [:],
        responseBody: String? = nil,
        responseBodyTruncated: Bool = false,
        matchedJourneyID: UUID? = nil,
        matchedJourneyStepID: UUID? = nil,
        failureLabel: String? = nil,
        outcome: RequestOutcome = .endpoint
    ) {
        self.id = id
        self.timestamp = timestamp
        self.method = method
        self.path = path
        self.requestHeaders = requestHeaders
        self.requestBody = requestBody
        self.matchedEndpointID = matchedEndpointID
        self.matchedScenarioID = matchedScenarioID
        self.responseStatusCode = responseStatusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseBodyTruncated = responseBodyTruncated
        self.matchedJourneyID = matchedJourneyID
        self.matchedJourneyStepID = matchedJourneyStepID
        self.failureLabel = failureLabel
        self.outcome = outcome
    }

    /// A copy with credential-bearing request headers replaced by a placeholder.
    ///
    /// The request log holds whatever the app under test sent, and what it sends is real: a bearer
    /// token for a staging API, a session cookie, an API key. Inside the app's own window that is
    /// exactly what you want to see — it is *your* traffic on *your* screen. Handing the same bytes
    /// to any caller of the control API is a different thing, so the log is redacted on its way out
    /// and left intact for the UI.
    ///
    /// Only header *values* are replaced. The names stay, because "there was an Authorization header"
    /// is often the fact you are debugging.
    public func redactingCredentials() -> RequestLog {
        RequestLog(
            id: id,
            timestamp: timestamp,
            method: method,
            path: path,
            requestHeaders: Self.redacted(requestHeaders),
            requestBody: requestBody,
            matchedEndpointID: matchedEndpointID,
            matchedScenarioID: matchedScenarioID,
            responseStatusCode: responseStatusCode,
            responseHeaders: Self.redacted(responseHeaders),
            responseBody: responseBody,
            responseBodyTruncated: responseBodyTruncated,
            matchedJourneyID: matchedJourneyID,
            matchedJourneyStepID: matchedJourneyStepID,
            failureLabel: failureLabel,
            outcome: outcome
        )
    }
}

extension RequestLog {
    /// `true` when this header's value must not leave the process.
    public static func isSensitiveHeader(_ name: String) -> Bool {
        sensitiveHeaderNames.contains(name.lowercased().trimmingCharacters(in: .whitespaces))
    }

    static func redacted(_ headers: [String: String]) -> [String: String] {
        headers.reduce(into: [:]) { result, pair in
            result[pair.key] = isSensitiveHeader(pair.key) ? redactionPlaceholder : pair.value
        }
    }
}
