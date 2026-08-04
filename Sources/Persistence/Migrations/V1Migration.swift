import GRDB

/// Schema migrations for Mimic's SQLite database.
///
/// `v1` is the original project/endpoint/scenario schema. `v2` adds journeys — stored relationally
/// rather than as a JSON blob so a step can be queried, reordered, and diffed like any other row.
enum AppMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        #if DEBUG
        // In DEBUG builds, erase the database on schema changes so developers
        // get a clean slate when iterating on the schema.
        migrator.eraseDatabaseOnSchemaChange = true
        #endif

        registerAll(on: &migrator)
        return migrator
    }

    /// The migrations themselves, without the DEBUG erase-on-schema-change behaviour.
    ///
    /// Separated so a test can verify that a real database *migrates forward* — with the erase flag
    /// set, an older database would simply be wiped and the test would prove nothing. It also means
    /// tests exercise these definitions rather than a hand-copied duplicate that silently rots every
    /// time a migration is added.
    static func registerAll(on migrator: inout DatabaseMigrator) {
        migrator.registerMigration("v1_initial_schema") { db in
            // Projects table — top-level container for a set of endpoints
            try db.create(table: "project") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("schemaVersion", .integer).notNull()
                t.column("name", .text).notNull()
                t.column("createdAt", .datetime).notNull()
                t.column("modifiedAt", .datetime).notNull()
                t.column("serverPort", .integer).notNull()
                t.column("globalDelayMs", .integer).notNull()
            }

            // Endpoints table — individual API route definitions
            try db.create(table: "endpoint") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("activeScenarioID", .text)
                t.column("delayMs", .integer).notNull()
                t.column("groupTag", .text)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }

            // Scenarios table — response variations per endpoint
            try db.create(table: "scenario") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("endpointID", .text).notNull()
                    .references("endpoint", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("statusCode", .integer).notNull()
                t.column("headersJSON", .text).notNull()
                t.column("body", .text)
                t.column("bodyContentType", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
        }

        migrator.registerMigration("v2_journeys") { db in
            // Which journey overlays endpoint resolution. Nullable: most projects have none.
            try db.alter(table: "project") { t in
                t.add(column: "activeJourneyID", .text)
            }

            try db.create(table: "journey") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("projectID", .text).notNull()
                    .references("project", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("summary", .text)
                t.column("matchMode", .text).notNull()
                t.column("completion", .text).notNull()
                t.column("unmatchedBehavior", .text).notNull()
                t.column("autoAdvance", .boolean).notNull().defaults(to: true)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "journey_projectID", on: "journey", columns: ["projectID"])

            // A step is either a scripted response (statusCode set) or a transport failure
            // (failureKind set). Storing both shapes in one table keeps ordering trivial — the
            // sequence is the feature — and the mutual exclusion is enforced when mapping to Domain.
            try db.create(table: "journeyStep") { t in
                t.column("id", .text).primaryKey().notNull()
                t.column("journeyID", .text).notNull()
                    .references("journey", onDelete: .cascade)
                t.column("name", .text).notNull()
                t.column("method", .text).notNull()
                t.column("path", .text).notNull()
                t.column("statusCode", .integer)
                t.column("headersJSON", .text).notNull().defaults(to: "{}")
                t.column("body", .text)
                t.column("contentType", .text).notNull()
                t.column("failureKind", .text)
                t.column("failureHoldMs", .integer)
                t.column("delayMs", .integer).notNull().defaults(to: 0)
                t.column("repeatCount", .integer).notNull().defaults(to: 1)
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
            }
            try db.create(index: "journeyStep_journeyID", on: "journeyStep", columns: ["journeyID"])

            // Key-value store for instance-level state the control plane needs to survive a restart
            // (most importantly: which project is open in a headless daemon).
            try db.create(table: "setting") { t in
                t.column("key", .text).primaryKey().notNull()
                t.column("value", .text).notNull()
            }
        }

        migrator.registerMigration("v3_graphql_operation") { db in
            // GraphQL routes everything through one path, so an endpoint needs a body-level
            // discriminator to be addressable at all. Nullable: every REST mock leaves it empty.
            try db.alter(table: "endpoint") { t in
                t.add(column: "graphqlOperation", .text)
            }
            try db.alter(table: "journeyStep") { t in
                t.add(column: "graphqlOperation", .text)
            }
        }
    }
}
