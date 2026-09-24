import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Domain
@testable import MockServerEngine

@Suite("Response attribution", .serialized, .timeLimit(.minutes(1)))
struct ResponseAttributionTests {
    @Test("A served mock records the project attached to its response")
    func servedMockLogIncludesProjectID() async throws {
        let projectID = UUID(uuidString: "aebd8df3-dc32-4fd0-8d58-ed882a7f2c05")!
        let scenario = Scenario(name: "OK", statusCode: 200, body: "from mock")
        let endpoint = Endpoint(
            name: "Mock", path: "/mock", scenarios: [scenario], activeScenarioID: scenario.id
        )

        try await JourneyServingTests.withEngine(endpoints: [endpoint]) { engine, baseURL in
            let port = try #require(baseURL.port)
            await engine.updateServerConfiguration(
                ServerConfiguration(port: port, globalDelayMs: 0), projectID: projectID
            )

            let reply = try await JourneyServingTests.call(
                "GET", "mock", baseURL: baseURL, session: JourneyServingTests.session()
            )
            #expect(reply.status == 200)
            #expect(reply.body == "from mock")

            let log = await MockServerEngineTests.firstLogEntry(from: engine.logStream, within: .seconds(5))
            #expect(log?.outcome == .endpoint)
            #expect(log?.projectID == projectID)
        }
    }
}
