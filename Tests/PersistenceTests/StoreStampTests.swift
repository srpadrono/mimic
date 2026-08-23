import Domain
import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Store provenance")
struct StoreStampTests {

    /// A real, fully migrated store on disk — the shape the app opens.
    private func makeStore() throws -> (queue: DatabaseQueue, cleanup: () -> Void) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-stamp-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("mimic.sqlite")
        let queue = try DatabaseQueue(path: url.path)
        try AppMigrations.migrator.migrate(queue)
        return (queue, { try? FileManager.default.removeItem(at: directory) })
    }

    /// Writes a migration identifier straight into GRDB's ledger.
    ///
    /// Literal SQL rather than a second `DatabaseMigrator` carrying an extra migration: the ledger
    /// row *is* what "a newer build has been here" means on disk, and writing it directly means this
    /// fixture does not move if the migrator does.
    private func recordUnknownMigration(_ identifier: String, in queue: DatabaseQueue) throws {
        try queue.write { db in
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES (?)", arguments: [identifier])
        }
    }

    // MARK: - The high-water mark

    /// Every case is a literal pair, and the first two are the ones a string comparison gets wrong.
    @Test("Only a genuinely newer version replaces the record")
    func shouldRecordComparesVersionsNotStrings() {
        // Newer — must replace.
        #expect(StoreStamp.shouldRecord("0.10.0", over: "0.9.9"))
        #expect(StoreStamp.shouldRecord("0.9.10", over: "0.9.9"))
        #expect(StoreStamp.shouldRecord("1.0.0", over: "0.11.0"))
        // Older — must not.
        #expect(!StoreStamp.shouldRecord("0.9.9", over: "0.10.0"))
        #expect(!StoreStamp.shouldRecord("0.9.9", over: "0.9.10"))
        // The same version is not newer, so nothing is rewritten on an ordinary relaunch.
        #expect(!StoreStamp.shouldRecord("0.10.0", over: "0.10.0"))
        // No record yet — anything is an improvement on knowing nothing.
        #expect(StoreStamp.shouldRecord("0.10.0", over: nil))
        // An unreadable record is replaced; an unreadable running version never overwrites a good one.
        #expect(StoreStamp.shouldRecord("0.10.0", over: "garbage"))
        #expect(!StoreStamp.shouldRecord("garbage", over: "0.10.0"))
    }

    @Test("A fresh store records the build that opened it")
    func stampsOnFirstOpen() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }

        let provenance = try StoreStamp.readAndStamp(queue, version: "0.10.0")

        #expect(provenance.highestVersionSeen == "0.10.0")
        #expect(!provenance.schemaIsAhead)
        #expect(try queue.read { try StoreStamp.recordedVersion($0) } == "0.10.0")
    }

    /// The record is a high-water mark, not a log of the last launch.
    ///
    /// If it were the latter, a downgraded build would warn once, stamp itself, and then report a
    /// clean store on every launch after that — while still being the older build looking at the
    /// newer store.
    @Test("An older build does not lower the record")
    func downgradeLeavesTheRecordAlone() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try StoreStamp.readAndStamp(queue, version: "0.11.0")

        let provenance = try StoreStamp.readAndStamp(queue, version: "0.10.0")

        #expect(provenance.highestVersionSeen == "0.11.0")
        #expect(try queue.read { try StoreStamp.recordedVersion($0) } == "0.11.0")
    }

    // MARK: - Noticing a schema that has run ahead

    @Test("A migration this build does not know about is reported")
    func detectsASupersededSchema() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try StoreStamp.readAndStamp(queue, version: "0.10.0")

        try recordUnknownMigration("v99_written_by_a_later_build", in: queue)

        let provenance = try queue.read { try StoreStamp.read($0) }
        #expect(provenance.schemaIsAhead)
        #expect(provenance.isFromANewerBuild)
    }

    @Test("An ordinary store is not reported as ahead")
    func migratedStoreIsNotAhead() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }

        let provenance = try queue.read { try StoreStamp.read($0) }
        #expect(!provenance.schemaIsAhead)
        #expect(!provenance.isFromANewerBuild)
    }

    /// The stamp is the only surviving evidence of which build to go back to, so an older build must
    /// not write over it — not even to record, truthfully, that it was here.
    @Test("An older build does not stamp itself onto a store that is ahead of it")
    func doesNotStampASupersededStore() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }
        _ = try StoreStamp.readAndStamp(queue, version: "0.11.0")
        try recordUnknownMigration("v99_written_by_a_later_build", in: queue)

        let provenance = try StoreStamp.readAndStamp(queue, version: "0.10.0")

        #expect(provenance.schemaIsAhead)
        #expect(provenance.highestVersionSeen == "0.11.0")
        #expect(try queue.read { try StoreStamp.recordedVersion($0) } == "0.11.0")
    }

    // MARK: - Reading a store that predates the stamp

    /// Every store that exists today is in this state, so "no record" must never read as "brand new".
    @Test("A store written before stamping existed reports an unknown history")
    func absentRecordIsUnknownNotZero() throws {
        let (queue, cleanup) = try makeStore()
        defer { cleanup() }

        let provenance = try queue.read { try StoreStamp.read($0) }

        #expect(provenance.highestVersionSeen == nil)
        #expect(!provenance.schemaIsAhead)
    }

    // MARK: - Through the door the app actually uses

    @Test("Opening the store reports its provenance")
    func projectStoreCarriesProvenance() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-stamp-open", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("mimic.sqlite").path
        let environment = [DatabaseFactory.databasePathEnvironmentKey: path]

        let first = ProjectStore.open(
            makeOnDisk: { try DatabaseFactory.makeAppDatabaseQueue(environment: environment) },
            runningVersion: "0.10.0"
        )
        #expect(first.failure == nil)
        #expect(first.provenance.highestVersionSeen == "0.10.0")

        // A later build opening the same store moves the mark; an earlier one does not.
        let upgraded = ProjectStore.open(
            makeOnDisk: { try DatabaseFactory.makeAppDatabaseQueue(environment: environment) },
            runningVersion: "0.11.0"
        )
        #expect(upgraded.provenance.highestVersionSeen == "0.11.0")

        let downgraded = ProjectStore.open(
            makeOnDisk: { try DatabaseFactory.makeAppDatabaseQueue(environment: environment) },
            runningVersion: "0.10.0"
        )
        #expect(downgraded.provenance.highestVersionSeen == "0.11.0")
    }

    @Test("An in-memory session has no provenance to report")
    func inMemoryFallbackReportsUnknown() {
        struct Unopenable: Error {}
        let opened = ProjectStore.open(makeOnDisk: { throw Unopenable() })

        #expect(opened.isEphemeral)
        #expect(opened.provenance == .unknown)
    }
}
