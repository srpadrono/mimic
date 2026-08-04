import Foundation

public struct IncomingRequest: Sendable, Equatable {
    public let method: HTTPMethod
    public let path: String
    public let headers: [String: String]
    public let body: String?

    public init(method: HTTPMethod, path: String, headers: [String: String] = [:], body: String? = nil) {
        self.method = method
        self.path = path
        self.headers = headers
        self.body = body
    }
}

public enum MatchResult: Sendable {
    case matched(endpoint: Endpoint, scenario: Scenario)
    case noMatch
}

/// The fully-resolved plan for answering a request: the concrete status/headers/body to write,
/// the effective delay to apply before writing, and the matched identifiers for the request log.
///
/// Producing this in Domain (rather than inside the Vapor handler) keeps response resolution —
/// matching, scenario selection, and delay arithmetic — pure and unit-testable without a server.
public struct ResolvedResponse: Sendable, Equatable {
    public let statusCode: Int
    public let headers: [String: String]
    public let contentType: Scenario.ContentType
    public let body: String?
    public let delayMs: Int
    public let matchedEndpointID: UUID?
    public let matchedScenarioID: UUID?
    /// Set when the plan is to fail at the transport level instead of writing a response.
    /// The status/headers/body above are then only carried for logging.
    public let failure: NetworkFailure?
    public let matchedJourneyID: UUID?
    public let matchedJourneyStepID: UUID?
    /// What answered — named rather than inferred from the ids above, so "nothing was configured"
    /// stays distinguishable from "a journey answered".
    public let outcome: RequestOutcome

    public init(
        statusCode: Int,
        headers: [String: String],
        contentType: Scenario.ContentType,
        body: String?,
        delayMs: Int,
        matchedEndpointID: UUID?,
        matchedScenarioID: UUID?,
        failure: NetworkFailure? = nil,
        matchedJourneyID: UUID? = nil,
        matchedJourneyStepID: UUID? = nil,
        outcome: RequestOutcome = .endpoint
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.contentType = contentType
        self.body = body
        self.delayMs = delayMs
        self.matchedEndpointID = matchedEndpointID
        self.matchedScenarioID = matchedScenarioID
        self.failure = failure
        self.matchedJourneyID = matchedJourneyID
        self.matchedJourneyStepID = matchedJourneyStepID
        self.outcome = outcome
    }

    /// The canonical response when no endpoint matched.
    public static let notFound = ResolvedResponse(
        statusCode: 404,
        headers: [:],
        contentType: .plainText,
        body: "No mock endpoint matched.",
        delayMs: 0,
        matchedEndpointID: nil,
        matchedScenarioID: nil,
        outcome: .unmatched
    )

    /// The response for a request an active journey refused because it isn't part of the script.
    /// Distinct copy from ``notFound`` so a blocked call is obvious in the request log.
    public static let journeyBlocked = ResolvedResponse(
        statusCode: 404,
        headers: [:],
        contentType: .plainText,
        body: "Request is not part of the active journey.",
        delayMs: 0,
        matchedEndpointID: nil,
        matchedScenarioID: nil,
        outcome: .blockedByJourney
    )
}

/// How well a candidate matches, ranked so the most specific wins.
///
/// Ordering is lexicographic and deliberate: a candidate that discriminated on the *body* beats one
/// that only matched the route, no matter how many literal path segments the latter has. That is what
/// keeps a bare `POST /graphql` working as a catch-all while named operations take precedence over it.
public struct MatchSpecificity: Comparable, Sendable, Equatable {
    /// The candidate named a GraphQL operation and the request asked for it.
    public let matchedOperation: Bool
    /// Literal (non-`:wildcard`) path segments matched.
    public let literalSegments: Int

    public init(matchedOperation: Bool, literalSegments: Int) {
        self.matchedOperation = matchedOperation
        self.literalSegments = literalSegments
    }

    public static func < (lhs: MatchSpecificity, rhs: MatchSpecificity) -> Bool {
        if lhs.matchedOperation != rhs.matchedOperation { return !lhs.matchedOperation }
        return lhs.literalSegments < rhs.literalSegments
    }
}

public enum RequestMatcher {

    /// Whether a candidate declaring `graphqlOperation` applies to this request, and how specifically.
    ///
    /// Returns `nil` when the candidate names an operation the request is not asking for — that is a
    /// non-match, not a weak match, so a mock for `GetAccountSummary` never answers a `SendPayment`.
    static func operationSpecificity(
        declared: String?,
        request: IncomingRequest
    ) -> Bool? {
        guard let declared, !declared.isEmpty else { return false }
        guard let operation = GraphQLRequest.operation(inBody: request.body) else { return nil }
        return operation.name == declared ? true : nil
    }
    /// Selects the best endpoint for a request. When several endpoints match, the **most specific**
    /// wins — an endpoint with more literal (non-`:wildcard`) segments beats one with fewer, so a
    /// literal route like `/users/me` is preferred over `/users/:id` regardless of declaration order.
    /// Ties (equal specificity) resolve to the first declared endpoint.
    public static func match(request: IncomingRequest, against endpoints: [Endpoint]) -> MatchResult {
        var best: (endpoint: Endpoint, scenario: Scenario, specificity: MatchSpecificity)?

        for endpoint in endpoints {
            guard endpoint.method == request.method else { continue }
            guard let segments = PathPattern.specificity(requestPath: request.path, pattern: endpoint.path) else { continue }
            guard let matchedOperation = operationSpecificity(declared: endpoint.graphqlOperation, request: request)
            else { continue }
            guard let activeID = endpoint.activeScenarioID else { continue }
            guard let scenario = endpoint.scenarios.first(where: { $0.id == activeID }) else { continue }

            let specificity = MatchSpecificity(matchedOperation: matchedOperation, literalSegments: segments)
            if best == nil || specificity > best!.specificity {
                best = (endpoint, scenario, specificity)
            }
        }

        if let best {
            return .matched(endpoint: best.endpoint, scenario: best.scenario)
        }
        return .noMatch
    }

    /// Resolves a request into the concrete response to serve, combining the matched scenario with
    /// the effective delay. The effective delay is the global (network-simulation) delay plus the
    /// endpoint's own delay — both are additive, mirroring how a slow network and a slow endpoint
    /// stack in the real world. Unmatched requests resolve to a fast `404` (no delay) so missing
    /// mocks stay obvious during debugging.
    public static func resolve(
        request: IncomingRequest,
        against endpoints: [Endpoint],
        globalDelayMs: Int
    ) -> ResolvedResponse {
        switch match(request: request, against: endpoints) {
        case let .matched(endpoint, scenario):
            return ResolvedResponse(
                statusCode: scenario.statusCode,
                headers: scenario.headers,
                contentType: scenario.bodyContentType,
                body: scenario.body,
                delayMs: max(0, globalDelayMs) + max(0, endpoint.delayMs),
                matchedEndpointID: endpoint.id,
                matchedScenarioID: scenario.id,
                outcome: .endpoint
            )
        case .noMatch:
            return .notFound
        }
    }
}
