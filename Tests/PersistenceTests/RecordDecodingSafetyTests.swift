import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Stored record decoding safety")
struct RecordDecodingSafetyTests {
    private func corruptedField(_ decode: () throws -> Void) -> String? {
        do {
            try decode()
        } catch let error as Persistence.PersistenceError {
            if case let .corruptedRecord(_, _, field) = error { return field }
        } catch {}
        return nil
    }

    @Test("Identifiers and behavior fields never acquire replacement values")
    func malformedRecordFieldsAreRefused() {
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let endpointID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var project = ProjectRecord(from: MockProject(id: projectID, name: "Saved project"))
        project.id = "invalid-project-id"
        #expect(corruptedField { _ = try project.toDomain() } == "id")

        var endpoint = EndpointRecord(
            from: Endpoint(id: endpointID, name: "Route", path: "/route"),
            projectID: projectID.uuidString
        )
        endpoint.projectID = "invalid-reference"
        #expect(corruptedField { _ = try endpoint.toDomain(scenarios: []) } == "projectID")
        endpoint.projectID = projectID.uuidString
        endpoint.activeScenarioID = "invalid-selection"
        #expect(corruptedField { _ = try endpoint.toDomain(scenarios: []) } == "activeScenarioID")
        endpoint.activeScenarioID = nil
        endpoint.method = "UNRECOGNIZED"
        #expect(corruptedField { _ = try endpoint.toDomain(scenarios: []) } == "method")

        var journey = JourneyRecord(from: Journey(name: "Flow"), projectID: projectID.uuidString)
        journey.matchMode = "unrecognized"
        #expect(corruptedField { _ = try journey.toDomain(steps: []) } == "matchMode")
    }

    @Test("Malformed response headers, content type, and outcome are refused")
    func malformedResponseFieldsAreRefused() {
        let parentID = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        var scenario = ScenarioRecord(from: Scenario(name: "Saved", statusCode: 503), endpointID: parentID)
        scenario.headersJSON = "{broken"
        #expect(corruptedField { _ = try scenario.toDomain() } == "headersJSON")
        scenario.headersJSON = "{}"
        scenario.bodyContentType = "future/type"
        #expect(corruptedField { _ = try scenario.toDomain() } == "bodyContentType")

        var step = JourneyStepRecord(
            from: JourneyStep(name: "Reply", path: "/reply", outcome: .respond(JourneyResponse(statusCode: 418))),
            journeyID: parentID
        )
        step.statusCode = nil
        #expect(corruptedField { _ = try step.toDomain() } == "statusCode")
        step.failureKind = "future-failure"
        #expect(corruptedField { _ = try step.toDomain() } == "failureKind")
    }

    @Test("A malformed stored method refuses project load and leaves its row untouched")
    func malformedMethodDoesNotLoadOrRewrite() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: queue)
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let endpointID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let project = MockProject(
            id: projectID,
            name: "Saved project",
            endpoints: [Endpoint(id: endpointID, name: "Route", method: .post, path: "/route")]
        )
        try await repository.save(project)
        try await queue.write { db in
            try db.execute(
                sql: "UPDATE endpoint SET method = 'FUTURE' WHERE id = ?",
                arguments: [endpointID.uuidString]
            )
        }

        do {
            _ = try await repository.load(id: projectID)
            Issue.record("The unknown method should prevent the project from opening")
        } catch let error as Persistence.PersistenceError {
            guard case let .corruptedRecord(table, id, field) = error else {
                Issue.record("Expected corruptedRecord, got \(error)")
                return
            }
            #expect(table == "endpoint")
            #expect(id == endpointID.uuidString)
            #expect(field == "method")
        }

        let stored = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT method FROM endpoint WHERE id = ?", arguments: [endpointID.uuidString])
        }
        #expect(stored == "FUTURE")
    }

    @Test("A missing stored step outcome refuses project load without becoming HTTP 200")
    func missingOutcomeDoesNotBecomeSuccess() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: queue)
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let stepID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let step = JourneyStep(id: stepID, name: "Reply", path: "/reply", outcome: .respond(JourneyResponse(statusCode: 503)))
        let project = MockProject(id: projectID, name: "Saved project", journeys: [Journey(name: "Flow", steps: [step])])
        try await repository.save(project)
        try await queue.write { db in
            try db.execute(sql: "UPDATE journeyStep SET statusCode = NULL WHERE id = ?", arguments: [stepID.uuidString])
        }

        do {
            _ = try await repository.load(id: projectID)
            Issue.record("A missing outcome should prevent the project from opening")
        } catch let error as Persistence.PersistenceError {
            guard case let .corruptedRecord(table, id, field) = error else {
                Issue.record("Expected corruptedRecord, got \(error)")
                return
            }
            #expect(table == "journeyStep")
            #expect(id == stepID.uuidString)
            #expect(field == "statusCode")
        }

        let stored = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT statusCode FROM journeyStep WHERE id = ?", arguments: [stepID.uuidString])
        }
        #expect(stored == nil)
    }

    @Test("A stored step cannot contain both a response and a network failure")
    func conflictingOutcomeDoesNotDiscardResponse() async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: queue)
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let stepID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let step = JourneyStep(
            id: stepID, name: "Disconnect", path: "/reply", outcome: .networkFailure(.connectionDrop)
        )
        let project = MockProject(id: projectID, name: "Saved project", journeys: [Journey(name: "Flow", steps: [step])])
        try await repository.save(project)

        // A future writer or damaged row has supplied two incompatible outcomes. The older decoder
        // selected the failure and silently discarded this literal response status.
        try await queue.write { db in
            try db.execute(sql: "UPDATE journeyStep SET statusCode = 207 WHERE id = ?", arguments: [stepID.uuidString])
        }

        do {
            _ = try await repository.load(id: projectID)
            Issue.record("Conflicting outcome columns should prevent the project from opening")
        } catch let error as Persistence.PersistenceError {
            guard case let .corruptedRecord(table, id, field) = error else {
                Issue.record("Expected corruptedRecord, got \(error)")
                return
            }
            #expect(table == "journeyStep")
            #expect(id == stepID.uuidString)
            #expect(field == "outcome")
        }

        let storedStatus = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT statusCode FROM journeyStep WHERE id = ?", arguments: [stepID.uuidString])
        }
        let storedFailure = try await queue.read { db in
            try String.fetchOne(db, sql: "SELECT failureKind FROM journeyStep WHERE id = ?", arguments: [stepID.uuidString])
        }
        #expect(storedStatus == 207)
        #expect(storedFailure == "connectionDrop")
    }

    @Test("Listing projection keeps scalar identity and selection without decoding backend JSON")
    func listingProjectionSurvivesUnreadableBackends() throws {
        let projectID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let activeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        var record = ProjectRecord(from: MockProject(id: projectID, name: "Visible", activeJourneyID: activeID))
        record.backendsJSON = "{broken"

        let listing = try record.toListingDomain()
        #expect(listing.id == projectID)
        #expect(listing.name == "Visible")
        #expect(listing.activeJourneyID == activeID)
        #expect(listing.serverConfiguration.backends.isEmpty)
        #expect(throws: Persistence.PersistenceError.self) { try record.toDomain() }
    }
}
