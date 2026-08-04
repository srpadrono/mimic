import Testing
import Foundation
@testable import Domain

@Suite("RequestMatcher")
struct RequestMatcherTests {

    // MARK: - Helpers

    private func makeScenario(id: UUID = UUID()) -> Scenario {
        Scenario(id: id, name: "Success", statusCode: 200)
    }

    private func makeEndpoint(method: HTTPMethod = .get, path: String, activeScenarioID: UUID? = nil, scenarios: [Scenario] = []) -> Endpoint {
        Endpoint(name: "Test", method: method, path: path, scenarios: scenarios, activeScenarioID: activeScenarioID)
    }

    // MARK: - Basic matching

    @Test func exactPathMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .matched(let e, let s) = result else {
            Issue.record("Expected .matched but got .noMatch")
            return
        }
        #expect(e.id == endpoint.id)
        #expect(s.id == scenario.id)
    }

    @Test func methodMismatchReturnsNoMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(method: .get, path: "/users", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .post, path: "/users")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .noMatch = result else {
            Issue.record("Expected .noMatch for method mismatch")
            return
        }
    }

    @Test func wildcardSegmentMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users/:id", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users/123")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .matched = result else {
            Issue.record("Expected .matched for wildcard segment")
            return
        }
    }

    @Test func segmentCountMismatchReturnsNoMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users/:id", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users/123/posts")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .noMatch = result else {
            Issue.record("Expected .noMatch for segment count mismatch")
            return
        }
    }

    @Test func nilActiveScenarioIDReturnsNoMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: nil, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .noMatch = result else {
            Issue.record("Expected .noMatch for nil activeScenarioID")
            return
        }
    }

    @Test func activeScenarioIDPointingToNonExistentScenarioReturnsNoMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: UUID(), scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .noMatch = result else {
            Issue.record("Expected .noMatch for non-existent activeScenarioID")
            return
        }
    }

    // MARK: - Query string handling

    @Test func queryStringIsStrippedBeforeMatching() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users?page=1&limit=10")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .matched = result else {
            Issue.record("Expected .matched when request has query string")
            return
        }
    }

    @Test func queryStringWithWildcardSegment() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users/:id/posts", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users/42/posts?sort=desc")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .matched = result else {
            Issue.record("Expected .matched for wildcard + query string")
            return
        }
    }

    // MARK: - Edge cases

    @Test func emptyEndpointsArrayReturnsNoMatch() {
        let request = IncomingRequest(method: .get, path: "/users")
        let result = RequestMatcher.match(request: request, against: [])
        guard case .noMatch = result else {
            Issue.record("Expected .noMatch for empty endpoints")
            return
        }
    }

    @Test func trailingSlashDoesNotAffectMatch() {
        let scenario = makeScenario()
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: scenario.id, scenarios: [scenario])
        let request = IncomingRequest(method: .get, path: "/users/")
        let result = RequestMatcher.match(request: request, against: [endpoint])
        guard case .matched = result else {
            Issue.record("Expected .matched — trailing slash should be ignored")
            return
        }
    }

    @Test func firstMatchWinsWithMultipleMatchingEndpoints() {
        let scenario1 = makeScenario()
        let scenario2 = makeScenario()
        let endpoint1 = makeEndpoint(path: "/users/:id", activeScenarioID: scenario1.id, scenarios: [scenario1])
        let endpoint2 = makeEndpoint(path: "/users/:id", activeScenarioID: scenario2.id, scenarios: [scenario2])
        let request = IncomingRequest(method: .get, path: "/users/42")
        let result = RequestMatcher.match(request: request, against: [endpoint1, endpoint2])
        guard case .matched(let e, _) = result else {
            Issue.record("Expected .matched")
            return
        }
        #expect(e.id == endpoint1.id)
    }

    // MARK: - Specificity

    @Test func literalSegmentBeatsWildcardRegardlessOfOrder() {
        let literalScenario = makeScenario()
        let wildcardScenario = makeScenario()
        let literal = makeEndpoint(path: "/users/me", activeScenarioID: literalScenario.id, scenarios: [literalScenario])
        let wildcard = makeEndpoint(path: "/users/:id", activeScenarioID: wildcardScenario.id, scenarios: [wildcardScenario])
        let request = IncomingRequest(method: .get, path: "/users/me")

        // Wildcard declared first must NOT shadow the more specific literal route.
        for endpoints in [[wildcard, literal], [literal, wildcard]] {
            guard case .matched(let e, _) = RequestMatcher.match(request: request, against: endpoints) else {
                Issue.record("Expected .matched")
                return
            }
            #expect(e.id == literal.id)
        }
    }

    @Test func wildcardStillMatchesNonLiteralRequests() {
        let literalScenario = makeScenario()
        let wildcardScenario = makeScenario()
        let literal = makeEndpoint(path: "/users/me", activeScenarioID: literalScenario.id, scenarios: [literalScenario])
        let wildcard = makeEndpoint(path: "/users/:id", activeScenarioID: wildcardScenario.id, scenarios: [wildcardScenario])
        let request = IncomingRequest(method: .get, path: "/users/42")

        guard case .matched(let e, _) = RequestMatcher.match(request: request, against: [literal, wildcard]) else {
            Issue.record("Expected .matched")
            return
        }
        #expect(e.id == wildcard.id)
    }

    // MARK: - Response resolution

    @Test func resolveAppliesAdditiveDelay() {
        let scenario = Scenario(name: "OK", statusCode: 200, body: #"{"ok":true}"#)
        let endpoint = makeEndpoint(path: "/users", activeScenarioID: scenario.id, scenarios: [scenario])
        let mutableEndpoint = Endpoint(
            id: endpoint.id, name: endpoint.name, method: .get, path: "/users",
            scenarios: [scenario], activeScenarioID: scenario.id, delayMs: 150
        )
        let request = IncomingRequest(method: .get, path: "/users")

        let resolved = RequestMatcher.resolve(request: request, against: [mutableEndpoint], globalDelayMs: 100)

        #expect(resolved.delayMs == 250)
        #expect(resolved.statusCode == 200)
        #expect(resolved.body == #"{"ok":true}"#)
        #expect(resolved.contentType == .json)
        #expect(resolved.matchedEndpointID == mutableEndpoint.id)
        #expect(resolved.matchedScenarioID == scenario.id)
    }

    @Test func resolveCarriesScenarioHeaders() {
        let scenario = Scenario(name: "OK", statusCode: 201, headers: ["X-Trace": "abc"], body: nil)
        let endpoint = makeEndpoint(path: "/items", activeScenarioID: scenario.id, scenarios: [scenario])
        let resolved = RequestMatcher.resolve(
            request: IncomingRequest(method: .get, path: "/items"),
            against: [endpoint],
            globalDelayMs: 0
        )
        #expect(resolved.statusCode == 201)
        #expect(resolved.headers["X-Trace"] == "abc")
        #expect(resolved.delayMs == 0)
    }

    @Test func resolveReturnsFastNotFoundWhenNothingMatches() {
        let resolved = RequestMatcher.resolve(
            request: IncomingRequest(method: .get, path: "/missing"),
            against: [],
            globalDelayMs: 500
        )
        #expect(resolved.statusCode == 404)
        #expect(resolved.delayMs == 0)
        #expect(resolved.matchedEndpointID == nil)
        #expect(resolved == .notFound)
    }
}
