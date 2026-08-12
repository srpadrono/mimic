import Foundation
import Domain

/// A candidate endpoint parsed from a HAR entry, ready for user review before import.
public struct ImportCandidate: Identifiable, Sendable {
    public let id: UUID
    public var isSelected: Bool
    public let method: HTTPMethod
    public let path: String
    public let suggestedName: String
    public let suggestedGroupTag: String?
    public let statusCode: Int
    public let responseHeaders: [String: String]
    public let responseBody: String?
    public let responseContentType: Scenario.ContentType
    /// Set when the capture was a GraphQL call, so the imported mock answers that operation alone.
    public let graphqlOperation: String?
    public let bodySizeBytes: Int
    public let bodySizeExceedsLimit: Bool
    public let isDuplicate: Bool

    /// Explicit rather than memberwise so `graphqlOperation` can default — it is meaningful for a
    /// minority of captures, and every REST call site would otherwise have to pass `nil`.
    public init(
        id: UUID = UUID(),
        isSelected: Bool,
        method: HTTPMethod,
        path: String,
        suggestedName: String,
        suggestedGroupTag: String?,
        statusCode: Int,
        responseHeaders: [String: String],
        responseBody: String?,
        responseContentType: Scenario.ContentType,
        graphqlOperation: String? = nil,
        bodySizeBytes: Int,
        bodySizeExceedsLimit: Bool,
        isDuplicate: Bool
    ) {
        self.id = id
        self.isSelected = isSelected
        self.method = method
        self.path = path
        self.suggestedName = suggestedName
        self.suggestedGroupTag = suggestedGroupTag
        self.statusCode = statusCode
        self.responseHeaders = responseHeaders
        self.responseBody = responseBody
        self.responseContentType = responseContentType
        self.graphqlOperation = graphqlOperation
        self.bodySizeBytes = bodySizeBytes
        self.bodySizeExceedsLimit = bodySizeExceedsLimit
        self.isDuplicate = isDuplicate
    }

    /// Human-readable body size label.
    public var bodySizeLabel: String {
        if bodySizeBytes < 1024 {
            return "\(bodySizeBytes) B"
        } else if bodySizeBytes < 1_048_576 {
            return String(format: "%.1f KB", Double(bodySizeBytes) / 1024)
        } else {
            return String(format: "%.1f MB", Double(bodySizeBytes) / 1_048_576)
        }
    }
}

/// Parses HAR files into import candidates.
public enum HARParser {
    /// Maximum response body size (1 MB). Bodies exceeding this are flagged but still included.
    public static let bodySizeLimit = ImportCandidateBuilder.bodySizeLimit

    /// Parse HAR file data into import candidates.
    /// - Parameters:
    ///   - data: Raw JSON data of the HAR file.
    ///   - existingEndpoints: Current project endpoints for duplicate detection.
    /// - Returns: Array of import candidates.
    public static func parse(
        data: Data,
        existingEndpoints: [Endpoint] = []
    ) async throws -> [ImportCandidate] {
        try await Task.detached {
            let harFile = try JSONDecoder().decode(HARFile.self, from: data)
            return harFile.log.entries.compactMap { entry in
                candidateFromEntry(entry, existingEndpoints: existingEndpoints)
            }
        }.value
    }

    // MARK: - Private

    private static func candidateFromEntry(
        _ entry: HAREntry,
        existingEndpoints: [Endpoint]
    ) -> ImportCandidate? {
        guard let method = httpMethod(from: entry.request.method) else { return nil }
        let path = extractPath(from: entry.request.url)
        guard !path.isEmpty else { return nil }

        let responseBody = decodeResponseBody(entry.response.content)
        let contentType = ImportCandidateBuilder.detectContentType(entry.response.content?.mimeType)

        let headers = extractResponseHeaders(entry.response.headers)

        // GraphQL sends every operation to one path, so a capture of twenty distinct calls would
        // otherwise collapse into twenty candidates that all look like `POST /graphql` — and, worse,
        // into one endpoint that can only answer one of them. Naming the operation makes each
        // addressable, which is the whole point of importing a capture.
        let operation = GraphQLRequest.operation(inBody: entry.request.postData?.text)

        return ImportCandidateBuilder.makeCandidate(
            method: method,
            path: path,
            suggestedName: operation.map { suggestName(operation: $0) }
                ?? suggestName(method: method, path: path),
            suggestedGroupTag: operation != nil ? "GraphQL" : suggestGroupTag(path: path),
            statusCode: entry.response.status,
            responseHeaders: headers,
            responseBody: responseBody,
            responseContentType: contentType,
            graphqlOperation: operation?.name,
            existingEndpoints: existingEndpoints
        )
    }

    /// Names a GraphQL candidate after its operation, which is the only thing distinguishing it.
    static func suggestName(operation: GraphQLOperation) -> String {
        operation.name
    }

    private static func httpMethod(from raw: String) -> HTTPMethod? {
        HTTPMethod(rawValue: raw.uppercased())
    }

    /// Extract the path component from a full URL.
    ///
    /// The result always begins with `/`, because an endpoint whose path does not cannot match any
    /// request the server will ever receive — it imports, it appears in the list, and it is dead.
    ///
    /// That was reachable, and the `guard` below looks like it covers it but does not.
    /// `URLComponents(string:)` does not fail on a schemeless string: it parses `api.example.com/users`
    /// as a *relative reference*, succeeds, and hands back the whole thing as `.path` with no host —
    /// so the fallback never ran and the host arrived as the start of the route. Re-parsing with a
    /// scheme is what separates the authority from the path, and it is only safe to do when the first
    /// segment actually looks like a hostname: `users/123` is a relative path, not a host called
    /// `users`.
    static func extractPath(from urlString: String) -> String {
        var components = URLComponents(string: urlString)

        if components?.scheme == nil,
           let firstSegment = urlString.split(separator: "/", maxSplits: 1).first,
           firstSegment.contains("."),
           let withScheme = URLComponents(string: "http://\(urlString)"),
           withScheme.host != nil,
           // Only when there is a path left after the authority. `logo.png` is one dotted segment
           // with nothing behind it, and re-parsing it as a host would leave the path empty and lose
           // the segment entirely — a relative filename is a path, not a bare host.
           !withScheme.path.isEmpty {
            components = withScheme
        }

        let path = components?.path ?? urlString
        guard !path.isEmpty else { return "/" }
        return path.hasPrefix("/") ? path : "/\(path)"
    }

    /// Suggest a group tag from the first meaningful path segment.
    /// e.g. "/api/v1/users/123" → "users", "/health" → nil (too short)
    static func suggestGroupTag(path: String) -> String? {
        ImportCandidateBuilder.suggestGroupTag(path: path)
    }

    /// Generate a human-readable name from method + path.
    /// e.g. GET /api/v1/users → "Get Users", POST /api/v1/users → "Create Users"
    static func suggestName(method: HTTPMethod, path: String) -> String {
        ImportCandidateBuilder.suggestName(method: method, path: path)
    }

    /// Decode response body, handling base64 encoding.
    ///
    /// The body is reproduced exactly as captured. An importer that edits the payload defeats the
    /// point of importing: the mock has to answer what the real server answered, byte for byte, or
    /// the client under test is being tested against something that never happened.
    ///
    /// This used to run a redaction pass here, and it did more harm than the leak it guarded. The
    /// key match was a *substring*, so `author`, `keywords`, `shipping`, `shopping`, `mapping`,
    /// `typing`, `opinion` and `monkey` all had their values replaced with `[REDACTED]` — ordinary
    /// fields, in the majority of real captures. Worse, the scalar branch quoted its replacement, so
    /// `"sessionCount": 42` came back as `"sessionCount": "[REDACTED]"` and changed the JSON type
    /// under a client that had every right to expect a number.
    ///
    /// A capture therefore now lands with whatever it contained, credentials included. That is the
    /// deliberate trade: see `SECURITY.md`. Review an imported mock before committing it.
    private static func decodeResponseBody(_ content: HARContent?) -> String? {
        guard let content, let text = content.text, !text.isEmpty else { return nil }

        if content.encoding?.lowercased() == "base64",
           let data = Data(base64Encoded: text),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return text
    }

    /// Flattens HAR's header list, dropping anything ``ImportHeaderPolicy`` says must not be replayed.
    ///
    /// A HAR may list the same header more than once (`Set-Cookie` typically); last one wins, which
    /// matches how a client would have seen it.
    static func extractResponseHeaders(_ headers: [HARHeader]?) -> [String: String] {
        guard let headers else { return [:] }
        var dict: [String: String] = [:]
        for header in headers where !ImportHeaderPolicy.shouldDrop(header.name) {
            dict[header.name] = header.value
        }
        return dict
    }
}
