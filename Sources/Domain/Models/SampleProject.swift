import Foundation

/// The project the welcome window's "Try the sample project" opens: a few endpoints with more than
/// one response each, and a journey that plays them in order.
///
/// Built through `ProjectCommandExecutor`, the way a person building it in the window would, so the
/// sample is held to every rule a real project is and cannot drift from them.
public enum SampleProject {
    public static let name = "Sample project"

    /// Each endpoint's first response is the one served; the rest are there to switch to.
    private struct Route {
        let method: HTTPMethod
        let path: String
        let name: String
        let responses: [ScenarioSpec]
    }

    private static let routes: [Route] = [
        Route(method: .post, path: "/login", name: "Log in", responses: [
            ScenarioSpec(name: "Signed in", statusCode: 200,
                         body: #"{"token":"mimic-session-token","userId":"u_1001"}"#),
            ScenarioSpec(name: "Wrong password", statusCode: 401,
                         body: #"{"error":"invalid_credentials"}"#),
        ]),
        Route(method: .get, path: "/account-summary", name: "Account summary", responses: [
            ScenarioSpec(name: "Balance", statusCode: 200,
                         body: #"{"balance":1520.44,"currency":"USD","accounts":2,"frozen":false}"#),
            ScenarioSpec(name: "Server error", statusCode: 500,
                         body: #"{"error":"internal_error","message":"Summary service unavailable"}"#),
        ]),
        Route(method: .get, path: "/inbox", name: "Inbox", responses: [
            ScenarioSpec(name: "Messages", statusCode: 200,
                         body: #"{"messages":[{"id":"m_1","subject":"Welcome","read":false}]}"#),
            ScenarioSpec(name: "Empty", statusCode: 200, body: #"{"messages":[]}"#),
        ]),
        Route(method: .get, path: "/products/:id", name: "Product", responses: [
            ScenarioSpec(name: "Found", statusCode: 200,
                         body: #"{"id":"p_42","name":"Desk lamp","price":39.5,"discount":null}"#),
            ScenarioSpec(name: "Not found", statusCode: 404, body: #"{"error":"not_found"}"#),
        ]),
    ]

    /// The template whose steps call the endpoints above.
    static let journeyTemplateID = JourneyTemplates.retryAfterFailure.id

    /// A new sample project with its own id, on `port`.
    public static func make(port: Int = ServerConfiguration.default.port) throws -> MockProject {
        var project = MockProject(
            name: name,
            serverConfiguration: ServerConfiguration(port: port, globalDelayMs: 0)
        )
        for route in routes {
            _ = try ProjectCommandExecutor.apply(
                .endpointCreate(name: route.name, method: route.method, path: route.path, spec: nil),
                to: &project
            )
            let endpoint = EndpointRef.route(route.method, route.path)
            guard let first = route.responses.first else { continue }
            // `endpointCreate` gives every endpoint an empty 200; the first response replaces it.
            _ = try ProjectCommandExecutor.apply(
                .endpointUpdateWithActiveScenario(endpoint: endpoint, spec: EndpointSpec(), scenarioSpec: first),
                to: &project
            )
            for response in route.responses.dropFirst() {
                _ = try ProjectCommandExecutor.apply(
                    .scenarioCreate(endpoint: endpoint, name: response.name ?? "Response", spec: response),
                    to: &project
                )
            }
        }
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: journeyTemplateID, name: nil),
            to: &project
        )
        return project
    }
}
