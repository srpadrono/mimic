import Domain
import Foundation

enum ImportCandidateBuilder {
    static let bodySizeLimit = 1_048_576

    /// - Parameter documentBasePath: The prefix the source document declares for every route in it,
    ///   exactly as written — Swagger 2's `basePath`, or the first entry of OpenAPI 3's `servers`.
    ///   `nil` for a HAR, whose entries carry whole URLs and no document-level prefix.
    static func makeCandidate(
        method: HTTPMethod,
        path: String,
        documentBasePath: String? = nil,
        suggestedName: String? = nil,
        suggestedGroupTag: String? = nil,
        statusCode: Int,
        responseHeaders: [String: String],
        responseBody: String?,
        responseContentType: Scenario.ContentType,
        graphqlOperation: String? = nil,
        existingEndpoints: [Endpoint]
    ) -> ImportCandidate {
        // Filtered here rather than in each parser: a header that describes the original transfer is
        // wrong to replay no matter which format it was read from, and one chokepoint means a future
        // importer cannot forget.
        let replayableHeaders = ImportHeaderPolicy.replayable(responseHeaders)
        let bodySize = responseBody?.utf8.count ?? 0

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

        // Two GraphQL operations share a route, so route alone would call every one after the first
        // a duplicate. The operation is what makes them distinct.
        //
        // Compared on the *normalised* route, so a spec re-imported over endpoints it created before
        // is still recognised: what the project holds is `/v2/pet/:petId`, and what the document says
        // is `/pet/{petId}`.
        let isDuplicate = existingEndpoints.contains { endpoint in
            endpoint.method == method
                && endpoint.path == route
                && endpoint.graphqlOperation == graphqlOperation
        }

        return ImportCandidate(
            id: UUID(),
            isSelected: !isDuplicate,
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
        guard let mimeType, !mimeType.isEmpty else { return .plainText }
        return mimeType.lowercased().contains("json") ? .json : .plainText
    }

    private static func meaningfulSegments(in path: String) -> [String] {
        path.split(separator: "/")
            .map(String.init)
            .filter { segment in
                let lower = segment.lowercased()
                let isCommonPrefix = lower == "api"
                    || (lower.hasPrefix("v") && lower.dropFirst().allSatisfy(\.isNumber))
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
