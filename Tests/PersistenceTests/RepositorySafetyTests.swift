import Domain
import Foundation
import GRDB
import Persistence
import Testing

@Suite("Repository safety")
struct RepositorySafetyTests {
    @Test("One unreadable backend payload does not hide the other stored projects")
    func mixedProjectListingSurvivesDamagedBackendJSON() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let activeJourney = Journey(name: "Current flow")
        let healthy = MockProject(
            name: "Healthy project",
            serverConfiguration: ServerConfiguration(port: 9271, globalDelayMs: 35),
            journeys: [activeJourney], activeJourneyID: activeJourney.id
        )
        let damaged = MockProject(
            name: "Damaged backend payload",
            serverConfiguration: ServerConfiguration(port: 9272, globalDelayMs: 50)
        )
        try await repository.save(healthy)
        try await repository.save(damaged)

        // Literal invalid JSON stands in for a damaged or future-format payload. The list only
        // needs stable summary columns; a full load must still refuse to reinterpret the payload.
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET backendsJSON = ? WHERE id = ?",
                arguments: ["{broken", damaged.id.uuidString]
            )
        }

        let listed = try await repository.allProjects()
        #expect(Set(listed.map(\.id)) == Set([healthy.id, damaged.id]))
        #expect(Set(listed.map(\.name)) == ["Healthy project", "Damaged backend payload"])
        #expect(listed.allSatisfy { $0.endpoints.isEmpty && $0.journeys.isEmpty })
        #expect(listed.first(where: { $0.id == healthy.id })?.serverConfiguration.port == 9271)
        #expect(listed.first(where: { $0.id == healthy.id })?.serverConfiguration.globalDelayMs == 35)
        #expect(listed.first(where: { $0.id == damaged.id })?.serverConfiguration.port == 9272)
        #expect(listed.first(where: { $0.id == damaged.id })?.serverConfiguration.globalDelayMs == 50)
        #expect(listed.first(where: { $0.id == healthy.id })?.activeJourneyID == activeJourney.id)
        #expect(try await repository.load(id: healthy.id).name == "Healthy project")

        do {
            _ = try await repository.load(id: damaged.id)
            Issue.record("A full load accepted the damaged backend payload")
        } catch {
            if case let Persistence.PersistenceError.corruptedRecord(table, id, field) = error {
                #expect(table == "project")
                #expect(id == damaged.id.uuidString)
                #expect(field == "backendsJSON")
            } else {
                Issue.record("Expected a corrupt backendsJSON error, got \(error)")
            }
        }
    }

    @Test("One malformed active journey ID does not hide the other stored projects")
    func mixedProjectListingSurvivesDamagedActiveJourneyID() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let activeJourney = Journey(name: "Healthy journey")
        let healthy = MockProject(
            name: "Healthy project", journeys: [activeJourney], activeJourneyID: activeJourney.id
        )
        let damaged = MockProject(name: "Damaged selection")
        try await repository.save(healthy)
        try await repository.save(damaged)

        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET activeJourneyID = ? WHERE id = ?",
                arguments: ["not-a-uuid", damaged.id.uuidString]
            )
        }

        let listed = try await repository.allProjects()
        #expect(Set(listed.map(\.id)) == Set([healthy.id, damaged.id]))
        #expect(listed.first(where: { $0.id == healthy.id })?.activeJourneyID == activeJourney.id)
        #expect(listed.first(where: { $0.id == damaged.id })?.activeJourneyID == nil)
        #expect(try await repository.load(id: healthy.id).activeJourneyID == activeJourney.id)

        do {
            _ = try await repository.load(id: damaged.id)
            Issue.record("A full load accepted the malformed active journey ID")
        } catch {
            if case let Persistence.PersistenceError.corruptedRecord(table, id, field) = error {
                #expect(table == "project")
                #expect(id == damaged.id.uuidString)
                #expect(field == "activeJourneyID")
            } else {
                Issue.record("Expected a corrupt activeJourneyID error, got \(error)")
            }
        }
    }

    @Test("A failed child insert rolls back the project and every child replacement")
    func failedChildInsertLeavesPriorProjectUnchanged() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let scenario = Scenario(
            name: "Original response", statusCode: 201, body: "original body", bodyContentType: .plainText
        )
        let endpoint = Endpoint(name: "Original route", method: .get, path: "/original", scenarios: [scenario])
        let step = JourneyStep(
            name: "Original step", method: .get, path: "/original",
            outcome: .respond(JourneyResponse(statusCode: 202, body: "original step"))
        )
        let journey = Journey(name: "Original journey", steps: [step])
        let original = MockProject(
            name: "Original project", endpoints: [endpoint], journeys: [journey], activeJourneyID: journey.id
        )
        try await repository.save(original)

        var replacement = original
        replacement.name = "Partially written project"
        replacement.endpoints[0].name = "Partially written route"
        replacement.endpoints[0].scenarios[0].body = "partially written body"
        let duplicateStepID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let first = JourneyStep(
            id: duplicateStepID, name: "First replacement", method: .get, path: "/first",
            outcome: .respond(JourneyResponse(statusCode: 203))
        )
        let second = JourneyStep(
            id: duplicateStepID, name: "Second replacement", method: .get, path: "/second",
            outcome: .respond(JourneyResponse(statusCode: 204))
        )
        replacement.journeys[0].steps = [first, second]

        do {
            try await repository.save(replacement)
            Issue.record("Duplicate journey-step IDs should make the insert fail")
        } catch let error as DatabaseError {
            #expect(error.resultCode == .SQLITE_CONSTRAINT)
            // The second journey-step insert violates its primary key after the project, endpoint,
            // scenario, and journey rows have all been replaced inside the write transaction.
        } catch {
            Issue.record("Expected a SQLite constraint error from the duplicate child ID, got \(error)")
        }

        let restored = try await repository.load(id: original.id)
        #expect(restored.name == "Original project")
        #expect(restored.endpoints.map(\.id) == [endpoint.id])
        #expect(restored.endpoints.map(\.name) == ["Original route"])
        #expect(restored.endpoints[0].scenarios.map(\.id) == [scenario.id])
        #expect(restored.endpoints[0].scenarios[0].body == "original body")
        #expect(restored.journeys.map(\.id) == [journey.id])
        #expect(restored.journeys[0].steps.map(\.id) == [step.id])
        #expect(restored.journeys[0].steps[0].name == "Original step")
        #expect(restored.activeJourneyID == journey.id)
    }
}
