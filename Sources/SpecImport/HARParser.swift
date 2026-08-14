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
    /// The captured body was bytes, not text: base64 whose decoded form is not valid UTF-8 — an
    /// image, a font, a gzipped payload — or a body declared base64 that would not decode at all.
    /// A `String` response body cannot reproduce those bytes, so the candidate imports without
    /// one, flagged, the same treatment an oversized body gets. What it must never do is import
    /// the base64 *spelling* as the body, which is what happened before this flag existed.
    public let bodyIsBinary: Bool
    /// Something already covers this method, path and GraphQL operation: an endpoint the project
    /// holds, **or an earlier candidate in the same import**. Flagged and deselected either way —
    /// see ``ImportRouteLedger`` for why the earlier one is the one left selected.
    public let isDuplicate: Bool

    /// Explicit rather than memberwise so `graphqlOperation` and `bodyIsBinary` can default —
    /// each is meaningful for a minority of captures, and every other call site would otherwise
    /// have to pass `nil` or `false`.
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
        bodyIsBinary: Bool = false,
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
        self.bodyIsBinary = bodyIsBinary
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
    ///   - existingEndpoints: Current project endpoints. One half of duplicate detection; the other
    ///     is the entries already read from this same capture.
    /// - Returns: Array of import candidates, one per usable entry — repeats included, flagged.
    public static func parse(
        data: Data,
        existingEndpoints: [Endpoint] = []
    ) async throws -> [ImportCandidate] {
        try await Task.detached {
            let harFile = try JSONDecoder().decode(HARFile.self, from: data)
            // One ledger, threaded through the entries in order. This was a `compactMap` with
            // `existingEndpoints` captured once before it and nothing accumulated, so `isDuplicate`
            // could only ever mean "already in the project" — and a capture of real traffic hits the
            // same route repeatedly by definition. See ``ImportRouteLedger``.
            var ledger = ImportRouteLedger(existingEndpoints: existingEndpoints)
            var candidates: [ImportCandidate] = []
            for entry in harFile.log.entries {
                guard let candidate = candidateFromEntry(entry, ledger: &ledger) else { continue }
                candidates.append(candidate)
            }
            return candidates
        }.value
    }

    // MARK: - Private

    private static func candidateFromEntry(
        _ entry: HAREntry,
        ledger: inout ImportRouteLedger
    ) -> ImportCandidate? {
        guard let method = httpMethod(from: entry.request.method) else { return nil }
        let path = extractPath(from: entry.request.url)
        guard !path.isEmpty else { return nil }

        let responseBody: String?
        let binaryBodySizeBytes: Int?
        switch decodeResponseBody(entry.response.content) {
        case .empty:
            responseBody = nil
            binaryBodySizeBytes = nil
        case .text(let text):
            responseBody = text
            binaryBodySizeBytes = nil
        case .binary(let sizeBytes):
            responseBody = nil
            binaryBodySizeBytes = sizeBytes
        }
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
            binaryBodySizeBytes: binaryBodySizeBytes,
            responseContentType: contentType,
            graphqlOperation: operation?.name,
            ledger: &ledger
        )
    }

    /// Names a GraphQL candidate after its operation, which is the only thing distinguishing it.
    static func suggestName(operation: GraphQLOperation) -> String {
        operation.name
    }

    private static func httpMethod(from raw: String) -> HTTPMethod? {
        HTTPMethod(rawValue: raw.uppercased())
    }

    /// Extract the path component from a full URL, **percent-encoded**, which is the form the
    /// running server compares against.
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
    ///
    /// **`percentEncodedPath`, not `path`, and this is the seam.** A route has to be written in one
    /// encoding on both sides of it, and the serving side does not offer a choice: `VaporConfigurator`
    /// builds its `IncomingRequest` from `req.url.path`, and Vapor's `URI.path` getter is
    /// `components?.percentEncodedPath` with `%3B` mapped back to `;`
    /// (`Sources/Vapor/Utilities/URI.swift:179` in Vapor 4.121.3, the revision both `Package.resolved`
    /// files pin), built from the raw request line by `URI.init(path:)` — the decoder's own comment
    /// says why it must be that initialiser and not `URI.init(string:)`.
    /// `PathPattern.specificity` then compares segments with
    /// `!=` on those raw strings. So `.path` — which is decoded — imported a capture of
    /// `/v1/caf%C3%A9/items` as `/v1/café/items`, and the endpoint 404'd for the rest of its life;
    /// `EndpointValidator.validatePath` waves it through, because a decoded path is not malformed,
    /// only unmatchable.
    ///
    /// Decoding at the serving boundary instead was the alternative, and it is worse: `%2F` decodes
    /// to `/`, so decoding before the split would change how many segments a request has, and it
    /// would have to be done inside `PathPattern` — where it would apply to every endpoint in every
    /// project rather than to the one place that reads a wire-form URL.
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
           !withScheme.percentEncodedPath.isEmpty {
            components = withScheme
        }

        let path = components?.percentEncodedPath ?? urlString
        guard !path.isEmpty else { return "/" }
        let routable = path.hasPrefix("/") ? path : "/\(path)"
        // The one place the two sides would still disagree. Vapor's `URI.path` getter maps `%3B`
        // back to `;` unconditionally; the reason is written beside its `urlPathAllowedIsBroken`
        // branch — "On Linux and in older Xcode versions, URLComponents incorrectly treats `;` as
        // *not* allowed in the path component." Undo it here too, or a captured `%3B` is a segment
        // the server can never hand the matcher.
        return routable.replacingOccurrences(of: "%3B", with: ";", options: .literal)
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

    /// What a captured body decoded to: text a `String` response body can carry, nothing at all,
    /// or bytes no `String` can represent.
    private enum DecodedBody {
        case empty
        case text(String)
        /// Base64 whose decoded bytes are not valid UTF-8, or a body declared base64 that did not
        /// decode as it. Carries the byte count for the review sheet; the body itself is dropped.
        case binary(sizeBytes: Int)
    }

    /// Decode response body, handling base64 encoding.
    ///
    /// A body that decodes to *text* is reproduced exactly as captured. An importer that edits the
    /// payload defeats the point of importing: the mock has to answer what the real server
    /// answered, or the client under test is being tested against something that never happened.
    ///
    /// A body that does not — every image, font and gzipped asset in a real browser capture — is
    /// **dropped and flagged** instead, because `ImportCandidate.responseBody` is a `String` and no
    /// `String` reproduces those bytes. This function used to fall through to returning the literal
    /// base64 *spelling* of such a body, pre-selected and unflagged, so the mock served the
    /// encoding where the wire carried the bytes; it also decoded strictly, so newline-wrapped
    /// base64 — which real exporters write at MIME column widths — took the same fall-through even
    /// when the body underneath was text. The candidate now arrives with no body and
    /// ``ImportCandidate/bodyIsBinary`` set, the same treatment ``ImportCandidateBuilder`` gives an
    /// oversized body.
    ///
    /// This used to run a redaction pass here, and it did more harm than the leak it guarded. The
    /// key match was a *substring*, so `author`, `keywords`, `shipping`, `shopping`, `mapping`,
    /// `typing`, `opinion` and `monkey` all had their values replaced with `[REDACTED]` — ordinary
    /// fields, in the majority of real captures. Worse, the scalar branch quoted its replacement, so
    /// `"sessionCount": 42` came back as `"sessionCount": "[REDACTED]"` and changed the JSON type
    /// under a client that had every right to expect a number.
    ///
    /// A text capture therefore now lands with whatever it contained, credentials included. That is
    /// the deliberate trade: see `SECURITY.md`. Review an imported mock before committing it.
    private static func decodeResponseBody(_ content: HARContent?) -> DecodedBody {
        guard let content, let text = content.text, !text.isEmpty else { return .empty }
        guard content.encoding?.lowercased() == "base64" else { return .text(text) }

        // `.ignoreUnknownCharacters`, because a strict decode fails on the first line break of
        // wrapped base64 — and the failure must not hand the wrapped spelling to the caller.
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else {
            // Declared base64, not decodable as it. The capture says these characters are an
            // *encoding* of the body, not the body — importing them as text would be the same lie
            // as the binary case, so same treatment. The raw length is the only size on hand.
            return .binary(sizeBytes: text.utf8.count)
        }
        if let str = String(data: data, encoding: .utf8) {
            return .text(str)
        }
        return .binary(sizeBytes: data.count)
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
