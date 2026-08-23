import Domain
import Foundation
import GRDB

/// What this store can tell us about the builds that have opened it.
public struct StoreProvenance: Sendable, Equatable {

    /// The newest Mimic that has ever opened this store, as it recorded itself.
    ///
    /// `nil` for a store written before this was recorded, which is every store that exists today —
    /// so its absence means "we do not know", never "this is the first build".
    public let highestVersionSeen: String?

    /// The store carries migrations this build has never heard of.
    ///
    /// This is the mechanical, exact signal, and it is the one to branch on. ``highestVersionSeen``
    /// is for the sentence shown to a person; this is the fact.
    public let schemaIsAhead: Bool

    public init(highestVersionSeen: String?, schemaIsAhead: Bool) {
        self.highestVersionSeen = highestVersionSeen
        self.schemaIsAhead = schemaIsAhead
    }

    public static let unknown = StoreProvenance(highestVersionSeen: nil, schemaIsAhead: false)

    /// Whether an older build should hold back from writing to this store.
    public var isFromANewerBuild: Bool { schemaIsAhead }

    /// What to tell someone whose store was written by a build newer than the one they are running.
    ///
    /// `nil` when there is nothing to say, so the caller has one thing to check rather than a
    /// boolean and a string that can disagree.
    ///
    /// The wording leads with the consequence rather than the diagnosis. "Schema is ahead" is
    /// accurate and tells a person nothing about what happens to their projects if they carry on,
    /// which is the only question they have.
    public func warning(latestBackup: URL? = nil) -> String? {
        guard schemaIsAhead else { return nil }
        let writer = highestVersionSeen.map { "Mimic \($0)" } ?? "a newer version of Mimic"
        var lines = """
        Your projects were last saved by \(writer), which stores them in a format this version \
        does not fully understand. You can look around, but saving from here may drop anything \
        the newer version added.

        Install the current version of Mimic to open them safely.
        """
        if let latestBackup {
            lines += "\n\nA copy taken before the last update is at \(latestBackup.path)."
        }
        return lines
    }
}

/// Records which build last opened the store, and notices when the store has run ahead of us.
///
/// This is the *migration*-level counterpart to the document-level guard in
/// ``ProjectRecord/toDomain(name:)``, which refuses a project whose `schemaVersion` is higher than
/// this build understands. That guard catches a change to the shape of a project. It cannot catch a
/// change to the shape of the **database**: add a migration in 0.11.0 that puts a new column on
/// `endpoint`, open the store with 0.10.0, and every read succeeds — SQLite does not mind columns
/// nobody selected, and `MockProject.currentSchemaVersion` never moved because the document is
/// unchanged from the old build's point of view. Then the old build saves, `GRDBProjectRepository`
/// deletes and reinserts the rows through the columns *it* knows, and the new column's values are
/// gone. No error, no alert, nothing in a log.
///
/// The signal for that is not a version string, it is the migration ledger: GRDB's
/// `hasBeenSuperseded` is true exactly when the database carries migration identifiers this
/// migrator does not declare. The version string is kept alongside it only so the warning can name
/// the build a person needs to go back to.
public enum StoreStamp {

    /// The key in the `setting` table — the table the v2 migration created for exactly this kind of
    /// instance-level fact and which, until now, nothing has read.
    public static let settingKey = "lastOpenedByVersion"

    /// Reads what the store knows about itself, then records this build if it is the newest to date.
    ///
    /// The two halves are one operation on purpose. Reading and then stamping in separate database
    /// accesses leaves a window where a second process does the same thing, and the value written is
    /// whichever landed last rather than the highest — the exact read-then-write shape this
    /// repository's concurrency rules call out. One `write` closure is one transaction.
    @discardableResult
    public static func readAndStamp(_ dbQueue: DatabaseQueue, version: String) throws -> StoreProvenance {
        try dbQueue.write { db in
            let provenance = try read(db)

            // Never write over the record when the store is ahead of us. That row is the only
            // remaining evidence of which build a person has to go back to, and an older build
            // stamping itself on top of it destroys the answer while reporting the question.
            guard !provenance.schemaIsAhead else { return provenance }

            if shouldRecord(version, over: provenance.highestVersionSeen) {
                try stamp(version, in: db)
                return StoreProvenance(highestVersionSeen: version, schemaIsAhead: false)
            }
            return provenance
        }
    }

    public static func read(_ db: Database) throws -> StoreProvenance {
        StoreProvenance(
            highestVersionSeen: try recordedVersion(db),
            schemaIsAhead: try AppMigrations.migrator.hasBeenSuperseded(db)
        )
    }

    static func recordedVersion(_ db: Database) throws -> String? {
        guard try db.tableExists("setting") else { return nil }
        return try String.fetchOne(db, sql: "SELECT value FROM setting WHERE key = ?", arguments: [settingKey])
    }

    static func stamp(_ version: String, in db: Database) throws {
        try db.execute(
            sql: "INSERT INTO setting (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
            arguments: [settingKey, version]
        )
    }

    /// Whether `version` should replace `recorded` — that is, whether it is genuinely newer.
    ///
    /// The record is a high-water mark, not a log of the last launch. Storing "whatever opened it
    /// most recently" would erase the warning on the *second* launch of a downgraded build: the
    /// first launch warns, stamps itself, and every launch after that sees its own version and
    /// reports nothing wrong, while the store is still the newer one.
    ///
    /// An unreadable recorded value is treated as "no record" rather than as something to preserve;
    /// the alternative is a store that can never be stamped again because of one bad row.
    static func shouldRecord(_ version: String, over recorded: String?) -> Bool {
        guard let recorded, let recordedVersion = ReleaseVersion(recorded) else { return true }
        guard let running = ReleaseVersion(version) else { return false }
        return running > recordedVersion
    }
}
