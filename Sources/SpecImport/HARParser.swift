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
    static func extractPath(from urlString: String) -> String {
        guard let components = URLComponents(string: urlString) else {
            return urlString.hasPrefix("/") ? urlString : "/\(urlString)"
        }
        let path = components.path
        return path.isEmpty ? "/" : path
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

    /// Decode response body, handling base64 encoding and stripping sensitive tokens.
    private static func decodeResponseBody(_ content: HARContent?) -> String? {
        guard let content, let text = content.text, !text.isEmpty else { return nil }

        let decoded: String
        if content.encoding?.lowercased() == "base64",
           let data = Data(base64Encoded: text),
           let str = String(data: data, encoding: .utf8) {
            decoded = str
        } else {
            decoded = text
        }

        return redactSensitiveValues(decoded)
    }

    /// Redact bearer tokens, API keys, and other secrets from response bodies
    /// (common when APIs echo back request headers like httpbin's /anything).
    ///
    /// Best-effort, and worth being honest about what that means: this is pattern matching over
    /// someone else's JSON, so it catches the shapes that show up in practice and cannot promise to
    /// catch everything. It is a net, not a guarantee. Review an imported mock before committing it.
    ///
    /// The key match is a *substring* match on purpose. An earlier version anchored both quotes, so
    /// `"token"` was redacted but `"refresh_token"`, `"id_token"` and `"client_secret"` sailed
    /// through — the near-misses are exactly the ones worth catching, since an imported mock is
    /// committed to a repository and shared.
    /// Key names that make a value a secret. Matched as a *substring* of the JSON key.
    static let sensitiveKeyFragment = "key|secret|token|password|passwd|credential|auth|session|signature|otp|pin"

    static func redactSensitiveValues(_ body: String) -> String {
        var result = body

        // "Bearer <token>" → "Bearer [REDACTED]", wherever it appears.
        // Bound to a `let` rather than written inline: a bare regex literal in argument position is
        // ambiguous with the division operator, and this one ends in `=*/`, which a parser that has
        // not committed to "this is a regex" reads as the end of a block comment.
        let bearer = /Bearer\s+[A-Za-z0-9\-._~+\/]+=*/
        result = result.replacing(bearer, with: "Bearer [REDACTED]")

        // A bare JWT — three base64url segments — is recognisable without a key name around it.
        let jwt = /eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]+/
        result = result.replacing(jwt, with: "[REDACTED_JWT]")

        // A sensitive JSON key with a string value.
        if let stringValued = try? Regex<(Substring, Substring, Substring)>(
            #""([A-Za-z0-9_.\-]*(?:\#(sensitiveKeyFragment))[A-Za-z0-9_.\-]*)"(\s*:\s*)"[^"]*""#
        ).ignoresCase() {
            result = result.replacing(stringValued) { match in
                "\"\(match.1)\"\(match.2)\"[REDACTED]\""
            }
        }

        // The same, with a non-string value — `"token": 123456`, `"secret": null`. The old pattern
        // required quotes around the value and so missed these entirely.
        if let scalarValued = try? Regex<(Substring, Substring, Substring)>(
            #""([A-Za-z0-9_.\-]*(?:\#(sensitiveKeyFragment))[A-Za-z0-9_.\-]*)"(\s*:\s*)(?:true|false|null|-?[0-9]+(?:\.[0-9]+)?)"#
        ).ignoresCase() {
            result = result.replacing(scalarValued) { match in
                "\"\(match.1)\"\(match.2)\"[REDACTED]\""
            }
        }

        return result
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
