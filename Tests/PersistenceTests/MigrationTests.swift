import Testing
import Foundation
@testable import Persistence
import GRDB
import Domain

@Suite("Migrations")
struct MigrationTests {

    /// A record stamped with a document schema one ahead of what this build understands.
    ///
    /// It exists to hand the write closure an immutable value. `ProjectRecord.schemaVersion` is a
    /// `var`, GRDB's `write` closure is `@Sendable`, and capturing a `var` in one is an error rather
    /// than a warning under Swift 6 — so mutating a local and then closing over it does not compile.
    /// Stamping through a function makes what the closure captures a `let`.
    ///
    /// `PersistenceError` is spelled `Persistence.PersistenceError` everywhere below for a
    /// neighbouring reason: GRDB carries a deprecated `typealias PersistenceError = RecordError`,
    /// and this file imports both modules, so the bare name is ambiguous. The compiler reported it
    /// at the `catch` and not at the `#expect(throws:)`, which is a difference in how far
    /// type-checking got rather than a difference in the two spellings — both are qualified.
    private func stampedAhead(_ record: ProjectRecord) -> ProjectRecord {
        var stamped = record
        stamped.schemaVersion = MockProject.currentSchemaVersion + 1
        return stamped
    }

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

    /// Named for what it actually shows, which is less than it used to claim.
    ///
    /// `schemaVersion` was **write-only**: `ProjectRecord.init(from:)` stores `project.schemaVersion`,
    /// but `toDomain` rebuilds through `MockProject`'s memberwise initialiser, which hard-codes
    /// `MockProject.currentSchemaVersion`. So a test that writes a current project and reads back the
    /// current version is round-tripping a *constant* — it passes for a store whose column holds any
    /// value at all, including one from a build that understands more than this one.
    ///
    /// Carrying the stored integer through unchanged would need a `schemaVersion:` parameter on
    /// `MockProject.init`, which is a Domain change. What the column *is* read for is the refusal
    /// below, which is the only reading it has ever had.
    @Test func toDomainReportsTheCurrentVersionWhateverTheColumnHolds() throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let project = MockProject(name: "SchemaVersionTest")
        #expect(project.schemaVersion == MockProject.currentSchemaVersion)

        var record = ProjectRecord(from: project)
        // A v1 row — the real shape of a store written before journeys existed. Loading it as the
        // current version is a genuine forward migration: v2 added journeys, and a v1 project has
        // none, which is exactly what `toDomain` produces.
        record.schemaVersion = 1
        try dbQueue.write { db in try record.insert(db) }

        let fetched = try dbQueue.read { db in try ProjectRecord.fetchOne(db, key: project.id.uuidString) }
        let stored = try #require(fetched)
        #expect(stored.schemaVersion == 1, "the column itself round-trips")
        #expect(stored.toDomain().schemaVersion == MockProject.currentSchemaVersion)
        #expect(stored.toDomain().journeys.isEmpty)
    }

    /// The reading the column exists for, and the one it never had.
    ///
    /// A project written by a build that understands a later document schema loaded as a current one,
    /// having silently dropped whatever that version added — and the next autosave wrote the lower
    /// number back over it. That is the exact failure the field exists to prevent.
    ///
    /// Refusing rather than repairing, because a document from ahead of us cannot be read down safely:
    /// the fields we do not know about are precisely the ones that would be lost, and a load that
    /// half-succeeds is how data actually goes missing.
    @Test("A project written by a newer build is refused on load, naming both versions")
    func aNewerSchemaVersionIsRefusedOnLoad() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)

        let project = MockProject(name: "From the future")
        let record = stampedAhead(ProjectRecord(from: project))
        try await dbQueue.write { db in try record.insert(db) }

        do {
            _ = try await repository.load(id: project.id)
            Issue.record("expected the load to be refused")
        } catch let error as Persistence.PersistenceError {
            guard case let .unsupportedSchemaVersion(name, stored, supported) = error else {
                Issue.record("expected unsupportedSchemaVersion, got \(error)")
                return
            }
            #expect(name == "From the future")
            #expect(stored == MockProject.currentSchemaVersion + 1)
            #expect(supported == MockProject.currentSchemaVersion)

            // The message is what reaches the user — both hosts map `PersistenceError` onto
            // `persistence.failure` with `localizedDescription` — so "update Mimic" has to be
            // actionable, which means showing how far ahead the store is.
            let message = try #require(error.errorDescription)
            #expect(message.contains("From the future"))
            #expect(message.contains(String(stored)))
            #expect(message.contains(String(supported)))
        }
    }

    /// Deliberately *not* filtered out of the listing.
    ///
    /// A project this build cannot open is still a project the user has, and hiding it would look
    /// exactly like the symptom this repository has already lost a project to once — "the recents list
    /// is empty". So it lists, and `load` refuses it by name if they try to open it.
    @Test("A project this build cannot open still appears in the listing")
    func aNewerSchemaVersionStillLists() async throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let repository = GRDBProjectRepository(dbQueue: dbQueue)

        let record = stampedAhead(ProjectRecord(from: MockProject(name: "From the future")))
        try await dbQueue.write { db in try record.insert(db) }

        let listed = try await repository.allProjects()
        #expect(listed.map(\.name) == ["From the future"])
    }

    /// The guard on its own, at both boundaries: the current version and every older one are opened,
    /// and only a version this build does not know is refused.
    ///
    /// Note what it does *not* pin, because that gap is how `graphqlOperation` came to ship inside
    /// documents still stamped version 2: this is written entirely in terms of
    /// `MockProject.currentSchemaVersion`, so it passes whatever that constant happens to be —
    /// including a value the document has already outgrown. `DocumentShapeTests` is the half that
    /// notices the document changing shape underneath it.
    @Test("Only a version ahead of this build is refused")
    func schemaVersionGuardBoundaries() throws {
        var record = ProjectRecord(from: MockProject(name: "Boundaries"))

        for version in 1...MockProject.currentSchemaVersion {
            record.schemaVersion = version
            try record.requireSupportedSchemaVersion()
        }

        record.schemaVersion = MockProject.currentSchemaVersion + 1
        #expect(throws: Persistence.PersistenceError.self) { try record.requireSupportedSchemaVersion() }
    }

    // MARK: - Erase-on-schema-change gating

    /// GRDB's `eraseDatabaseOnSchemaChange` drops the file and rebuilds it empty on any schema
    /// difference. It used to be on for every DEBUG build — the configuration every developer runs —
    /// against the real store in Application Support, so the next migration anybody added would have
    /// deleted everyone's projects. These six cases are the gate that replaced it: the flag needs an
    /// explicit opt-in *and* an explicitly chosen store, so it can never reach a path nobody named.
    @Test(
        "Erase-on-schema-change needs both the opt-in and an explicit store",
        arguments: zip(
            [
                [:],
                ["MIMIC_ERASE_DB_ON_SCHEMA_CHANGE": "1"],
                ["MIMIC_DATABASE_PATH": "/tmp/throwaway.sqlite"],
                ["MIMIC_ERASE_DB_ON_SCHEMA_CHANGE": "1", "MIMIC_DATABASE_PATH": ""],
                ["MIMIC_ERASE_DB_ON_SCHEMA_CHANGE": "0", "MIMIC_DATABASE_PATH": "/tmp/throwaway.sqlite"],
                ["MIMIC_ERASE_DB_ON_SCHEMA_CHANGE": "1", "MIMIC_DATABASE_PATH": "/tmp/throwaway.sqlite"],
            ] as [[String: String]],
            [false, false, false, false, false, true]
        )
    )
    func eraseIsGated(environment: [String: String], expected: Bool) {
        #expect(AppMigrations.erasesOnSchemaChange(environment: environment) == expected)
    }

    /// Every column another table joins on carries an index.
    ///
    /// `journey` and `journeyStep` got theirs in v2 and `endpoint` and `scenario` did not, which made
    /// it an oversight rather than a policy — and these are the columns `load` and `save` walk, the
    /// latter on an autosave debounce as the user types. Asserted by name so a future migration that
    /// rebuilds a table cannot quietly drop one.
    @Test(
        "Foreign-key columns are indexed",
        arguments: [
            ("endpoint", "endpoint_projectID"),
            ("scenario", "scenario_endpointID"),
            ("journey", "journey_projectID"),
            ("journeyStep", "journeyStep_journeyID"),
        ]
    )
    func foreignKeyColumnsAreIndexed(table: String, index: String) throws {
        let dbQueue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let count = try dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM sqlite_master WHERE type = 'index' AND name = ? AND tbl_name = ?",
                arguments: [index, table]
            ) ?? 0
        }
        #expect(count == 1, "\(table) has no \(index)")
    }

    /// The default migrator is the one the app opens a real store with, and it must never erase.
    @Test("The default migrator migrates forward rather than erasing")
    func defaultMigratorDoesNotErase() throws {
        #expect(AppMigrations.migrator.eraseDatabaseOnSchemaChange == false)
        #expect(AppMigrations.migrator(erasingOnSchemaChange: false).eraseDatabaseOnSchemaChange == false)
        #expect(AppMigrations.migrator(erasingOnSchemaChange: true).eraseDatabaseOnSchemaChange)
    }
}
