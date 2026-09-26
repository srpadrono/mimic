import Domain
import Foundation

enum ImportCandidateBuilder {
    static let bodySizeLimit = 1_048_576

    /// - Parameter documentBasePath: The prefix the source document declares for every route in it,
    ///   exactly as written — Swagger 2's `basePath`, or the first entry of OpenAPI 3's `servers`.
    ///   `nil` for a HAR, whose entries carry whole URLs and no document-level prefix.
    /// - Parameter binaryBodySizeBytes: The byte count of a captured body that was bytes rather
    ///   than text, or `nil` when the body — if there is one — is text. Non-nil means the parser
    ///   could not produce a `String` for the body at all, so the caller passes
    ///   `responseBody: nil` beside it and the candidate arrives flagged ``ImportCandidate/bodyIsBinary``.
    /// - Parameter unavailableBodySizeBytes: A positive captured size whose text was omitted from
    ///   the HAR. Kept separate from binary content so review can explain what is missing.
    /// - Parameter ledger: Every route this import has already accounted for. Passed `inout` because
    ///   a candidate claims its own route as it is built — see ``ImportRouteLedger``.
    static func makeCandidate(
        method: HTTPMethod,
        path: String,
        documentBasePath: String? = nil,
        suggestedName: String? = nil,
        suggestedGroupTag: String? = nil,
        statusCode: Int,
        responseHeaders: [String: String],
        responseBody: String?,
        binaryBodySizeBytes: Int? = nil,
        unavailableBodySizeBytes: Int? = nil,
        responseContentType: Scenario.ContentType,
        graphqlOperation: String? = nil,
        ledger: inout ImportRouteLedger
    ) -> ImportCandidate {
        // Filtered here rather than in each parser: a header that describes the original transfer is
        // wrong to replay no matter which format it was read from, and one chokepoint means a future
        // importer cannot forget.
        let replayableHeaders = ImportHeaderPolicy.replayable(responseHeaders)
        // A binary body has no `String` form, so its size arrives separately — the review sheet
        // still shows what the capture carried, even though no body can be imported from it.
        let bodySize = max(0, unavailableBodySizeBytes ?? binaryBodySizeBytes ?? responseBody?.utf8.count ?? 0)

        // The route as Mimic will match it, and the route as the *document* wrote it. See
        // ``ImportPath``: the first carries the document's prefix, the second does not, because a
        // spec served under `/mock` must not have every endpoint in it named and grouped "Mock".
        //
        // The rewrite runs for a HAR too, which is the point of doing it here — but note what that
        // means for one: a captured segment that is literally `{id}` becomes `:id`. That widens what
        // the endpoint answers rather than narrowing it (a wildcard segment matches the literal one
        // as well), so the request that produced the capture still matches, and a raw brace in a
        // captured path is not something a browser or a client library normally emits.
        let route = ImportPath.normalized(path, documentBasePath: documentBasePath)
        let namingRoute = ImportPath.route(path)
        // A failed, partial, or unavailable capture must not hide a later complete response for
        // this route. The row remains reviewable, but only replayable defaults claim the route.
        let canReplay = EndpointValidator.serveableStatusCodes.contains(statusCode) && statusCode != 206
            && (try? EndpointValidator.validatePath(route)) != nil
            && (try? EndpointValidator.validateHeaders(replayableHeaders)) != nil
            && binaryBodySizeBytes == nil && unavailableBodySizeBytes == nil && bodySize <= bodySizeLimit

        // Two GraphQL operations share a route, so route alone would call every one after the first
        // a duplicate. The operation is what makes them distinct.
        //
        // Compared on the *normalised* route, so a spec re-imported over endpoints it created before
        // is still recognised: what the project holds is `/v2/pet/:petId`, and what the document says
        // is `/pet/{petId}`.
        let isDuplicate = ledger.isAlreadyClaimed(
            method: method,
            path: route,
            graphqlOperation: graphqlOperation,
            claiming: canReplay
        )

        return ImportCandidate(
            id: UUID(),
            isSelected: canReplay && !isDuplicate,
            method: method,
            path: route,
            suggestedName: suggestedName ?? suggestName(method: method, path: namingRoute),
            suggestedGroupTag: suggestedGroupTag ?? suggestGroupTag(path: namingRoute),
            statusCode: statusCode,
            responseHeaders: replayableHeaders,
            responseBody: bodySize > bodySizeLimit ? nil : responseBody,
            responseContentType: responseContentType,
            graphqlOperation: graphqlOperation,
            bodySizeBytes: bodySize,
            bodySizeExceedsLimit: bodySize > bodySizeLimit,
            bodyIsBinary: binaryBodySizeBytes != nil,
            bodyIsUnavailable: unavailableBodySizeBytes != nil,
            isDuplicate: isDuplicate
        )
    }

    static func suggestGroupTag(path: String) -> String? {
        let filtered = meaningfulSegments(in: path)
        guard let group = filtered.first, group.count >= 2 else { return nil }
        return group.capitalized
    }

    static func suggestName(method: HTTPMethod, path: String) -> String {
        let resource = meaningfulSegments(in: path).last?.capitalized ?? "Resource"

        let verb: String
        switch method {
        case .get: verb = "Get"
        case .post: verb = "Create"
        case .put: verb = "Update"
        case .patch: verb = "Patch"
        case .delete: verb = "Delete"
        case .head: verb = "Head"
        case .options: verb = "Options"
        }

        return "\(verb) \(resource)"
    }

    static func detectContentType(_ mimeType: String?) -> Scenario.ContentType {
        let mediaType = mimeType?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
        return mediaType == "application/json" || mediaType == "text/json"
            || (mediaType.contains("/") && mediaType.hasSuffix("+json")) ? .json : .plainText
    }

    private static func meaningfulSegments(in path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { segment in
                let lower = segment.lowercased()
                let isCommonPrefix = lower == "api"
                    || (lower.count > 1 && lower.hasPrefix("v") && lower.dropFirst().allSatisfy(\.isNumber))
                // A wildcard segment is the template form of the `42` the numeric filter beside it
                // already drops: neither one names the resource. `/pet/:petId` is named after
                // `pet`, so a spec that supplies no `summary` and no `operationId` gets "Get Pet"
                // rather than the parameter — which, before the route rewrite, arrived here with
                // its braces still on and was just as wrong.
                return !isCommonPrefix
                    && !segment.hasPrefix(ImportPath.wildcardMarker)
                    && !segment.allSatisfy(\.isNumber)
            }
    }
}

/// Tracks primary-backend endpoints and replayable candidates already selected by default.
/// Equivalent slash shapes and wildcard names share a claim; method and GraphQL operation still
/// distinguish routes. The first usable response wins, matching the server's equal-specificity
/// rule. Later duplicates remain visible and may be selected explicitly in the review sheet.
struct ImportRouteLedger {
    /// What makes two candidates the same mock. Method and route alone would call every GraphQL
    /// operation after the first a duplicate of the one before it: they all share `POST /graphql`.
    private struct Claim: Hashable {
        let method: HTTPMethod
        let path: [String]
        let graphqlOperation: String?

        init(method: HTTPMethod, path: String, graphqlOperation: String?) {
            self.method = method
            self.path = PathPattern.matchingKey(for: path)
            self.graphqlOperation = graphqlOperation?.isEmpty == true ? nil : graphqlOperation
        }
    }

    private var claims: Set<Claim>

    init(existingEndpoints: [Endpoint]) {
        // ImportCommitter creates endpoints on the primary backend. A matching route on another
        // listener cannot answer primary-backend requests, so it must not pre-deselect this import.
        claims = Set(existingEndpoints.filter { $0.backendID == nil }.map {
            Claim(method: $0.method, path: $0.path, graphqlOperation: $0.graphqlOperation)
        })
    }

    /// Reports an existing claim. Only candidates that can be replayed by default create a new
    /// claim; a failed or unavailable capture must not hide a complete response later in the file.
    mutating func isAlreadyClaimed(
        method: HTTPMethod,
        path: String,
        graphqlOperation: String?,
        claiming: Bool = true
    ) -> Bool {
        let claim = Claim(method: method, path: path, graphqlOperation: graphqlOperation)
        let isDuplicate = claims.contains(claim)
        if claiming { claims.insert(claim) }
        return isDuplicate
    }
}
