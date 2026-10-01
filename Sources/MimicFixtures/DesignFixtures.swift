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

    /// "Payment retry": the journey the journeys artboard is editing, three steps in.
    public static let paymentRetry = Journey(
        id: uuid(201),
        name: "Payment retry",
        summary: "The first payment fails, the retry succeeds.",
        groupTag: "Checkout",
        steps: [
            JourneyStep(id: uuid(211), name: "Add to cart", method: .post, path: "/cart",
                        outcome: .respond(JourneyResponse(statusCode: 201, body: #"{"items":1}"#))),
            JourneyStep(id: uuid(212), name: "Payment declined", method: .post, path: "/payments",
                        outcome: .respond(JourneyResponse(statusCode: 402, body: #"{"error":"card_declined"}"#))),
            JourneyStep(id: uuid(213), name: "Payment accepted", method: .post, path: "/payments",
                        outcome: .respond(JourneyResponse(statusCode: 200, body: #"{"status":"paid"}"#)),
                        delayMs: 250),
            JourneyStep(id: uuid(214), name: "Order confirmed", method: .get, path: "/payments/:id",
                        outcome: .respond(JourneyResponse(statusCode: 200, body: #"{"status":"confirmed"}"#))),
        ]
    )

    public static let journeys: [Journey] = [
        paymentRetry,
        Journey(id: uuid(202), name: "Guest checkout", groupTag: "Checkout", steps: [
            JourneyStep(id: uuid(221), name: "Add to cart", method: .post, path: "/cart",
                        outcome: .respond(JourneyResponse(statusCode: 201))),
        ]),
        Journey(id: uuid(203), name: "Session expiry", groupTag: "Account", steps: [
            JourneyStep(id: uuid(231), name: "Profile rejected", method: .patch, path: "/account/profile",
                        outcome: .respond(JourneyResponse(statusCode: 401))),
        ]),
    ]

    // MARK: - Project

    public static var serverConfiguration: ServerConfiguration {
        ServerConfiguration(port: port, globalDelayMs: 0, upstreamURL: "https://api.acme.example",
                            primaryName: "Storefront")
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

    /// The welcome window's recent projects, as the artboard lists them.
    public static var recentProjects: [RecentProjectEntry] {
        let day: TimeInterval = 86_400
        return [
            RecentProjectEntry(id: uuid(9_999), name: projectName, lastOpenedAt: now,
                               summary: .init(ports: [port], endpointCount: 12, journeyCount: 3)),
            RecentProjectEntry(id: uuid(9_998), name: "Weather API", lastOpenedAt: now.addingTimeInterval(-day),
                               summary: .init(ports: [8080], endpointCount: 4, journeyCount: 0)),
            RecentProjectEntry(id: uuid(9_997), name: "Banking iOS", lastOpenedAt: now.addingTimeInterval(-7 * day),
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

    // MARK: - Helpers

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
