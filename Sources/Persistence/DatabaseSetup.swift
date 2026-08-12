import GRDB
import Foundation

public enum DatabaseFactory {

    /// How long SQLite waits for a lock before giving up.
    ///
    /// Quitting Mimic and starting it again immediately is a normal sequence — `mimic app stop`
    /// followed by `mimic app start` does exactly that — and the outgoing process can still hold the
    /// database for a moment. Without a busy timeout the new process fails the very first read with
    /// `SQLite error 5: database is locked`, which the app's `try!` turns into a crash on launch.
    /// Waiting briefly costs nothing and removes the race.
    public static let busyTimeoutSeconds: TimeInterval = 5

    static var appConfiguration: Configuration {
        var configuration = Configuration()
        configuration.busyMode = .timeout(busyTimeoutSeconds)
        return configuration
    }
    /// Environment override for the SQLite location.
    ///
    /// A CI job or an agent-driven test run needs a throwaway store it can delete between runs, and
    /// a sandboxed app keeps its database inside its container where an unsandboxed CLI cannot reach.
    /// Pointing both at one explicit path is the only way they can share state.
    public static let databasePathEnvironmentKey = "MIMIC_DATABASE_PATH"

    /// Creates a DatabaseQueue backed by a SQLite file in Application Support — or at
    /// `MIMIC_DATABASE_PATH` when that is set. Runs all pending migrations before returning.
    public static func makeAppDatabaseQueue(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> DatabaseQueue {
        let dbURL = try resolveDatabaseURL(environment: environment)
        try FileManager.default.createDirectory(
            at: dbURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let dbQueue = try DatabaseQueue(path: dbURL.path, configuration: appConfiguration)
        let migrator = AppMigrations.migrator(
            erasingOnSchemaChange: AppMigrations.erasesOnSchemaChange(environment: environment)
        )
        try migrator.migrate(dbQueue)
        return dbQueue
    }

    /// The file the app or CLI will open, so callers can report it without opening the database.
    public static func resolveDatabaseURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment[databasePathEnvironmentKey], !override.isEmpty {
            return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
        }
        let appSupportURL = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return appSupportURL
            .appendingPathComponent("devxa.Mimic", isDirectory: true)
            .appendingPathComponent("mimic.sqlite")
    }

    /// Creates an in-memory DatabaseQueue for use in unit tests.
    public static func makeInMemoryDatabaseQueue() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try AppMigrations.migrator.migrate(dbQueue)
        return dbQueue
    }
}
