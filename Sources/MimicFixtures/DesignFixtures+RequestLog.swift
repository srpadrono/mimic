#if DEBUG
import Domain
import Foundation

/// The request log the Main and RequestDetail boards draw: 142 requests, ten of them on screen.
///
/// Separate from ``DesignFixtures/requestLogs``, which the endpoint inspector's traffic reads, so the
/// request log can carry the boards' whole history without moving the inspector's numbers.
extension DesignFixtures {
    /// The serving port's name, as the request detail's Port row reads it: "Storefront · 18086".
    public static let requestLogPortName = "Storefront"

    /// The request the RequestDetail board has open: the unmatched `GET /recommendations?limit=4`.
    public static var requestLogDetailID: UUID { uuid(400) }

    /// The boards' 142 requests, oldest first as the log stores them.
    ///
    /// The newest ten are the rows the Main board draws, with their durations and sizes. Below them
    /// are the two other unmatched calls the RequestDetail board lists, and 130 quiet successes, so
    /// the header reads 142 and Unmatched 3. Errors reads 6: the board's 5 leaves out one of the
    /// three unmatched 404s.
    public static var requestLogHistory: [RequestLog] {
        var logs: [RequestLog] = []

        // 130 earlier successes, one every 2.5 s back from 21:46:00, interleaving the two older
        // unmatched calls at the times the RequestDetail board prints.
        let quiet: [(HTTPMethod, String, UUID, Int)] = [
            (.get, "/products", uuid(1), 214),
            (.get, "/products/42", uuid(2), 640),
            (.get, "/account-summary", uuid(5), 2_150),
            (.get, "/products/search?q=bag", uuid(3), 1_434),
        ]
        for index in 0..<130 {
            let row = quiet[index % quiet.count]
            logs.append(entry(
                id: 1_000 + index,
                secondsAgo: 12.418 + 2.5 * Double(130 - index),
                row.0, row.1, status: 200, endpoint: row.2, scenario: scenarioID(for: row.2),
                durationMs: 6 + index % 9, bytes: row.3
            ))
        }
        logs.append(entry(id: 401, secondsAgo: 304.8, .post, "/analytics/events", status: 404,
                          durationMs: 1, bytes: 0, outcome: .unmatched))
        logs.append(entry(id: 402, secondsAgo: 80.4, .get, "/wishlist", status: 404,
                          durationMs: 2, bytes: 0, outcome: .unmatched))
        logs.sort { $0.timestamp < $1.timestamp }

        // The Main board's ten, newest last. Out of stock is the one scenario that isn't its
        // endpoint's first.
        let recent: [(Int, Double, HTTPMethod, String, Int, UUID?, Int, Int, RequestOutcome)] = [
            (410, 5.438, .delete, "/session", 204, uuid(7), 3, 0, .endpoint),
            (409, 4.887, .get, "/cdn/fonts/inter.woff2", 302, nil, 41, 0, .passthrough),
            (408, 4.206, .get, "/products/search?q=tote", 200, uuid(3), 11, 1_434, .endpoint),
            (407, 3.768, .patch, "/account/profile", 401, uuid(6), 6, 96, .endpoint),
            (406, 3.414, .get, "/account-summary", 200, uuid(5), 15, 2_150, .endpoint),
            (405, 2.647, .post, "/payments", 503, uuid(8), 1_200, 180, .endpoint),
            (400, 2.263, .get, "/recommendations?limit=4", 404, nil, 2, 0, .unmatched),
            (404, 0.516, .post, "/cart", 201, uuid(4), 24, 312, .endpoint),
            (403, 0.038, .get, "/products/42", 200, uuid(2), 8, 640, .endpoint),
            (411, 0.000, .get, "/products", 503, uuid(1), 803, 214, .endpoint),
        ]
        for row in recent {
            let scenario = row.0 == 411 ? uuid(102) : row.5.flatMap(scenarioID(for:))
            logs.append(entry(
                id: row.0, secondsAgo: row.1, row.2, row.3, status: row.4, endpoint: row.5, scenario: scenario,
                durationMs: row.6, bytes: row.7, outcome: row.8
            ))
        }
        return logs
    }

    /// The endpoints with the scenario names the request log's Scenario column prints.
    public static var requestLogEndpoints: [Endpoint] {
        let names: [UUID: String] = [
            uuid(4): "Item added", uuid(5): "Premium member", uuid(6): "Session expired", uuid(8): "Declined",
        ]
        return endpoints.map { endpoint in
            guard let name = names[endpoint.id], !endpoint.scenarios.isEmpty else { return endpoint }
            var renamed = endpoint
            renamed.scenarios[0].name = name
            return renamed
        }
    }

    /// The single scenario a navigator endpoint other than Products answers with.
    private static func scenarioID(for endpointID: UUID) -> UUID? {
        endpoints.first { $0.id == endpointID }?.scenarios.first?.id
    }

    private static func entry(
        id: Int,
        secondsAgo: Double,
        _ method: HTTPMethod,
        _ path: String,
        status: Int,
        endpoint: UUID? = nil,
        scenario: UUID? = nil,
        durationMs: Int,
        bytes: Int,
        outcome: RequestOutcome = .endpoint
    ) -> RequestLog {
        RequestLog(
            id: uuid(id),
            timestamp: now.addingTimeInterval(-secondsAgo),
            method: method,
            path: path,
            // A passed-through request names the server that answered it, as its Scenario cell shows.
            backendName: outcome == .passthrough ? "Upstream" : requestLogPortName,
            listenerPort: port,
            durationMs: durationMs,
            requestHeaders: [
                "Host": "localhost:\(port)",
                "Accept": "application/json",
                "Accept-Language": "en-GB",
                "User-Agent": "AcmeShop/4.2 (iPhone; iOS 26.0)",
                "Authorization": "Bearer eyJhbGciOi\u{2026}",
                "X-Request-ID": "7f3a9c2e-51b0-4d6a",
            ],
            matchedEndpointID: endpoint,
            matchedScenarioID: scenario,
            responseStatusCode: status,
            // The size column reads Content-Length when no body was kept, as for a streamed answer.
            responseHeaders: ["Content-Type": "application/json", "Content-Length": "\(bytes)"],
            outcome: outcome
        )
    }
}
#endif
