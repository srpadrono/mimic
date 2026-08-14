import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Persistence

@Suite("Journey persistence")
struct JourneyPersistenceTests {

    static func makeRepository() throws -> (GRDBProjectRepository, DatabaseQueue) {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        return (GRDBProjectRepository(dbQueue: queue), queue)
    }

    static func projectWithJourneys() throws -> MockProject {
        var project = MockProject(
            name: "Checkout",
            serverConfiguration: ServerConfiguration(port: 9091, globalDelayMs: 40)
        )
        _ = try ProjectCommandExecutor.apply(
            .endpointCreate(name: "Login", method: .post, path: "/login", spec: EndpointSpec(delayMs: 15, groupTag: "Auth")),
            to: &project
        )
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "retry-after-failure", name: nil),
            to: &project
        )
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "offline-to-online", name: nil),
            to: &project
        )
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "maintenance-window", name: nil),
            to: &project
        )
        project.activeJourneyID = project.journeys[1].id
        return project
    }

    @Test("A project's journeys, steps, and active selection survive a save/load cycle")
    func journeysRoundTrip() async throws {
        let (repository, _) = try Self.makeRepository()
        let original = try Self.projectWithJourneys()

        try await repository.save(original)
        let loaded = try await repository.load(id: original.id)

        #expect(loaded.journeys.count == 3)
        #expect(loaded.activeJourneyID == original.activeJourneyID)
        #expect(loaded.journeys == original.journeys, "journeys must round-trip exactly, order included")
        #expect(loaded.endpoints == original.endpoints)
        #expect(loaded.serverConfiguration == original.serverConfiguration)
    }

    @Test("Step order is preserved, because the order is the whole point of a journey")
    func stepOrderIsPreserved() async throws {
        let (repository, _) = try Self.makeRepository()
        var project = MockProject(name: "Ordered")
        let paths = (0..<12).map { "/step-\($0)" }
        _ = try ProjectCommandExecutor.apply(
            .journeyCreate(
                name: "Long",
                spec: JourneySpec(steps: paths.map { JourneyStepSpec(name: $0, method: .get, path: $0, statusCode: 200) })
            ),
            to: &project
        )

        try await repository.save(project)
        let loaded = try await repository.load(id: project.id)

        #expect(loaded.journeys[0].steps.map(\.path) == paths)
    }

    @Test("Journey order is preserved across a save/load cycle")
    func journeyOrderIsPreserved() async throws {
        let (repository, _) = try Self.makeRepository()
        var project = MockProject(name: "Many")
        for name in ["A", "B", "C", "D"] {
            _ = try ProjectCommandExecutor.apply(.journeyCreate(name: name, spec: nil), to: &project)
        }

        try await repository.save(project)
        let loaded = try await repository.load(id: project.id)

        #expect(loaded.journeys.map(\.name) == ["A", "B", "C", "D"])
    }

    @Test("Transport-failure steps round-trip with their kind and hold time")
    func failureStepsRoundTrip() async throws {
        let (repository, _) = try Self.makeRepository()
        var project = MockProject(name: "Failures")
        _ = try ProjectCommandExecutor.apply(
            .journeyCreate(
                name: "Offline",
                spec: JourneySpec(steps: [
                    JourneyStepSpec(name: "drop", method: .get, path: "/a", failure: .connectionDrop),
                    JourneyStepSpec(name: "hang", method: .get, path: "/b", failure: .timeout(holdMs: 7_500)),
                    JourneyStepSpec(name: "ok", method: .get, path: "/c", statusCode: 200, body: "{}"),
                ])
            ),
            to: &project
        )

        try await repository.save(project)
        let loaded = try await repository.load(id: project.id)

        #expect(loaded.journeys[0].steps[0].outcome == .networkFailure(.connectionDrop))
        #expect(loaded.journeys[0].steps[1].outcome == .networkFailure(.timeout(holdMs: 7_500)))
        #expect(loaded.journeys[0].steps[2].outcome == .respond(JourneyResponse(statusCode: 200, body: "{}")))
    }

    @Test("Response headers, bodies, and options round-trip")
    func responseDetailsRoundTrip() async throws {
        let (repository, _) = try Self.makeRepository()
        var project = MockProject(name: "Details")
        _ = try ProjectCommandExecutor.apply(
            .journeyCreate(
                name: "Rate limits",
                spec: JourneySpec(
                    summary: "429 then 200",
                    matchMode: .strictSequence,
                    completion: .restart,
                    unmatchedBehavior: .notFound,
                    autoAdvance: false,
                    steps: [
                        JourneyStepSpec(
                            name: "429",
                            method: .get,
                            path: "/inbox",
                            statusCode: 429,
                            headers: ["Retry-After": "30", "X-RateLimit-Remaining": "0"],
                            body: #"{"error":"rate_limited"}"#,
                            contentType: .json,
                            delayMs: 120,
                            repeatCount: 4
                        )
                    ]
                )
            ),
            to: &project
        )

        try await repository.save(project)
        let journey = try await repository.load(id: project.id).journeys[0]

        #expect(journey.summary == "429 then 200")
        #expect(journey.matchMode == .strictSequence)
        #expect(journey.completion == .restart)
        #expect(journey.unmatchedBehavior == .notFound)
        #expect(journey.autoAdvance == false)
        #expect(journey.steps[0].delayMs == 120)
        #expect(journey.steps[0].repeatCount == 4)

        guard case let .respond(response) = journey.steps[0].outcome else {
            Issue.record("expected a respond outcome")
            return
        }
        #expect(response.headers["Retry-After"] == "30")
        #expect(response.headers["X-RateLimit-Remaining"] == "0")
        #expect(response.body == #"{"error":"rate_limited"}"#)
    }

    @Test("Re-saving replaces journeys instead of accumulating duplicates")
    func resavingReplacesJourneys() async throws {
        let (repository, queue) = try Self.makeRepository()
        var project = try Self.projectWithJourneys()

        try await repository.save(project)
        _ = try ProjectCommandExecutor.apply(.journeyDelete(journey: .name("Offline then online")), to: &project)
        try await repository.save(project)

        let loaded = try await repository.load(id: project.id)
        #expect(loaded.journeys.count == 2)

        // No orphaned steps left behind by the delete-then-reinsert strategy.
        let stepCount = try await queue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journeyStep") ?? -1
        }
        let expected = loaded.journeys.reduce(0) { $0 + $1.steps.count }
        #expect(stepCount == expected)
    }

    @Test("Deleting a project cascades to its journeys and steps")
    func deleteCascades() async throws {
        let (repository, queue) = try Self.makeRepository()
        let project = try Self.projectWithJourneys()
        try await repository.save(project)

        try await repository.delete(id: project.id)

        let counts = try await queue.read { db in
            (
                journeys: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journey") ?? -1,
                steps: try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM journeyStep") ?? -1
            )
        }
        #expect(counts.journeys == 0)
        #expect(counts.steps == 0)
    }

    @Test("An active journey that was deleted out from under the project loads as no journey")
    func danglingActiveJourneyIsDropped() async throws {
        let (repository, queue) = try Self.makeRepository()
        var project = try Self.projectWithJourneys()
        let activeID = try #require(project.activeJourneyID)
        try await repository.save(project)

        // Simulate an out-of-band deletion, e.g. a concurrent edit from another instance.
        try await queue.write { db in
            try db.execute(sql: "DELETE FROM journey WHERE id = ?", arguments: [activeID.uuidString])
        }

        project = try await repository.load(id: project.id)
        #expect(project.activeJourneyID == nil)
        #expect(project.activeJourney == nil)
    }

    @Test("A v1 database migrates forward with its projects intact")
    func migrationPreservesExistingProjects() async throws {
        // Build a database at v1 only, insert a project, then migrate to the journeys schema.
        let queue = try DatabaseQueue()
        // v1 is written out by hand because it is the *historical* shape, which by definition no
        // longer exists in the current migrator.
        var v1 = DatabaseMigrator()
        v1.registerMigration("v1_initial_schema") { db in
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("schemaVersion", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("serverPort", .integer).notNull()
                t.column("globalDelayMs", .integer).notNull()
            }
            try db.create(table: "endpoint") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("projectID", .text).notNull().references("project", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("activeScenarioID", .text)
                t.column("delayMs", .integer).notNull()
                t.column("groupTag", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(table: "scenario") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("endpointID", .text).notNull().references("endpoint", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("statusCode", .integer).notNull()
                t.column("headersJSON", .text).notNull()
                t.column("body", .text)
                t.column("bodyContentType", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }
        try v1.migrate(queue)

        let legacyID = UUID()
        try await queue.write { db in
            try db.execute(
                sql: """
                INSERT INTO project (id, schemaVersion, name, createdAt, modifiedAt, serverPort, globalDelayMs)
                VALUES (?, 1, 'Legacy', '2025-01-01 00:00:00.000', '2025-01-01 00:00:00.000', 8080, 0)
                """,
                arguments: [legacyID.uuidString]
            )
        }

        // Bring the same file forward with the *real* migrations, not a hand-copied duplicate —
        // otherwise this test silently stops covering anything the moment a migration is added.
        var forward = DatabaseMigrator()
        AppMigrations.registerAll(on: &forward)
        try forward.migrate(queue)

        let repository = GRDBProjectRepository(dbQueue: queue)
        let migrated = try await repository.load(id: legacyID)
        #expect(migrated.name == "Legacy")
        #expect(migrated.journeys.isEmpty)
        #expect(migrated.activeJourneyID == nil)

        // And the migrated project can now hold journeys.
        var withJourney = migrated
        _ = try ProjectCommandExecutor.apply(
            .journeyAddTemplate(templateID: "payment-retry", name: nil),
            to: &withJourney
        )
        try await repository.save(withJourney)
        #expect(try await repository.load(id: legacyID).journeys.count == 1)
    }

    @Test("Listing counts endpoints and journeys without loading whole projects")
    func countsAreCheapAndCorrect() async throws {
        let (repository, _) = try Self.makeRepository()
        let project = try Self.projectWithJourneys()
        try await repository.save(project)

        let counts = try await repository.projectCounts()
        #expect(counts[project.id]?.endpoints == 1)
        #expect(counts[project.id]?.journeys == 3)
    }
}

// `SettingsStoreTests` stood here. `SettingsStore` went with the second host: its one purpose was
// remembering which project a windowless instance had open, its one production consumer was the
// deleted `MimicControlService`, and the window keeps that memory in `RecentProjectsStore` instead.
// The `settings` table it read stays in the schema — migrations are frozen and real databases carry
// the table — it is simply no longer read or written by anything.

@Suite("Database location")
struct DatabaseLocationTests {

    @Test("MIMIC_DATABASE_PATH redirects the store so a test run can be fully isolated")
    func environmentOverrideIsHonored() throws {
        let url = try DatabaseFactory.resolveDatabaseURL(
            environment: ["MIMIC_DATABASE_PATH": "/tmp/mimic-test/scratch.sqlite"]
        )
        #expect(url.path == "/tmp/mimic-test/scratch.sqlite")
    }

    @Test("A tilde in the override is expanded")
    func tildeIsExpanded() throws {
        let url = try DatabaseFactory.resolveDatabaseURL(
            environment: ["MIMIC_DATABASE_PATH": "~/mimic-scratch.sqlite"]
        )
        #expect(url.path.hasPrefix("/"))
        #expect(url.path.contains("mimic-scratch.sqlite"))
        #expect(url.path.contains("~") == false)
    }

    @Test("Without an override the store lands in Application Support")
    func defaultLocation() throws {
        let url = try DatabaseFactory.resolveDatabaseURL(environment: [:])
        #expect(url.lastPathComponent == "mimic.sqlite")
        #expect(url.deletingLastPathComponent().lastPathComponent == "devxa.Mimic")
    }

    @Test("An empty override is ignored rather than resolving to an empty path")
    func emptyOverrideIsIgnored() throws {
        let url = try DatabaseFactory.resolveDatabaseURL(environment: ["MIMIC_DATABASE_PATH": ""])
        #expect(url.lastPathComponent == "mimic.sqlite")
    }
}
