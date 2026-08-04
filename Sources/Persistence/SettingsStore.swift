import GRDB
import Foundation

/// Instance state that must survive a restart but is not part of any project — chiefly *which*
/// project is open.
///
/// A headless daemon has no `UserDefaults` worth speaking of and no window to remember, so this
/// lives in the same SQLite file as the projects. That also means an agent can point
/// `MIMIC_DATABASE_PATH` at a scratch file and get a completely isolated instance, open project
/// included.
public struct SettingsStore: Sendable {
    public enum Key: String, Sendable {
        case openProjectID
    }

    private let dbQueue: DatabaseQueue

    public init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    public func string(_ key: Key) async throws -> String? {
        try await dbQueue.read { db in
            try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [key.rawValue])
        }
    }

    public func uuid(_ key: Key) async throws -> UUID? {
        try await string(key).flatMap(UUID.init(uuidString:))
    }

    public func set(_ key: Key, to value: String?) async throws {
        try await dbQueue.write { db in
            guard let value else {
                try db.execute(sql: "DELETE FROM setting WHERE key = ?", arguments: [key.rawValue])
                return
            }
            try db.execute(
                sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
                arguments: [key.rawValue, value]
            )
        }
    }

    public func set(_ key: Key, to value: UUID?) async throws {
        try await set(key, to: value?.uuidString)
    }
}
