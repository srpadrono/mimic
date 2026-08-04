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
}
