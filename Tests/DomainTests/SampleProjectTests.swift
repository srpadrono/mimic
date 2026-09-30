import Foundation
import Testing
@testable import Domain

@Suite("Sample project")
struct SampleProjectTests {

    @Test("The sample is a valid project with switchable responses and a journey")
    func sampleIsValidAndComplete() throws {
        let project = try SampleProject.make(port: 18086)

        try ProjectValidator.validate(project)
        #expect(project.name == "Sample project")
        #expect(project.serverConfiguration.port == 18086)
        #expect(project.endpoints.map(\.path) == ["/login", "/account-summary", "/inbox", "/products/:id"])
        #expect(project.endpoints.allSatisfy { $0.scenarios.count == 2 })
        #expect(project.journeys.count == 1)
        #expect(project.activeJourneyID == nil)
    }

    @Test("Each endpoint serves its first response, not the empty placeholder")
    func firstResponseIsActive() throws {
        let project = try SampleProject.make()
        let login = try #require(project.endpoints.first { $0.path == "/login" })
        let active = try #require(login.scenarios.first { $0.id == login.activeScenarioID })

        #expect(active.name == "Signed in")
        #expect(active.statusCode == 200)
        #expect(active.body == #"{"token":"mimic-session-token","userId":"u_1001"}"#)
    }

    @Test("Every sample has its own identity")
    func samplesAreDistinct() throws {
        #expect(try SampleProject.make().id != SampleProject.make().id)
    }
}
