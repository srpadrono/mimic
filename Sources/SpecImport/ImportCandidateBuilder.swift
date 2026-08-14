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
        let bodySize = binaryBodySizeBytes ?? responseBody?.utf8.count ?? 0

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
        let isDuplicate = ledger.isAlreadyClaimed(
            method: method,
            path: route,
            graphqlOperation: graphqlOperation
        )

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
            bodyIsBinary: binaryBodySizeBytes != nil,
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

/// Every route an import has already accounted for: the endpoints the project holds, **plus the
/// candidates produced so far in this same batch**.
///
/// The second half is what was missing, and it is a HAR that needs it: a spec's `paths` is a
/// dictionary keyed by the route as written, so one document cannot list the same path twice —
/// though two different templates can still normalise onto one route, and that is now caught here
/// too — while a capture of real traffic repeats routes by definition.
/// `HARParser.parse` computed `isDuplicate` against a list of existing
/// endpoints captured once before the loop and accumulated nothing, so four hits on `/cart` produced
/// four candidates all flagged clean and all pre-selected. `ImportCommitter` issues one
/// `.endpointCreate` per selected candidate and `ProjectCommandExecutor` appends, so all four landed
/// on one method and path — and `RequestMatcher.match` replaces its best only on *strictly greater*
/// specificity, so the first answered every request and the other three were unreachable rows
/// carrying responses the user could see in the review sheet and never reach.
///
/// **The first claim on a route keeps it**, which is a choice and not the only defensible one. Three
/// reasons for it over last-write-wins:
///
/// - It is the same direction as the rule for an endpoint the project already holds, which is not
///   negotiable: what exists wins, and the candidate arrives deselected. One rule, applied whether
///   the earlier claim is in the project or three entries up the capture.
/// - It agrees with what the server does. `RequestMatcher.match` keeps the first endpoint of equal
///   specificity, so if a user overrides the defaults and selects several repeats, the one that
///   answers is the one that was selected for them. Under last-wins the default and the override
///   would name different rows.
/// - Deselection is a default, not a decision. Every repeat still appears in the review sheet with
///   its own status and size, flagged the way a pre-existing duplicate is flagged, and the user can
///   flip which one lands — that is what makes the choice visible rather than silent.
struct ImportRouteLedger {
    /// What makes two candidates the same mock. Method and route alone would call every GraphQL
    /// operation after the first a duplicate of the one before it: they all share `POST /graphql`.
    private struct Claim: Hashable {
        let method: HTTPMethod
        let path: String
        let graphqlOperation: String?
    }

    private var claims: Set<Claim>

    init(existingEndpoints: [Endpoint]) {
        claims = Set(existingEndpoints.map {
            Claim(method: $0.method, path: $0.path, graphqlOperation: $0.graphqlOperation)
        })
    }

    /// `true` when this route was already spoken for — by an endpoint the project holds, or by an
    /// earlier candidate in this import. Records it either way, so the *next* repeat is answered
    /// too.
    mutating func isAlreadyClaimed(
        method: HTTPMethod,
        path: String,
        graphqlOperation: String?
    ) -> Bool {
        claims.insert(Claim(method: method, path: path, graphqlOperation: graphqlOperation)).inserted == false
    }
}
