import Foundation
import GRDB
import Testing
@testable import Persistence

@Suite("Store backups")
struct StoreBackupTests {

    // MARK: - Scratch space

    /// A directory that goes away with the test, holding a store at the path a caller would pass.
    private func makeScratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-backup-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent("mimic.sqlite")
    }

    private func remove(_ storeURL: URL) {
        try? FileManager.default.removeItem(at: storeURL.deletingLastPathComponent())
    }

    /// Builds a store from **raw SQL literals**.
    ///
    /// Deliberately not `DatabaseFactory.makeAppDatabaseQueue`, and deliberately not `AppMigrations`:
    /// a fixture that comes from the migrator moves whenever the migrator moves, and the point of
    /// these tests is what `StoreBackup` does to bytes that are already on disk.
    private func seed(_ storeURL: URL) throws {
        let dbQueue = try DatabaseQueue(path: storeURL.path)
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO project (id, name) VALUES ('a', 'Checkout flow')")
            try db.execute(sql: "INSERT INTO project (id, name) VALUES ('b', 'Payments sandbox')")
        }
    }

    private func projectNames(in url: URL) throws -> [String] {
        let dbQueue = try DatabaseQueue(path: url.path)
        return try dbQueue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM project ORDER BY id")
        }
    }

    // MARK: - The copy itself

    @Test("A snapshot carries every row the store had")
    func snapshotCopiesTheData() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        try seed(storeURL)

        let snapshot = try StoreBackup.snapshot(of: storeURL, version: "0.10.0")

        #expect(FileManager.default.fileExists(atPath: snapshot.path))
        #expect(try projectNames(in: snapshot) == ["Checkout flow", "Payments sandbox"])
        // …and the original is untouched.
        #expect(try projectNames(in: storeURL) == ["Checkout flow", "Payments sandbox"])
    }

    /// A plain copy of the main SQLite file misses committed changes still in `-wal`. Keep the
    /// source connection open, checkpoint one row, and commit a second row only to WAL so the
    /// fixture itself proves the difference between copying bytes and taking a SQLite snapshot.
    @Test("A snapshot includes a committed row that has not been checkpointed from WAL")
    func snapshotIncludesCommittedWALRows() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let queue = try DatabaseQueue(path: storeURL.path)
        try queue.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE project (id TEXT PRIMARY KEY, name TEXT NOT NULL)")
            try db.execute(sql: "INSERT INTO project (id, name) VALUES ('a', 'Before checkpoint')")
            try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)")
            try db.execute(sql: "INSERT INTO project (id, name) VALUES ('b', 'Committed in WAL')")
        }

        let walURL = URL(fileURLWithPath: storeURL.path + "-wal")
        try #require(FileManager.default.fileExists(atPath: walURL.path),
                     "the source connection must still hold its WAL sidecar")
        #expect(try Data(contentsOf: walURL).count > 32, "the WAL must contain committed frames")

        let rawCopy = storeURL.deletingLastPathComponent().appendingPathComponent("main-file-only.sqlite")
        try FileManager.default.copyItem(at: storeURL, to: rawCopy)
        #expect(try projectNames(in: rawCopy) == ["Before checkpoint"],
                "the fixture must distinguish a raw main-file copy from a SQLite snapshot")
        #expect(try queue.read { db in
            try String.fetchAll(db, sql: "SELECT name FROM project ORDER BY id")
        } == ["Before checkpoint", "Committed in WAL"])

        let snapshot = try withExtendedLifetime(queue) {
            try StoreBackup.snapshot(of: storeURL, version: "0.12.0")
        }
        #expect(try projectNames(in: snapshot) == ["Before checkpoint", "Committed in WAL"])
    }

    @Test("A missing source cannot create an empty backup or prune a prior one")
    func missingSourcePreservesEarlierSnapshots() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let directory = StoreBackup.directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let prior = directory.appendingPathComponent("mimic-20260101-000000-0.11.0.sqlite")
        try seed(prior)

        do {
            _ = try StoreBackup.snapshot(of: storeURL, version: "0.12.0", keeping: 0)
            Issue.record("a missing source was opened as a new empty SQLite database")
        } catch let error as StoreBackupError {
            #expect(error == .sourceMissing(path: storeURL.path))
        } catch {
            Issue.record("missing source threw \(error) instead of StoreBackupError")
        }

        #expect(!FileManager.default.fileExists(atPath: storeURL.path))
        #expect(StoreBackup.snapshots(for: storeURL).map { $0.resolvingSymlinksInPath() }
                == [prior.resolvingSymlinksInPath()])
        #expect(try projectNames(in: prior) == ["Checkout flow", "Payments sandbox"])
    }

    /// The reason `snapshot` opens its own plain connection instead of going through
    /// `DatabaseFactory.makeAppDatabaseQueue`.
    ///
    /// Going through the factory would migrate the store and *then* copy it, so the backup would be
    /// of the schema this build wants rather than the one the user had — useless as a way back.
    /// Revert that connection to the factory and this test goes red: the seeded store has no
    /// `journey` table, and a migrated one does.
    @Test("Taking a snapshot does not migrate the store it copies")
    func snapshotRunsNoMigrations() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        try seed(storeURL)

        let snapshot = try StoreBackup.snapshot(of: storeURL, version: "0.10.0")

        for url in [storeURL, snapshot] {
            let dbQueue = try DatabaseQueue(path: url.path)
            let hasJourneys = try dbQueue.read { db in try db.tableExists("journey") }
            let hasMigrationLedger = try dbQueue.read { db in try db.tableExists("grdb_migrations") }
            #expect(!hasJourneys, "\(url.lastPathComponent) was migrated")
            #expect(!hasMigrationLedger, "\(url.lastPathComponent) was migrated")
        }
    }

    // MARK: - Ordering

    /// The negative control for the filename layout.
    ///
    /// `snapshots(for:)` sorts by filename, which is only chronological while the timestamp comes
    /// before the version. Move the version to the front — the more readable-looking order — and
    /// `mimic-0.9.9-…` sorts after `mimic-0.10.0-…`, so "the newest backup" starts naming an older
    /// one. The two names below are chosen so that the version order and the time order disagree.
    @Test("Snapshots are ordered by when they were taken, not by version string")
    func ordersByTimestampNotVersion() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let directory = StoreBackup.directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let older = "mimic-20260101-000000-0.10.0.sqlite"   // higher version, earlier date
        let newer = "mimic-20260201-000000-0.9.9.sqlite"    // lower version, later date
        for name in [older, newer] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }

        #expect(StoreBackup.snapshots(for: storeURL).map(\.lastPathComponent) == [newer, older])
        #expect(StoreBackup.latest(for: storeURL)?.lastPathComponent == newer)
    }

    @Test("Unrelated files in the directory are ignored")
    func ignoresForeignFiles() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let directory = StoreBackup.directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for name in ["mimic-20260101-000000-0.10.0.sqlite", "notes.txt", "mimic-20260101-000000-0.10.0.sqlite-wal", "other.sqlite"] {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }

        #expect(StoreBackup.snapshots(for: storeURL).map(\.lastPathComponent)
            == ["mimic-20260101-000000-0.10.0.sqlite"])
    }

    @Test("An incomplete staging file is neither latest nor pruned as a snapshot")
    func stagingFileIsOutsideTheSnapshotSet() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let directory = StoreBackup.directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let complete = directory.appendingPathComponent("mimic-20260101-000000-0.11.0.sqlite")
        let staging = directory.appendingPathComponent(".mimic-20270101-000000-0.12.0.sqlite.fixed.pending")
        try seed(complete)
        try Data("unfinished".utf8).write(to: staging)

        #expect(StoreBackup.latest(for: storeURL)?.resolvingSymlinksInPath()
                == complete.resolvingSymlinksInPath())
        try StoreBackup.prune(for: storeURL, keeping: 0)
        #expect(StoreBackup.snapshots(for: storeURL).isEmpty)
        #expect(FileManager.default.fileExists(atPath: staging.path),
                "pruning must not treat a partial staging file as a completed backup")
    }

    // MARK: - Pruning

    @Test("Pruning keeps the newest and deletes the rest")
    func pruneKeepsTheNewest() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        let directory = StoreBackup.directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let names = [
            "mimic-20260101-000000-0.9.0.sqlite",
            "mimic-20260102-000000-0.9.1.sqlite",
            "mimic-20260103-000000-0.9.2.sqlite",
            "mimic-20260104-000000-0.9.3.sqlite",
            "mimic-20260105-000000-0.10.0.sqlite",
        ]
        for name in names {
            FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data())
        }

        try StoreBackup.prune(for: storeURL, keeping: 3)

        #expect(StoreBackup.snapshots(for: storeURL).map(\.lastPathComponent) == [
            "mimic-20260105-000000-0.10.0.sqlite",
            "mimic-20260104-000000-0.9.3.sqlite",
            "mimic-20260103-000000-0.9.2.sqlite",
        ])
    }

    @Test("Taking a snapshot prunes older ones")
    func snapshotPrunesAsItGoes() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        try seed(storeURL)

        // Four distinct seconds, so the names are distinct and ordered.
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        for offset in 0..<4 {
            _ = try StoreBackup.snapshot(
                of: storeURL,
                version: "0.10.\(offset)",
                date: base.addingTimeInterval(TimeInterval(offset)),
                keeping: 3
            )
        }

        let remaining = StoreBackup.snapshots(for: storeURL)
        #expect(remaining.count == 3)
        // The one that went is the oldest, and every survivor still reads.
        #expect(remaining.allSatisfy { $0.lastPathComponent.contains("0.10.1")
            || $0.lastPathComponent.contains("0.10.2")
            || $0.lastPathComponent.contains("0.10.3") })
        for survivor in remaining {
            #expect(try projectNames(in: survivor) == ["Checkout flow", "Payments sandbox"])
        }
    }

    // MARK: - Naming

    @Test("Two snapshots inside one second do not overwrite each other")
    func sameSecondSnapshotsCoexist() throws {
        let storeURL = try makeScratch()
        defer { remove(storeURL) }
        try seed(storeURL)
        let instant = Date(timeIntervalSince1970: 1_800_000_000)

        let first = try StoreBackup.snapshot(of: storeURL, version: "0.10.0", date: instant)
        let second = try StoreBackup.snapshot(of: storeURL, version: "0.10.0", date: instant)

        #expect(first != second)
        #expect(StoreBackup.snapshots(for: storeURL).count == 2)
        let firstNames = try projectNames(in: first)
        let secondNames = try projectNames(in: second)
        #expect(firstNames == secondNames)
    }

    /// The timestamp is UTC and fixed-width, both of which the sort depends on.
    ///
    /// Pinned against a literal rather than against another call to `timestamp` — a test that asks
    /// the formatter what the formatter produces cannot fail.
    @Test("Timestamps are fixed-width UTC")
    func timestampIsSortableUTC() {
        // 2026-08-23T14:02:31Z
        #expect(StoreBackup.timestamp(Date(timeIntervalSince1970: 1_787_493_751)) == "20260823-140231")
        // Midnight on New Year's Day 2026 UTC — the case that loses its zeroes if the format is not
        // zero-padded, and shifts a day if it is rendered in a local time zone west of UTC.
        #expect(StoreBackup.timestamp(Date(timeIntervalSince1970: 1_767_225_600)) == "20260101-000000")
    }

    @Test("A version that is not filename-safe still produces one file")
    func sanitizesVersionsForFilenames() {
        #expect(StoreBackup.sanitize("0.10.0") == "0.10.0")
        #expect(StoreBackup.sanitize("0.11.0-beta.1") == "0.11.0-beta.1")
        #expect(StoreBackup.sanitize("0.10.0/../etc") == "0.10.0-..-etc")
        #expect(StoreBackup.sanitize("") == "unknown")
    }
}
