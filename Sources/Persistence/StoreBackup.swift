import Foundation
import GRDB

/// Point-in-time copies of the project store, taken before anything that could rewrite its schema.
///
/// The app's own update flow is the reason this exists. Replacing `Mimic.app` cannot touch the
/// store — the installer writes `/Applications` and `/usr/local/bin`, and the database is in the
/// sandbox container — but the *next launch* runs whatever migrations the new build added, and a
/// migration is the one operation that rewrites a schema in place. Migrations here are forward-only
/// and `eraseDatabaseOnSchemaChange` cannot fire on a real store (see `AppMigrations`), so this is
/// insurance against a migration that is wrong rather than against one that erases. There was
/// previously no insurance at all: `ProjectStore.open` falls back to an in-memory store and says so,
/// which leaves a working app, an honest alert, and no copy of the data on disk to go back to.
///
/// A snapshot is taken with `VACUUM INTO` rather than by copying the file. Copying a SQLite database
/// with the file manager is the classic way to capture a torn one — it can be mid-transaction, and
/// any `-wal`/`-shm` sidecar has to travel with it or the copy silently loses the most recent
/// writes. `VACUUM INTO` asks SQLite for one consistent, self-contained file, which is the same
/// reason it is preferred to `cp` in SQLite's own documentation. This store runs in
/// `journal_mode=delete` today, so there are no sidecars to forget — but a snapshot mechanism that
/// is only correct while that stays true is a trap for whoever changes it.
public enum StoreBackup {

    /// Where snapshots live, beside the store rather than inside it.
    public static let directoryName = "Backups"

    /// How many snapshots survive a prune.
    ///
    /// Three, because the useful history is "before this update, before the one before it" and each
    /// is the size of the whole store. Keeping every snapshot ever taken turns a safety net into a
    /// disk-usage complaint.
    public static let keptSnapshots = 3

    public static func directoryURL(for storeURL: URL) -> URL {
        storeURL.deletingLastPathComponent().appendingPathComponent(directoryName, isDirectory: true)
    }

    /// Takes a snapshot of `storeURL` and prunes older ones, returning the file written.
    ///
    /// Opens its own connection deliberately, and a plain one that runs **no migrations**: a backup
    /// taken through `DatabaseFactory.makeAppDatabaseQueue` would migrate the store first and then
    /// snapshot the result, which is precisely backwards — the copy exists to preserve what was
    /// there *before* this build touched it. It also means a snapshot can be taken of a store the
    /// app itself failed to open, which is when one is worth most.
    @discardableResult
    public static func snapshot(
        of storeURL: URL,
        version: String,
        date: Date = Date(),
        keeping: Int = keptSnapshots
    ) throws -> URL {
        let directory = directoryURL(for: storeURL)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let destination = availableURL(in: directory, stamp: timestamp(date), version: version)

        var configuration = Configuration()
        configuration.busyMode = .timeout(DatabaseFactory.busyTimeoutSeconds)
        let dbQueue = try DatabaseQueue(path: storeURL.path, configuration: configuration)
        try dbQueue.writeWithoutTransaction { db in
            // `VACUUM INTO` refuses a destination that already exists rather than overwriting it,
            // which is the behaviour worth having — `availableURL` has picked an unused name, and if
            // that race is ever lost the error is better than a clobbered snapshot.
            try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path])
        }

        try prune(for: storeURL, keeping: keeping)
        return destination
    }

    /// Every snapshot beside `storeURL`, newest first.
    ///
    /// Ordered by filename, which works only because the timestamp comes *before* the version in the
    /// name. With the version first, `mimic-0.9.9-…` would sort after `mimic-0.10.0-…` for the same
    /// reason `ReleaseVersion` exists at all, and "the newest backup" would start naming an old one
    /// the first time a component reached double digits.
    public static func snapshots(for storeURL: URL) -> [URL] {
        let directory = directoryURL(for: storeURL)
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.lastPathComponent.hasPrefix(filePrefix) && $0.pathExtension == fileExtension }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    public static func latest(for storeURL: URL) -> URL? {
        snapshots(for: storeURL).first
    }

    /// Deletes all but the newest `keeping` snapshots.
    public static func prune(for storeURL: URL, keeping: Int = keptSnapshots) throws {
        guard keeping >= 0 else { return }
        for stale in snapshots(for: storeURL).dropFirst(keeping) {
            try FileManager.default.removeItem(at: stale)
        }
    }

    // MARK: - Naming

    static let filePrefix = "mimic-"
    static let fileExtension = "sqlite"

    /// `20260823-140231` — sortable, second-resolution, and readable without a decoder ring.
    ///
    /// Built from `DateComponents` rather than a `DateFormatter` so it needs no locale, no time zone
    /// negotiation and no shared mutable formatter to reason about across actors. UTC, because a
    /// snapshot taken either side of a daylight-saving change must still sort by when it was taken.
    static func timestamp(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d%02d%02d-%02d%02d%02d",
            parts.year ?? 0, parts.month ?? 0, parts.day ?? 0,
            parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0
        )
    }

    /// Keeps a version safe to put in a filename without changing what it says.
    static func sanitize(_ version: String) -> String {
        let allowed = version.map { character -> Character in
            character.isLetter || character.isNumber || character == "." ? character : "-"
        }
        let text = String(allowed)
        return text.isEmpty ? "unknown" : text
    }

    /// The first unused name for this timestamp and version.
    ///
    /// Two snapshots inside one second is not a normal sequence, but "overwrite the other one" is
    /// the wrong answer to it in a type whose entire job is not losing copies of the database.
    static func availableURL(in directory: URL, stamp: String, version: String) -> URL {
        let base = "\(filePrefix)\(stamp)-\(sanitize(version))"
        var candidate = directory.appendingPathComponent("\(base).\(fileExtension)")
        var suffix = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent("\(base)-\(suffix).\(fileExtension)")
            suffix += 1
        }
        return candidate
    }
}
