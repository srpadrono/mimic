import Domain
import Foundation
import GRDB
import Persistence
import Testing

@Suite("Repository safety")
struct RepositorySafetyTests {
    @Test("A stale snapshot cannot overwrite a project upgraded by another build")
    func staleSnapshotCannotOverwriteNewerSchema() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let scenario = Scenario(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000301")!,
            name: "Response", body: "original body", bodyContentType: .plainText
        )
        let original = MockProject(name: "Originally opened", endpoints: [
            Endpoint(name: "Account", path: "/account", scenarios: [scenario], activeScenarioID: scenario.id),
        ])
        try await repository.save(original)
        var stale = try await repository.load(id: original.id)
        stale.name = "Stale edit"
        stale.endpoints[0].scenarios[0].body = "stale body"

        let futureVersion = MockProject.currentSchemaVersion + 1
        try await dbQueue.write { db in
            try db.execute(
                sql: "UPDATE project SET schemaVersion = ?, name = ? WHERE id = ?",
                arguments: [futureVersion, "Updated by newer build", original.id.uuidString]
            )
            try db.execute(
                sql: "UPDATE scenario SET body = ? WHERE id = ?",
                arguments: ["newer body", scenario.id.uuidString]
            )
        }

        do {
            try await repository.save(stale)
            Issue.record("A stale save must not replace a newer project schema")
        } catch let error as Persistence.PersistenceError {
            guard case let .unsupportedSchemaVersion(name, stored, supported) = error else {
                Issue.record("Expected a schema-version refusal, got \(error)")
                return
            }
            #expect(name == "Updated by newer build")
            #expect(stored == futureVersion)
            #expect(supported == MockProject.currentSchemaVersion)
        }

        let saved = try await dbQueue.read { db in
            (
                try Int.fetchOne(db, sql: "SELECT schemaVersion FROM project WHERE id = ?",
                                 arguments: [original.id.uuidString]),
                try String.fetchOne(db, sql: "SELECT name FROM project WHERE id = ?",
                                    arguments: [original.id.uuidString]),
                try String.fetchOne(db, sql: "SELECT body FROM scenario WHERE id = ?",
                                    arguments: [scenario.id.uuidString])
            )
        }
        #expect(saved.0 == futureVersion)
        #expect(saved.1 == "Updated by newer build")
        #expect(saved.2 == "newer body")

        // A refused transaction does not prevent saving another, compatible project.
        let compatible = MockProject(name: "Compatible project")
        try await repository.save(compatible)
        #expect(try await repository.load(id: compatible.id).name == "Compatible project")
        #expect(try await repository.allProjects().count == 2)
    }

    @Test("The repository refuses an incoming document from a newer schema")
    func incomingNewerSchemaIsRefusedBeforeWriting() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000302",
          "schemaVersion": \(MockProject.currentSchemaVersion + 1),
          "name": "Future import",
          "endpoints": [],
          "createdAt": 0,
          "modifiedAt": 0
        }
        """
        let future = try JSONDecoder().decode(MockProject.self, from: Data(json.utf8))

        do {
            try await repository.save(future)
            Issue.record("The repository must not write a document it cannot understand")
        } catch let error as Persistence.PersistenceError {
            guard case let .unsupportedSchemaVersion(name, stored, supported) = error else {
                Issue.record("Expected a schema-version refusal, got \(error)")
                return
            }
            #expect(name == "Future import")
            #expect(stored == MockProject.currentSchemaVersion + 1)
            #expect(supported == MockProject.currentSchemaVersion)
        }
        #expect(try await repository.allProjects().isEmpty)
    }

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
