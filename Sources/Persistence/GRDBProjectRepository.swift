import GRDB
import Domain
import Foundation

public struct GRDBProjectRepository: ProjectRepository {

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    // MARK: - Save

    public func save(_ project: MockProject) async throws {
        try await dbQueue.write { db in
            // Upsert the top-level project record
            let projectRecord = ProjectRecord(from: project)
            try projectRecord.upsert(db)

            // Delete-all-then-reinsert strategy: simpler than diffing, and acceptable for
            // expected data volumes (< 100 endpoints). If performance becomes an issue with
            // large projects, switch to upsert + orphan cleanup.
            try EndpointRecord
                .filter(Column("projectID") == project.id.uuidString)
                .deleteAll(db)

            // Re-insert each endpoint with sort order derived from enumeration index
            for (index, endpoint) in project.endpoints.enumerated() {
                let endpointRecord = EndpointRecord(
                    from: endpoint,
                    projectID: project.id.uuidString,
                    sortOrder: index
                )
                try endpointRecord.insert(db)

                // Insert each scenario for this endpoint with its own sort order
                for (scenarioIndex, scenario) in endpoint.scenarios.enumerated() {
                    let scenarioRecord = ScenarioRecord(
                        from: scenario,
                        endpointID: endpoint.id.uuidString,
                        sortOrder: scenarioIndex
                    )
                    try scenarioRecord.insert(db)
                }
            }

            // Journeys follow the same strategy. Step order *is* the feature, so `sortOrder` is
            // written from the array index and read back with an explicit ORDER BY — never left to
            // insertion order.
            try JourneyRecord
                .filter(Column("projectID") == project.id.uuidString)
                .deleteAll(db)

            for (index, journey) in project.journeys.enumerated() {
                let journeyRecord = JourneyRecord(
                    from: journey,
                    projectID: project.id.uuidString,
                    sortOrder: index
                )
                try journeyRecord.insert(db)

                for (stepIndex, step) in journey.steps.enumerated() {
                    let stepRecord = JourneyStepRecord(
                        from: step,
                        journeyID: journey.id.uuidString,
                        sortOrder: stepIndex
                    )
                    try stepRecord.insert(db)
                }
            }
        }
    }

    // MARK: - Load

    public func load(id: UUID) async throws -> MockProject {
        try await dbQueue.read { db in
            guard let projectRecord = try ProjectRecord.fetchOne(db, key: id.uuidString) else {
                throw PersistenceError.projectNotFound(id)
            }

            // Fetch all endpoints for this project, ordered by sortOrder
            let endpointRecords = try EndpointRecord
                .filter(Column("projectID") == id.uuidString)
                .order(Column("sortOrder"))
                .fetchAll(db)

            // For each endpoint, fetch its scenarios
            let endpoints: [Endpoint] = try endpointRecords.map { endpointRecord in
                let scenarioRecords = try ScenarioRecord
                    .filter(Column("endpointID") == endpointRecord.id)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
                let scenarios = scenarioRecords.map { $0.toDomain() }
                return endpointRecord.toDomain(scenarios: scenarios)
            }

            let journeyRecords = try JourneyRecord
                .filter(Column("projectID") == id.uuidString)
                .order(Column("sortOrder"))
                .fetchAll(db)

            let journeys: [Journey] = try journeyRecords.map { journeyRecord in
                let stepRecords = try JourneyStepRecord
                    .filter(Column("journeyID") == journeyRecord.id)
                    .order(Column("sortOrder"))
                    .fetchAll(db)
                return journeyRecord.toDomain(steps: stepRecords.map { $0.toDomain() })
            }

            var project = projectRecord.toDomain()
            project.endpoints = endpoints
            project.journeys = journeys
            // A stored selection whose journey has since been removed is dropped rather than kept
            // dangling, so an opened project never reports an active journey it cannot serve.
            if let activeID = project.activeJourneyID, !journeys.contains(where: { $0.id == activeID }) {
                project.activeJourneyID = nil
            }
            return project
        }
    }

    // MARK: - All Projects

    public func allProjects() async throws -> [MockProject] {
        try await dbQueue.read { db in
            let records = try ProjectRecord
                .order(Column("modifiedAt").desc)
                .fetchAll(db)
            // Return lightweight stubs — no endpoints loaded
            return records.map { $0.toDomain() }
        }
    }

    // MARK: - Delete

    public func delete(id: UUID) async throws {
        _ = try await dbQueue.write { db in
            // CASCADE on the schema handles endpoint, scenario, journey and step cleanup
            try ProjectRecord.deleteOne(db, key: id.uuidString)
        }
    }

    // MARK: - Counts

    /// Overrides the protocol's load-everything default with two grouped queries, so
    /// `mimic project list` stays cheap with a hundred stored projects.
    public func projectCounts() async throws -> [UUID: ProjectCounts] {
        try await dbQueue.read { db in
            var result: [UUID: ProjectCounts] = [:]

            let endpointRows = try Row.fetchAll(
                db,
                sql: "SELECT projectID, COUNT(*) AS c FROM endpoint GROUP BY projectID"
            )
            for row in endpointRows {
                guard let id = UUID(uuidString: row["projectID"]) else { continue }
                result[id, default: ProjectCounts(endpoints: 0, journeys: 0)].endpoints = row["c"]
            }

            let journeyRows = try Row.fetchAll(
                db,
                sql: "SELECT projectID, COUNT(*) AS c FROM journey GROUP BY projectID"
            )
            for row in journeyRows {
                guard let id = UUID(uuidString: row["projectID"]) else { continue }
                result[id, default: ProjectCounts(endpoints: 0, journeys: 0)].journeys = row["c"]
            }

            return result
        }
    }
}
