import Foundation

/// An ordered script of responses that reproduces a complete application scenario.
///
/// Endpoints answer the question *"what does `GET /account-summary` return?"*. A journey answers
/// the harder one: *"what does it return **the second time**, after the retry?"* — the response
/// depends on where the request falls in the flow, not only on the route. That makes flows like
/// "login succeeds, the first account load fails, the retry succeeds" reproducible and
/// deterministic for UI tests, integration tests, and AI agents.
///
/// A journey does not replace endpoints; it *overlays* them. Requests the journey has nothing to
/// say about keep resolving through the endpoint's active scenario (see ``JourneyUnmatchedBehavior``),
/// so a journey only needs to script the steps that actually matter to the scenario under test.
public struct Journey: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    /// Free-form description of the scenario. Surfaced to CLI/AI callers so a journey explains
    /// itself without reading its steps.
    public var summary: String?
    public var steps: [JourneyStep]
    public var matchMode: JourneyMatchMode
    public var completion: JourneyCompletion
    public var unmatchedBehavior: JourneyUnmatchedBehavior
    /// When `false` a served step stays current until something advances it explicitly
    /// (`journey advance` from the CLI, or the run-control UI), so a state can be held across
    /// many requests — useful for "backend is in maintenance mode until I say otherwise".
    public var autoAdvance: Bool

    public init(
        id: UUID = UUID(),
        name: String,
        summary: String? = nil,
        steps: [JourneyStep] = [],
        matchMode: JourneyMatchMode = .orderedPerEndpoint,
        completion: JourneyCompletion = .stop,
        unmatchedBehavior: JourneyUnmatchedBehavior = .fallThroughToEndpoints,
        autoAdvance: Bool = true
    ) {
        self.id = id
        self.name = name
        self.summary = summary
        self.steps = steps
        self.matchMode = matchMode
        self.completion = completion
        self.unmatchedBehavior = unmatchedBehavior
        self.autoAdvance = autoAdvance
    }
}

/// How a request is paired with a step.
///
/// Real clients fire requests concurrently and in orders no script can predict, so the default is
/// deliberately forgiving: order is enforced *per route*, not globally.
public enum JourneyMatchMode: String, Codable, Sendable, CaseIterable {
    /// Only the step at the cursor may match. A request for any other route takes
    /// ``JourneyUnmatchedBehavior`` and leaves the cursor untouched. Use when the test *is* the
    /// call order — e.g. asserting a client never skips the MFA challenge.
    case strictSequence

    /// The earliest unexhausted step at or after the cursor that matches the request wins, even if
    /// earlier steps for *other* routes are still pending. Two `GET /account-summary` steps are
    /// therefore consumed first-fail-then-succeed regardless of whether `/inbox` was fetched in
    /// between. This is the default because it survives real client concurrency.
    case orderedPerEndpoint
}

/// What happens once every step has been exhausted.
public enum JourneyCompletion: String, Codable, Sendable, CaseIterable {
    /// The journey stays complete; later requests take ``JourneyUnmatchedBehavior``.
    case stop
    /// The run state resets and the journey replays from step one — a loop for soak tests.
    case restart
}

/// What to serve for a request the journey has no step for.
public enum JourneyUnmatchedBehavior: String, Codable, Sendable, CaseIterable {
    /// Resolve normally against the project's endpoints. The journey scripts only what matters.
    case fallThroughToEndpoints
    /// Answer `404`. Makes an unscripted call fail loudly — the strict mode for "this flow must
    /// make exactly these calls".
    case notFound
}

/// One scripted response in a journey.
///
/// `method` + `path` are matched with the same rules as an ``Endpoint`` (`:param` wildcards, most
/// specific wins), so a step can target `/users/:id` without knowing the id the client will send.
public struct JourneyStep: Identifiable, Codable, Sendable, Equatable {
    public let id: UUID
    public var name: String
    public var method: HTTPMethod
    public var path: String
    public var outcome: JourneyStepOutcome
    /// Artificial delay for this step alone. Added to the project's global delay, mirroring how a
    /// slow network and a slow call stack in production.
    public var delayMs: Int
    /// How many times this step answers before the journey moves on. `3` models a poll that stays
    /// `202 Pending` for three calls before flipping to `200`.
    public var repeatCount: Int
    /// Matches only requests asking for this GraphQL operation.
    ///
    /// Without it every step of a GraphQL flow would look identical — same method, same path — and
    /// the journey could not tell them apart.
    public var graphqlOperation: String?

    public init(
        id: UUID = UUID(),
        name: String,
        method: HTTPMethod = .get,
        path: String,
        outcome: JourneyStepOutcome,
        delayMs: Int = 0,
        repeatCount: Int = 1,
        graphqlOperation: String? = nil
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.path = path
        self.outcome = outcome
        self.delayMs = delayMs
        self.repeatCount = max(1, repeatCount)
        self.graphqlOperation = graphqlOperation
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, method, path, outcome, delayMs, repeatCount, graphqlOperation
    }

    /// Hand-written so journey files written before GraphQL matching existed still load.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        method = try container.decodeIfPresent(HTTPMethod.self, forKey: .method) ?? .get
        path = try container.decode(String.self, forKey: .path)
        outcome = try container.decode(JourneyStepOutcome.self, forKey: .outcome)
        delayMs = try container.decodeIfPresent(Int.self, forKey: .delayMs) ?? 0
        repeatCount = max(1, try container.decodeIfPresent(Int.self, forKey: .repeatCount) ?? 1)
        graphqlOperation = try container.decodeIfPresent(String.self, forKey: .graphqlOperation)
    }
}

/// What a step does when it is reached: answer, or fail the way a network fails.
public enum JourneyStepOutcome: Codable, Sendable, Equatable {
    case respond(JourneyResponse)
    case networkFailure(NetworkFailure)

    /// The status a client would observe, or `nil` for outcomes that never produce one.
    /// Used for logging and CLI/UI summaries.
    public var observedStatusCode: Int? {
        switch self {
        case let .respond(response): response.statusCode
        case .networkFailure: nil
        }
    }
}

/// A concrete HTTP answer scripted by a step.
public struct JourneyResponse: Codable, Sendable, Equatable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: String?
    public var contentType: Scenario.ContentType

    public init(
        statusCode: Int = 200,
        headers: [String: String] = [:],
        body: String? = nil,
        contentType: Scenario.ContentType = .json
    ) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

/// A transport-level failure — the cases a status code cannot express.
///
/// These are the responses client code most often gets wrong: an HTTP 500 is a *reply*, but a
/// dropped socket or a stalled request exercises entirely different error paths (retry policy,
/// timeout configuration, offline banners).
public enum NetworkFailure: Codable, Sendable, Equatable {
    /// Accept the request, then abort the connection mid-response. The client sees a reset /
    /// truncated body rather than a status code.
    case connectionDrop
    /// Hold the connection open without answering for `holdMs`, then drop it — the client's own
    /// timeout fires first, which is exactly what a timeout test needs.
    case timeout(holdMs: Int)

    /// The default hold for a timeout step: long enough to outlast typical client timeouts
    /// (URLSession defaults to 60s) without stalling a test run forever.
    public static let defaultTimeoutHoldMs = 30_000

    public static var timeout: NetworkFailure { .timeout(holdMs: defaultTimeoutHoldMs) }
}
