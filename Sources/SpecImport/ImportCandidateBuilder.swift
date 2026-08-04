import Domain
import Foundation

enum ImportCandidateBuilder {
    static let bodySizeLimit = 1_048_576

    static func makeCandidate(
        method: HTTPMethod,
        path: String,
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
        // Two GraphQL operations share a route, so route alone would call every one after the first
        // a duplicate. The operation is what makes them distinct.
        let isDuplicate = existingEndpoints.contains { endpoint in
            endpoint.method == method
                && endpoint.path == path
                && endpoint.graphqlOperation == graphqlOperation
        }

        return ImportCandidate(
            id: UUID(),
            isSelected: !isDuplicate,
            method: method,
            path: path,
            suggestedName: suggestedName ?? suggestName(method: method, path: path),
            suggestedGroupTag: suggestedGroupTag ?? suggestGroupTag(path: path),
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
                return !isCommonPrefix && !segment.allSatisfy(\.isNumber)
            }
    }
}
