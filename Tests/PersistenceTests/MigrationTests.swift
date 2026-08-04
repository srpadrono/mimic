import Testing
import Foundation
@testable import Persistence
import GRDB
import Domain

@Suite("Migrations")
struct MigrationTests {

    // MARK: - Schema Tests

    @Test func v1MigrationCreatesAllTables() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()

        let projectExists = try dbQueue.read { db in try db.tableExists("project") }
        let endpointExists = try dbQueue.read { db in try db.tableExists("endpoint") }
        let scenarioExists = try dbQueue.read { db in try db.tableExists("scenario") }

        #expect(projectExists)
        #expect(endpointExists)
        #expect(scenarioExists)
    }

    // MARK: - Round-trip Tests

    @Test func projectRecordRoundTrip() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let project = MockProject(name: "Test", serverConfiguration: ServerConfiguration(port: 9090, globalDelayMs: 100))
        let record = ProjectRecord(from: project)

        try dbQueue.write { db in try record.insert(db) }
        let fetched = try dbQueue.read { db in try ProjectRecord.fetchOne(db, key: project.id.uuidString) }

        let domain = try #require(fetched).toDomain()
        #expect(domain.name == "Test")
        #expect(domain.serverConfiguration.port == 9090)
        #expect(domain.serverConfiguration.globalDelayMs == 100)
        #expect(domain.schemaVersion == MockProject.currentSchemaVersion)
    }

    @Test func endpointRecordRoundTrip() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()

        let project = MockProject(name: "TestProject")
        let projectRecord = ProjectRecord(from: project)
        try dbQueue.write { db in try projectRecord.insert(db) }

        let endpoint = Endpoint(name: "Get Users", method: .get, path: "/api/users", delayMs: 200, groupTag: "users")
        let record = EndpointRecord(from: endpoint, projectID: project.id.uuidString)
        try dbQueue.write { db in try record.insert(db) }

        let fetched = try dbQueue.read { db in try EndpointRecord.fetchOne(db, key: endpoint.id.uuidString) }

        let domain = try #require(fetched).toDomain(scenarios: [])
        #expect(domain.name == "Get Users")
        #expect(domain.method == .get)
        #expect(domain.path == "/api/users")
        #expect(domain.delayMs == 200)
        #expect(domain.groupTag == "users")
    }

    @Test func scenarioRecordRoundTrip() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()

        let project = MockProject(name: "TestProject")
        let projectRecord = ProjectRecord(from: project)
        let endpoint = Endpoint(name: "Test Endpoint", method: .post, path: "/api/test")
        let endpointRecord = EndpointRecord(from: endpoint, projectID: project.id.uuidString)
        try dbQueue.write { db in
            try projectRecord.insert(db)
            try endpointRecord.insert(db)
        }

        let scenario = Scenario(name: "Success", statusCode: 200, headers: ["Content-Type": "application/json"], body: "{\"ok\":true}", bodyContentType: .json)
        let record = ScenarioRecord(from: scenario, endpointID: endpoint.id.uuidString)
        try dbQueue.write { db in try record.insert(db) }

        let fetched = try dbQueue.read { db in try ScenarioRecord.fetchOne(db, key: scenario.id.uuidString) }

        let domain = try #require(fetched).toDomain()
        #expect(domain.name == "Success")
        #expect(domain.statusCode == 200)
        #expect(domain.headers["Content-Type"] == "application/json")
        #expect(domain.body == "{\"ok\":true}")
        #expect(domain.bodyContentType == .json)
    }

    // MARK: - Cascade Delete Tests

    @Test func cascadeDeleteRemovesEndpointsAndScenarios() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()

        let project = MockProject(name: "CascadeTest")
        let projectRecord = ProjectRecord(from: project)
        let endpoint = Endpoint(name: "Endpoint", method: .get, path: "/test")
        let endpointRecord = EndpointRecord(from: endpoint, projectID: project.id.uuidString)
        let scenario = Scenario(name: "Success", statusCode: 200)
        let scenarioRecord = ScenarioRecord(from: scenario, endpointID: endpoint.id.uuidString)

        try dbQueue.write { db in
            try projectRecord.insert(db)
            try endpointRecord.insert(db)
            try scenarioRecord.insert(db)
        }

        _ = try dbQueue.write { db in try projectRecord.delete(db) }

        let endpointCount = try dbQueue.read { db in try EndpointRecord.fetchCount(db) }
        let scenarioCount = try dbQueue.read { db in try ScenarioRecord.fetchCount(db) }

        #expect(endpointCount == 0)
        #expect(scenarioCount == 0)
    }

    // MARK: - Schema Version Tests

    @Test func schemaVersionRoundTrips() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let project = MockProject(name: "SchemaVersionTest")
        #expect(project.schemaVersion == MockProject.currentSchemaVersion)

        let record = ProjectRecord(from: project)
        try dbQueue.write { db in try record.insert(db) }

        let fetched = try dbQueue.read { db in try ProjectRecord.fetchOne(db, key: project.id.uuidString) }
        let domain = try #require(fetched).toDomain()
        #expect(domain.schemaVersion == MockProject.currentSchemaVersion)
    }
}
