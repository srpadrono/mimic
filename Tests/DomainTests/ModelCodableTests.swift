import Testing
import Foundation
@testable import Domain

@Suite("Model Codable")
struct ModelCodableTests {

    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    // MARK: - MockProject round-trip

    @Test func mockProjectCodableRoundTrip() throws {
        let project = MockProject(name: "My Project")
        let data = try encoder.encode(project)
        let decoded = try decoder.decode(MockProject.self, from: data)
        #expect(project == decoded)
        #expect(decoded.schemaVersion == MockProject.currentSchemaVersion)
    }

    @Test func schemaVersionUsesCurrentVersion() {
        let project = MockProject(name: "Test")
        #expect(project.schemaVersion == MockProject.currentSchemaVersion)
    }

    // MARK: - Endpoint + Scenario round-trip

    @Test func endpointWithScenariosRoundTrip() throws {
        let scenarioID = UUID()
        let scenario = Scenario(id: scenarioID, name: "Success", statusCode: 200, headers: ["Content-Type": "application/json"], body: "{}")
        let endpoint = Endpoint(
            name: "Get Users",
            method: .get,
            path: "/users",
            scenarios: [scenario],
            activeScenarioID: scenarioID
        )
        let data = try encoder.encode(endpoint)
        let decoded = try decoder.decode(Endpoint.self, from: data)
        #expect(endpoint == decoded)
        #expect(decoded.activeScenarioID == scenarioID)
    }

    // MARK: - HTTPMethod encoding

    @Test func httpMethodEncodesAsRawValueString() throws {
        let method = HTTPMethod.get
        let data = try encoder.encode(method)
        let jsonString = String(data: data, encoding: .utf8)
        #expect(jsonString == "\"GET\"")
    }

    @Test func httpMethodDecodesFromRawValueString() throws {
        let data = "\"POST\"".data(using: .utf8)!
        let method = try decoder.decode(HTTPMethod.self, from: data)
        #expect(method == .post)
    }

    @Test func allHTTPMethodsRoundTrip() throws {
        for method in HTTPMethod.allCases {
            let data = try encoder.encode(method)
            let decoded = try decoder.decode(HTTPMethod.self, from: data)
            #expect(method == decoded)
        }
    }

    // MARK: - IncomingRequest Equatable

    @Test func incomingRequestEquatable() {
        let a = IncomingRequest(method: .get, path: "/users", headers: ["X": "1"], body: "test")
        let b = IncomingRequest(method: .get, path: "/users", headers: ["X": "1"], body: "test")
        let c = IncomingRequest(method: .post, path: "/users")
        #expect(a == b)
        #expect(a != c)
    }

    // MARK: - Project document check

    @Test("A project document is recognised by any one of its own keys")
    func projectDocumentIsRecognisedByItsKeys() {
        #expect(MockProject.namesProjectDocument(Data(#"{"id":"x","name":"A","endpoints":[]}"#.utf8)))
        #expect(MockProject.namesProjectDocument(Data(#"{"schemaVersion":6}"#.utf8)))
        // A serialized journey has an id and a name and none of the four.
        #expect(MockProject.namesProjectDocument(Data(#"{"id":"x","name":"Checkout","steps":[]}"#.utf8)) == false)
        #expect(MockProject.namesProjectDocument(Data(#"[{"endpoints":[]}]"#.utf8)) == false)
        #expect(MockProject.namesProjectDocument(Data("not json".utf8)) == false)
    }

    @Test("A recent project's summary reads like the welcome list's detail line")
    func recentProjectSummaryText() {
        #expect(RecentProjectEntry.Summary(ports: [18086], endpointCount: 12, journeyCount: 3).text
                == "Port 18086 \u{00B7} 12 endpoints \u{00B7} 3 journeys")
        #expect(RecentProjectEntry.Summary(ports: [8080], endpointCount: 1, journeyCount: 0).text
                == "Port 8080 \u{00B7} 1 endpoint")
        #expect(RecentProjectEntry.Summary(ports: [9000, 9001], endpointCount: 38, journeyCount: 1).text
                == "Ports 9000, 9001 \u{00B7} 38 endpoints \u{00B7} 1 journey")
    }

    @Test("A recents entry written before summaries existed still decodes")
    func recentProjectEntryDecodesWithoutSummary() throws {
        let json = #"{"id":"6F1B7C9E-3D0A-4F59-9B7B-2C1E8A2D4F10","name":"Old","lastOpenedAt":0}"#
        let entry = try JSONDecoder().decode(RecentProjectEntry.self, from: Data(json.utf8))
        #expect(entry.name == "Old")
        #expect(entry.summary == nil)
    }
}
