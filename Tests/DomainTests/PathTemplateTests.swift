import Testing
import Foundation
@testable import Domain

/// `{name}` templates inside a segment, the shape OpenAPI writes as `/airport/{iata}.json` and
/// Twilio's published spec uses on 45 of its 121 paths (`/Accounts/{Sid}.json`).
@Suite("Path templates inside a segment")
struct PathTemplateTests {
    @Test("A template matches the requests its literal text describes", arguments: [
        ("/api/airport/{iata}.json", "/api/airport/LHR.json"),
        ("/api/airport/{iata}.json", "/api/airport/AUX_.json?fields=name"),
        ("/v{major}/users", "/v2/users"),
        ("/range/{from}-{to}", "/range/1-9"),
        ("/range/{from}-{to}", "/range/1-2-3"),
        ("/things/{id}:batchGet", "/things/42:batchGet"),
        ("/x/:prefix{id}", "/x/:prefix42"),
        ("/caf\u{e9}/{name}.json", "/caf%C3%A9/menu.json"),
        ("/files/{name}.json", "/files/r%C3%A9sum%C3%A9.json"),
    ])
    func templateMatches(pattern: String, request: String) {
        #expect(PathPattern.matches(requestPath: request, pattern: pattern))
    }

    @Test("A template refuses requests outside its literal text", arguments: [
        ("/api/airport/{iata}.json", "/api/airport/LHR"),
        ("/api/airport/{iata}.json", "/api/airport/LHR.xml"),
        ("/api/airport/{iata}.json", "/api/airport/.json"),
        ("/api/airport/{iata}.json", "/api/airport/LHR.json/extra"),
        ("/v{major}/users", "/v/users"),
        ("/range/{from}-{to}", "/range/19"),
        ("/range/{from}-{to}", "/range/-9"),
        ("/files/{name}.json", "/files/a%2Fb"),
        // A colon before a template is literal text, not the `:name` wildcard.
        ("/x/:prefix{id}", "/x/anything"),
    ])
    func templateRefuses(pattern: String, request: String) {
        #expect(!PathPattern.matches(requestPath: request, pattern: pattern))
    }

    @Test("Unpaired braces are not templates, and stay literal text")
    func unpairedBracesStayLiteral() {
        for segment in ["{unclosed", "closed}", "{a{b}}", "a}{b"] {
            #expect(!PathPattern.isTemplate(segment: segment), "\(segment)")
        }
        #expect(PathPattern.isTemplate(segment: "{iata}.json"))
        #expect(!PathPattern.isTemplate(segment: ":id"))
        #expect(PathPattern.isTemplate(segment: ":prefix{id}"))
        #expect(PathPattern.matchingKey(for: "/x/:prefix{id}") == ["x", ":prefix{}"])
        #expect(PathPattern.matches(requestPath: "/x/%7Bunclosed", pattern: "/x/{unclosed"))
    }

    @Test("Templates with the same literal text share an identity, whatever their names")
    func templateMatchingKey() {
        #expect(PathPattern.matchingKey(for: "/files/{name}.json") == ["files", "{}.json"])
        #expect(PathPattern.matchingKey(for: "/files/{name}.json") == PathPattern.matchingKey(for: "/files/{id}.json"))
        #expect(PathPattern.matchingKey(for: "/files/{name}.json") != PathPattern.matchingKey(for: "/files/:name"))
        #expect(PathPattern.matchingKey(for: "/files/{name}.json") != PathPattern.matchingKey(for: "/files/%7Bname%7D.json"))
    }

    @Test("A template ranks between a literal segment and a whole-segment wildcard")
    func templateRank() {
        let template = PathPattern.rank(requestPath: "/files/a.json", pattern: "/files/{name}.json")
        #expect(template == PathPattern.Rank(literalSegments: 1, templateSegments: 1))
        #expect(PathPattern.specificity(requestPath: "/files/a.json", pattern: "/files/{name}.json") == 1)

        func endpoint(_ name: String, _ path: String) -> Endpoint {
            let scenario = Scenario(id: UUID(), name: "Success", statusCode: 200)
            return Endpoint(name: name, method: .get, path: path, scenarios: [scenario], activeScenarioID: scenario.id)
        }
        func winner(_ path: String, among endpoints: [Endpoint]) -> String? {
            guard case .matched(let endpoint, _) = RequestMatcher.match(
                request: IncomingRequest(method: .get, path: path), against: endpoints
            ) else { return nil }
            return endpoint.name
        }
        // Declared least specific first, so declaration order cannot be what picks the winner.
        let endpoints = [
            endpoint("wildcard", "/files/:name"),
            endpoint("template", "/files/{name}.json"),
            endpoint("literal", "/files/index.json"),
        ]
        #expect(winner("/files/index.json", among: endpoints) == "literal")
        #expect(winner("/files/a.json", among: endpoints) == "template")
        #expect(winner("/files/a.xml", among: endpoints) == "wildcard")
    }
}
