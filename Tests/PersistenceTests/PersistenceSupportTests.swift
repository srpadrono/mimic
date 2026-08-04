import Foundation
import Testing
import Domain
@testable import Persistence

@Suite("Persistence Support")
struct PersistenceSupportTests {
    @Test("DatabaseFactory creates an app database in Application Support")
    func makeAppDatabaseQueueCreatesExpectedFile() throws {
        let originalHome = NSHomeDirectory()
        let temporaryHome = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temporaryHome, withIntermediateDirectories: true)
        setenv("HOME", temporaryHome.path, 1)
        defer {
            setenv("HOME", originalHome, 1)
            try? FileManager.default.removeItem(at: temporaryHome)
        }

        _ = try DatabaseFactory.makeAppDatabaseQueue()

        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        )
        let dbURL = appSupport
            .appendingPathComponent("devxa.Mimic", isDirectory: true)
            .appendingPathComponent("mimic.sqlite")

        #expect(FileManager.default.fileExists(atPath: dbURL.path))
    }

    @Test("PersistenceError describes missing projects")
    func persistenceErrorDescription() {
        let id = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        let error = PersistenceError.projectNotFound(id)

        #expect(error.errorDescription == "Project not found: \(id)")
    }

    @Test("ScenarioRecord round-trips scenario fields")
    func scenarioRecordRoundTrip() {
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
            endpointID: "endpoint-1",
            sortOrder: 2
        )
        let restored = record.toDomain()

        #expect(record.endpointID == "endpoint-1")
        #expect(record.sortOrder == 2)
        #expect(restored == scenario)
    }

    @Test("ScenarioRecord falls back for malformed persisted data")
    func scenarioRecordFallbacks() {
        var record = ScenarioRecord(
            from: Scenario(name: "Broken", statusCode: 500),
            endpointID: "endpoint-2"
        )
        record.id = "not-a-uuid"
        record.headersJSON = "{bad json"
        record.bodyContentType = "not/a-real-type"

        let restored = record.toDomain()

        #expect(restored.name == "Broken")
        #expect(restored.statusCode == 500)
        #expect(restored.headers.isEmpty)
        #expect(restored.bodyContentType == Scenario.ContentType.json)
    }
}
