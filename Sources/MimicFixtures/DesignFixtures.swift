#if DEBUG
import Domain
import Foundation

/// The data the design canvas draws, as Mimic values.
///
/// Every artboard in `Design/Canvas` shows one project, "Acme Storefront" on port 18086, with the same
/// endpoints, scenarios, journey and request log. A section rendered from these fixtures shows what
/// its artboard shows, so the difference between the two is the section's own, not the data's.
///
/// Identifiers are fixed, so a snapshot and a fidelity report are stable from run to run.
public enum DesignFixtures {
    public static let projectName = "Acme Storefront"
    public static let port = 18_086
    /// The wall-clock moment the artboards' request log was captured, 21:46:12.418 local time.
    public static let now: Date = {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = .current
        components.year = 2026
        components.month = 9
        components.day = 28
        components.hour = 21
        components.minute = 46
        components.second = 12
        components.nanosecond = 418_000_000
        return components.date ?? Date(timeIntervalSinceReferenceDate: 0)
    }()

    // MARK: - Endpoints

    /// `GET /products`, the endpoint every workspace artboard has selected.
    public static let products = Endpoint(
        id: uuid(1),
        name: "Products",
        method: .get,
        path: "/products",
        scenarios: [
            Scenario(id: uuid(101), name: "Default", statusCode: 200,
                     body: #"{"products":[{"id":"p_42","name":"Canvas Tote","price":39.5}]}"#),
            Scenario(
                id: uuid(102),
                name: "Out of stock",
                statusCode: 503,
                headers: ["Retry-After": "3600", "Content-Type": "application/json"],
                body: """
                {
                  "error": {
                    "code": "OUT_OF_STOCK",
                    "message": "Canvas Tote is out of stock",
                    "retryAfter": 3600,
                    "restockExpected": null
                  },
                  "products": [],
                  "partial": true
                }
                """
            ),
            Scenario(id: uuid(103), name: "Slow catalogue", statusCode: 200, body: #"{"products":[]}"#),
            Scenario(id: uuid(104), name: "Empty catalogue", statusCode: 200, body: #"{"products":[]}"#),
            Scenario(id: uuid(105), name: "Rate limited", statusCode: 429, body: #"{"error":"rate_limited"}"#),
        ],
        activeScenarioID: uuid(101),
        delayMs: 800,
        groupTag: "Catalog"
    )

    /// The endpoint list the navigator draws, in the artboard's order.
    public static let endpoints: [Endpoint] = [
        products,
        endpoint(2, "Product", .get, "/products/:id", group: "Catalog"),
        endpoint(3, "Search", .get, "/products/search", group: "Catalog"),
        endpoint(4, "Add to cart", .post, "/cart", group: "Catalog", status: 201),
        endpoint(5, "Account summary", .get, "/account-summary", group: "Account"),
        endpoint(6, "Update profile", .patch, "/account/profile", group: "Account", status: 401),
        endpoint(7, "Sign out", .delete, "/session", group: "Account", status: 204),
        endpoint(8, "Pay", .post, "/payments", group: "Payments", status: 503),
        endpoint(9, "Payment", .get, "/payments/:id", group: "Payments"),
        endpoint(10, "Refund", .put, "/payments/:id/refund", group: "Payments"),
    ]

    /// The scenario the endpoint editor artboard is editing: "Out of stock", not live.
    public static var editedScenario: Scenario { products.scenarios[1] }

    // MARK: - Journeys

    /// "Payment retry": the journey the journeys artboard is editing. Its run is on step 3, after
    /// the sign-in and the account summary were served once each.
    public static let paymentRetry = Journey(
        id: uuid(201),
        name: "Payment retry",
        summary: "The first payment drops the connection, the retry succeeds.",
        groupTag: "Checkout",
        steps: [
            JourneyStep(id: uuid(211), name: "Sign in", method: .post, path: "/login",
                        outcome: .respond(JourneyResponse(statusCode: 200, body: #"{"token":"t_1"}"#))),
            JourneyStep(id: uuid(212), name: "Account summary", method: .get, path: "/account-summary",
                        outcome: .respond(JourneyResponse(statusCode: 200, body: #"{"balance":2400}"#))),
            JourneyStep(id: uuid(213), name: "Payment dropped", method: .post, path: "/payments",
                        outcome: .networkFailure(.connectionDrop), delayMs: 5_000),
            editedStep,
            JourneyStep(id: uuid(215), name: "Receipt", method: .get, path: "/payments/:id",
                        outcome: .respond(JourneyResponse(statusCode: 200, body: #"{"status":"succeeded"}"#)),
                        repeatCount: 3),
        ]
    )

    /// The retry that succeeds: Payment retry's fourth step, as the journey step artboard's sheet
    /// edits it. The artboard titles that sheet "Edit step 3".
    public static let editedStep = JourneyStep(
        id: uuid(214),
        name: "",
        method: .post,
        path: "/payments",
        outcome: .respond(JourneyResponse(
            statusCode: 201,
            headers: ["Content-Type": "application/json"],
            body: """
            {
              "id": "pay_8Hf2kQ",
              "status": "succeeded",
              "amount": 2400,
              "currency": "eur",
              "retried": true,
              "receiptUrl": null
            }
            """
        ))
    )

    /// Payment retry's run as the artboard shows it: steps 1 and 2 served once, step 3 waiting.
    public static let paymentRetryRun = JourneyRunState(
        journeyID: paymentRetry.id,
        cursor: 2,
        servedCountsByStepID: [uuid(211).uuidString: 1, uuid(212).uuidString: 1],
        forceAdvancedStepIDs: [],
        isComplete: false,
        totalServed: 2
    )

    /// Where Payment retry's run has got to, as the editor, inspector and navigator draw it.
    public static var paymentRetryStatus: JourneyStatus {
        JourneyStatus.make(journey: paymentRetry, state: paymentRetryRun)
    }

    /// The journey list, in the artboard's order: Checkout, then Account, then Resilience.
    public static let journeys: [Journey] = [
        paymentRetry,
        journey(202, "Card declined twice", group: "Checkout", .post, "/payments", status: 402),
        journey(203, "Session expiry", group: "Account", .patch, "/account/profile", status: 401),
        journey(204, "Retry after failure", group: "Account", .get, "/account-summary", status: 500),
        journey(205, "Offline recovery", group: "Resilience", .get, "/products", status: 503),
        journey(206, "Maintenance window", group: "Resilience", .get, "/status", status: 503),
    ]

    // MARK: - Project

    public static var serverConfiguration: ServerConfiguration {
        ServerConfiguration(port: port, globalDelayMs: 0, upstreamURL: "https://api.acme.example",
                            primaryName: "Storefront")
    }

    /// The server settings board: Storefront, plus a Payments port moved to 18087 that the running
    /// server picks up on its next restart.
    public static var serverSettingsConfiguration: ServerConfiguration {
        ServerConfiguration(port: port, globalDelayMs: 0, upstreamURL: "https://api.acme.shop",
                            backends: [BackendConfiguration(id: uuid(950), name: "Payments", port: 18_087)],
                            primaryName: "Storefront")
    }

    /// What the running server bound before Payments moved.
    public static var serverSettingsBoundConfiguration: ServerConfiguration {
        var configuration = serverSettingsConfiguration
        configuration.backends[0].port = 18_088
        return configuration
    }

    /// The whole project, as the workspace artboards show it.
    public static var project: MockProject {
        MockProject(
            id: uuid(9_999),
            name: projectName,
            serverConfiguration: serverConfiguration,
            endpoints: endpoints,
            journeys: journeys,
            createdAt: now,
            modifiedAt: now
        )
    }

    /// A project with nothing in it yet, as the first-run artboard shows it.
    public static var emptyProject: MockProject {
        MockProject(id: uuid(900), name: "Weather API", serverConfiguration: ServerConfiguration(port: 8080, globalDelayMs: 0),
                    createdAt: now, modifiedAt: now)
    }

    // MARK: - Welcome

    /// The version the welcome artboard shows.
    public static let appVersion = "1.9"

    /// The welcome window's recent projects, as the artboard lists them.
    ///
    /// The ids pick each monogram tile's colour (`tileIndex` sums the id's bytes), so they are chosen
    /// to give the artboard's blue, green, purple and orange in order.
    public static var recentProjects: [RecentProjectEntry] {
        let day: TimeInterval = 86_400
        return [
            RecentProjectEntry(id: uuid(9_997), name: projectName, lastOpenedAt: now,
                               summary: .init(ports: [port], endpointCount: 12, journeyCount: 3)),
            RecentProjectEntry(id: uuid(9_998), name: "Weather API", lastOpenedAt: now.addingTimeInterval(-day),
                               summary: .init(ports: [8080], endpointCount: 4, journeyCount: 0)),
            RecentProjectEntry(id: uuid(9_999), name: "Banking iOS", lastOpenedAt: now.addingTimeInterval(-7 * day),
                               summary: .init(ports: [9000, 9001], endpointCount: 38, journeyCount: 7)),
            RecentProjectEntry(id: uuid(9_996), name: "GraphQL Gateway", lastOpenedAt: now.addingTimeInterval(-14 * day),
                               summary: .init(ports: [4000], endpointCount: 9, journeyCount: 0)),
        ]
    }

    // MARK: - Request log

    /// The ten rows the request log artboard shows, newest first as drawn; the log itself stores
    /// them oldest first, so this is reversed.
    public static var requestLogs: [RequestLog] {
        let rows: [(Double, HTTPMethod, String, Int, UUID?, UUID?, Int, RequestOutcome)] = [
            (0.000, .get, "/products", 503, uuid(1), uuid(102), 803, .endpoint),
            (0.038, .get, "/products/42", 200, uuid(2), nil, 8, .endpoint),
            (0.516, .post, "/cart", 201, uuid(4), nil, 24, .endpoint),
            (2.263, .get, "/recommendations?limit=4", 404, nil, nil, 2, .unmatched),
            (2.647, .post, "/payments", 503, uuid(8), nil, 1_200, .endpoint),
            (3.414, .get, "/account-summary", 200, uuid(5), nil, 15, .endpoint),
            (3.768, .patch, "/account/profile", 401, uuid(6), nil, 6, .endpoint),
            (4.206, .get, "/products/search?q=tote", 200, uuid(3), nil, 11, .endpoint),
            (4.887, .get, "/cdn/fonts/inter.woff2", 302, nil, nil, 41, .passthrough),
            (5.438, .delete, "/session", 204, uuid(7), nil, 3, .endpoint),
        ]
        let logs = rows.enumerated().map { index, row in
            RequestLog(
                id: uuid(300 + index),
                timestamp: now.addingTimeInterval(-row.0),
                method: row.1,
                path: row.2,
                listenerPort: port,
                durationMs: row.6,
                requestHeaders: ["Accept": "application/json", "User-Agent": "AcmeStorefront/4.2"],
                matchedEndpointID: row.4,
                matchedScenarioID: row.5,
                responseStatusCode: row.3,
                responseHeaders: ["Content-Type": "application/json"],
                responseBody: row.3 == 503 ? products.scenarios[1].body : #"{"ok":true}"#,
                outcome: row.7
            )
        }
        return Array(logs.reversed())
    }

    /// The last fifteen minutes of `GET /products`, as the inspector's Traffic section draws them:
    /// 128 served and 3 errors, at a 12 ms median, ending at `now`. Oldest minute first.
    ///
    /// The artboard's last three bars are red and about half the chart's height, which three errors
    /// can't reach beside a 16-request minute; here each of those minutes holds one error.
    public static var productsTraffic: [RequestLog] {
        let minutes: [(served: Int, errors: Int)] = [
            (5, 0), (8, 0), (7, 0), (11, 0), (9, 0), (13, 0), (11, 0), (14, 0),
            (10, 0), (12, 0), (16, 0), (12, 0), (0, 1), (0, 1), (0, 1),
        ]
        var logs: [RequestLog] = []
        for (index, minute) in minutes.enumerated() {
            let minutesAgo = Double(minutes.count - 1 - index)
            for request in 0..<(minute.served + minute.errors) {
                let isError = request >= minute.served
                logs.append(RequestLog(
                    id: uuid(5_000 + logs.count),
                    timestamp: now.addingTimeInterval(-(minutesAgo * 60 + 1 + Double(request))),
                    method: .get,
                    path: products.path,
                    listenerPort: port,
                    durationMs: 12,
                    matchedEndpointID: products.id,
                    matchedScenarioID: isError ? uuid(102) : uuid(101),
                    responseStatusCode: isError ? 503 : 200
                ))
            }
        }
        return logs
    }

    // MARK: - Helpers

    private static func journey(
        _ number: Int,
        _ name: String,
        group: String,
        _ method: HTTPMethod,
        _ path: String,
        status: Int
    ) -> Journey {
        Journey(id: uuid(number), name: name, groupTag: group, steps: [
            JourneyStep(id: uuid(number * 10 + 1), name: name, method: method, path: path,
                        outcome: .respond(JourneyResponse(statusCode: status))),
            JourneyStep(id: uuid(number * 10 + 2), name: "Recovered", method: method, path: path,
                        outcome: .respond(JourneyResponse(statusCode: 200))),
        ])
    }

    private static func endpoint(
        _ number: Int,
        _ name: String,
        _ method: HTTPMethod,
        _ path: String,
        group: String,
        status: Int = 200
    ) -> Endpoint {
        let scenario = Scenario(id: uuid(1_000 + number), name: "Default", statusCode: status)
        return Endpoint(
            id: uuid(number),
            name: name,
            method: method,
            path: path,
            scenarios: [scenario],
            activeScenarioID: scenario.id,
            groupTag: group
        )
    }

    /// A fixed identifier: `00000000-0000-0000-0000-00000000NNNN`.
    public static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", number)) ?? UUID()
    }
}
#endif
