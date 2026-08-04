import Foundation

/// Ready-made journeys for the scenarios teams actually need to reproduce.
///
/// Writing a journey by hand is a few minutes of JSON; picking one off a shelf is a second. These
/// exist so `mimic journey add-template session-expiry` is a complete answer to "make my app show
/// the re-login screen", and so an agent has concrete, correct examples of the step vocabulary to
/// imitate when it writes its own.
///
/// Paths are conventional placeholders (`/login`, `/account-summary`) — a template is a starting
/// point to retarget, not a contract with any particular backend.
public enum JourneyTemplates {

    public struct Template: Codable, Sendable, Equatable, Identifiable {
        /// Stable kebab-case handle used by the CLI.
        public let id: String
        public let title: String
        public let summary: String
        public let spec: JourneySpec

        public init(id: String, title: String, summary: String, spec: JourneySpec) {
            self.id = id
            self.title = title
            self.summary = summary
            self.spec = spec
        }
    }

    public static func template(id: String) -> Template? {
        all.first { $0.id.caseInsensitiveCompare(id) == .orderedSame }
    }

    public static let all: [Template] = [
        retryAfterFailure,
        paymentRetry,
        sessionExpiry,
        mfaChallenge,
        maintenanceWindow,
        progressiveLoading,
        offlineToOnline,
        featureFlagRollout,
        edgeCaseResponses,
    ]

    // MARK: - Templates

    /// The canonical example: login works, the first data load fails, the user navigates away, and
    /// the retry succeeds.
    public static let retryAfterFailure = Template(
        id: "retry-after-failure",
        title: "Retry after failure",
        summary: "Login succeeds, the first account load fails with 500, the user opens the inbox, and the retry succeeds.",
        spec: JourneySpec(
            summary: "Login succeeds, the first account load fails, the retry succeeds.",
            steps: [
                JourneyStepSpec(
                    name: "Login succeeds",
                    method: .post,
                    path: "/login",
                    statusCode: 200,
                    body: #"{"token":"mimic-session-token","userId":"u_1001"}"#
                ),
                JourneyStepSpec(
                    name: "Account summary fails",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 500,
                    body: #"{"error":"internal_error","message":"Summary service unavailable"}"#
                ),
                JourneyStepSpec(
                    name: "Inbox loads",
                    method: .get,
                    path: "/inbox",
                    statusCode: 200,
                    body: #"{"messages":[{"id":"m_1","subject":"Welcome"}]}"#
                ),
                JourneyStepSpec(
                    name: "Account summary recovers",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 200,
                    body: #"{"balance":1520.44,"currency":"USD","accounts":2}"#
                ),
            ]
        )
    )

    public static let paymentRetry = Template(
        id: "payment-retry",
        title: "Payment succeeds on retry",
        summary: "The first charge is declined by the processor; the second attempt clears.",
        spec: JourneySpec(
            summary: "First payment attempt declines, the retry is accepted.",
            steps: [
                JourneyStepSpec(
                    name: "First charge declined",
                    method: .post,
                    path: "/payments",
                    statusCode: 402,
                    body: #"{"error":"card_declined","declineCode":"insufficient_funds","retryable":true}"#
                ),
                JourneyStepSpec(
                    name: "Retry accepted",
                    method: .post,
                    path: "/payments",
                    statusCode: 201,
                    body: #"{"paymentId":"pay_88f2","status":"succeeded","amount":4999,"currency":"USD"}"#
                ),
            ]
        )
    )

    public static let sessionExpiry = Template(
        id: "session-expiry",
        title: "Session expires mid-flow",
        summary: "Two calls succeed, then the session goes stale with a 401 until the token is refreshed.",
        spec: JourneySpec(
            summary: "The session expires partway through a flow and recovers after a refresh.",
            steps: [
                JourneyStepSpec(name: "Login succeeds", method: .post, path: "/login", statusCode: 200, body: #"{"token":"expiring-token"}"#),
                JourneyStepSpec(name: "First load succeeds", method: .get, path: "/account-summary", statusCode: 200, body: #"{"balance":812.00}"#),
                JourneyStepSpec(
                    name: "Session expired",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 401,
                    headers: ["WWW-Authenticate": "Bearer error=\"invalid_token\""],
                    body: #"{"error":"token_expired"}"#
                ),
                JourneyStepSpec(name: "Token refreshed", method: .post, path: "/auth/refresh", statusCode: 200, body: #"{"token":"fresh-token"}"#),
                JourneyStepSpec(name: "Load succeeds again", method: .get, path: "/account-summary", statusCode: 200, body: #"{"balance":812.00}"#),
            ]
        )
    )

    public static let mfaChallenge = Template(
        id: "mfa-challenge",
        title: "MFA required after login",
        summary: "Login answers 401 with an MFA challenge; verification then issues the session.",
        spec: JourneySpec(
            summary: "Login requires a second factor before the session is issued.",
            steps: [
                JourneyStepSpec(
                    name: "MFA challenge issued",
                    method: .post,
                    path: "/login",
                    statusCode: 401,
                    body: #"{"error":"mfa_required","challengeId":"ch_7781","methods":["totp","sms"]}"#
                ),
                JourneyStepSpec(
                    name: "Wrong code rejected",
                    method: .post,
                    path: "/login/mfa",
                    statusCode: 422,
                    body: #"{"error":"invalid_code","attemptsRemaining":2}"#
                ),
                JourneyStepSpec(
                    name: "Correct code accepted",
                    method: .post,
                    path: "/login/mfa",
                    statusCode: 200,
                    body: #"{"token":"mimic-session-token","mfa":"totp"}"#
                ),
            ]
        )
    )

    public static let maintenanceWindow = Template(
        id: "maintenance-window",
        title: "Backend maintenance mode",
        summary: "Every call answers 503 with Retry-After until you advance the journey — a held state, not a sequence.",
        spec: JourneySpec(
            summary: "Holds the backend in maintenance mode until the journey is advanced manually.",
            // autoAdvance off: the step keeps answering, so the app stays in maintenance mode for as
            // long as the test needs, and `mimic journey advance` is the "bring it back up" switch.
            autoAdvance: false,
            steps: [
                JourneyStepSpec(
                    name: "Maintenance mode",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 503,
                    headers: ["Retry-After": "120"],
                    body: #"{"error":"service_unavailable","message":"Scheduled maintenance until 04:00 UTC"}"#
                ),
                JourneyStepSpec(
                    name: "Back online",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 200,
                    body: #"{"balance":1520.44,"currency":"USD"}"#
                ),
            ]
        )
    )

    public static let progressiveLoading = Template(
        id: "progressive-loading",
        title: "Progressive loading states",
        summary: "A job polls 202 three times with a slow response, then completes with 200.",
        spec: JourneySpec(
            summary: "A long-running job reports progress before completing.",
            steps: [
                JourneyStepSpec(
                    name: "Job accepted",
                    method: .post,
                    path: "/reports",
                    statusCode: 202,
                    body: #"{"jobId":"job_44","status":"queued"}"#
                ),
                JourneyStepSpec(
                    name: "Still processing",
                    method: .get,
                    path: "/reports/:id",
                    statusCode: 202,
                    body: #"{"jobId":"job_44","status":"processing","progress":0.35}"#,
                    delayMs: 400,
                    // One step, three polls: exactly the shape a spinner test needs.
                    repeatCount: 3
                ),
                JourneyStepSpec(
                    name: "Report ready",
                    method: .get,
                    path: "/reports/:id",
                    statusCode: 200,
                    body: #"{"jobId":"job_44","status":"complete","url":"/reports/job_44.pdf"}"#
                ),
            ]
        )
    )

    public static let offlineToOnline = Template(
        id: "offline-to-online",
        title: "Offline then online",
        summary: "The connection drops, then times out, then recovers — the three distinct failure paths a client must handle.",
        spec: JourneySpec(
            summary: "Transport failures followed by recovery.",
            steps: [
                JourneyStepSpec(
                    name: "Connection dropped",
                    method: .get,
                    path: "/account-summary",
                    failure: .connectionDrop
                ),
                JourneyStepSpec(
                    name: "Request times out",
                    method: .get,
                    path: "/account-summary",
                    failure: .timeout(holdMs: 15_000)
                ),
                JourneyStepSpec(
                    name: "Back online",
                    method: .get,
                    path: "/account-summary",
                    statusCode: 200,
                    body: #"{"balance":1520.44,"currency":"USD"}"#
                ),
            ]
        )
    )

    public static let featureFlagRollout = Template(
        id: "feature-flag-rollout",
        title: "Feature flag variations",
        summary: "The flag payload flips from off to on between fetches, so both branches are exercised in one run.",
        spec: JourneySpec(
            summary: "Feature flags change between fetches.",
            steps: [
                JourneyStepSpec(
                    name: "Flags off",
                    method: .get,
                    path: "/feature-flags",
                    statusCode: 200,
                    body: #"{"newDashboard":false,"instantTransfers":false}"#
                ),
                JourneyStepSpec(
                    name: "Flags on",
                    method: .get,
                    path: "/feature-flags",
                    statusCode: 200,
                    body: #"{"newDashboard":true,"instantTransfers":true}"#
                ),
            ]
        )
    )

    public static let edgeCaseResponses = Template(
        id: "edge-case-responses",
        title: "Edge-case API responses",
        summary: "Empty list, malformed JSON, 204, and rate limiting — the shapes that break optimistic parsers.",
        spec: JourneySpec(
            summary: "A tour of responses that break naive clients.",
            steps: [
                JourneyStepSpec(name: "Empty collection", method: .get, path: "/inbox", statusCode: 200, body: #"{"messages":[]}"#),
                JourneyStepSpec(
                    name: "Malformed JSON",
                    method: .get,
                    path: "/inbox",
                    statusCode: 200,
                    body: #"{"messages":[{"id":"m_1","subject":"Truncated"#
                ),
                JourneyStepSpec(name: "No content", method: .get, path: "/inbox", statusCode: 204, body: ""),
                JourneyStepSpec(
                    name: "Rate limited",
                    method: .get,
                    path: "/inbox",
                    statusCode: 429,
                    headers: ["Retry-After": "30", "X-RateLimit-Remaining": "0"],
                    body: #"{"error":"rate_limited"}"#
                ),
            ]
        )
    )
}
