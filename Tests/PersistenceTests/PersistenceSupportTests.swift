import Foundation
import GRDB
import Testing
import Domain
@testable import Persistence

@Suite("Persistence Support")
struct PersistenceSupportTests {
    @Test("Corrupt backend JSON is refused rather than loaded as an empty list")
    func corruptBackendsAreNotDiscarded() {
        var record = ProjectRecord(from: MockProject(name: "Preserve my data"))
        record.backendsJSON = "{broken"
        #expect(throws: (any Error).self) { try record.toDomain() }
    }

    @Test("DatabaseFactory creates and migrates only the requested temporary store")
    func makeAppDatabaseQueueHonoursExplicitPath() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-persistence-support-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // The nested parent does not exist yet; the factory must create it at the explicit path.
        let dbURL = directory.appendingPathComponent("nested", isDirectory: true)
            .appendingPathComponent("store.sqlite")
        let environment = [DatabaseFactory.databasePathEnvironmentKey: dbURL.path]
        let resolved = try DatabaseFactory.resolveDatabaseURL(environment: environment)
        try #require(resolved == dbURL, "Refuse to open a database outside this test's temporary directory")
        #expect(!FileManager.default.fileExists(atPath: dbURL.path))

        let dbQueue = try DatabaseFactory.makeAppDatabaseQueue(environment: environment)

        // If the factory ignores the override, this unique file is absent. These table checks also
        // prove it ran migrations, rather than merely creating an empty SQLite file.
        #expect(FileManager.default.fileExists(atPath: dbURL.path))
        let migrated = try dbQueue.read { db in
            let hasProject = try db.tableExists("project")
            let hasJourneyStep = try db.tableExists("journeyStep")
            return hasProject && hasJourneyStep
        }
        #expect(migrated)
    }

    @Test("PersistenceError describes missing projects")
    func persistenceErrorDescription() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let error = PersistenceError.projectNotFound(id)

        #expect(error.errorDescription == "Project not found: \(id)")
    }

    @Test("ScenarioRecord round-trips scenario fields")
    func scenarioRecordRoundTrip() throws {
        let scenario = Scenario(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            name: "Success",
            statusCode: 201,
            headers: [
                "Content-Type": "application/json",
                "ETag": "abc",
            ],
            body: #"{"id":1}"#,
            bodyContentType: .plainText
        )

        let record = ScenarioRecord(
            from: scenario,
            endpointID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
            sortOrder: 2
        )
        let restored = try record.toDomain()

        #expect(record.endpointID == "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        #expect(record.sortOrder == 2)
        #expect(restored == scenario)
    }

    @Test("ScenarioRecord identifies each malformed field independently", arguments: [
        "id", "headersJSON", "bodyContentType",
    ])
    func scenarioRecordRejectsMalformedData(field: String) throws {
        var record = ScenarioRecord(
            from: Scenario(name: "Broken", statusCode: 500),
            endpointID: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )
        switch field {
        case "id": record.id = "not-a-uuid"
        case "headersJSON": record.headersJSON = "{bad json"
        case "bodyContentType": record.bodyContentType = "not/a-real-type"
        default:
            Issue.record("No corruption fixture for \(field)")
            return
        }

        do {
            _ = try record.toDomain()
            Issue.record("Accepted an invalid \(field)")
        } catch let Persistence.PersistenceError.corruptedRecord(table, id, invalidField) {
            #expect(table == "scenario")
            #expect(id == record.id)
            #expect(invalidField == field)
        }
    }
}
