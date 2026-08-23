import Domain
import Foundation
import GRDB

/// Opens the project store, degrading rather than failing.
///
/// This lives in Persistence rather than in the app because opening a database is a persistence
/// concern and GRDB is a persistence detail — the whole point of the `ProjectRepository` port is that
/// the app layer never learns which database is behind it.
public enum ProjectStore {

    /// A store that opened, plus why it is not the one on disk if it is not.
    public struct Opened: Sendable {
        public let repository: any ProjectRepository
        /// `nil` when the on-disk store opened normally. Otherwise the session is in memory and this
        /// explains why — the caller is expected to surface it, because unsaved work is not a detail.
        public let failure: String?
        /// What the store on disk says about the builds that have opened it.
        ///
        /// Carried here rather than fetched later because it has to be read at the moment the store
        /// is opened and before anything writes to it — which is the one moment this type already
        /// owns. ``StoreProvenance/unknown`` for an in-memory session, which has no history to have.
        public let provenance: StoreProvenance

        public init(
            repository: any ProjectRepository,
            failure: String?,
            provenance: StoreProvenance = .unknown
        ) {
            self.repository = repository
            self.failure = failure
            self.provenance = provenance
        }

        public var isEphemeral: Bool { failure != nil }
    }

    /// Opens the on-disk store, falling back to memory if it cannot be opened.
    ///
    /// The app used to force-unwrap this, so a database that was locked, unwritable, or on a full
    /// disk killed the process on launch — quitting and relaunching hit exactly that. A local
    /// development tool should stay usable and say what went wrong instead.
    ///
    /// The makers are injectable so the degraded branch is testable; it is the path that matters most
    /// and the hardest to reach by hand.
    /// - Parameter runningVersion: the build doing the opening, recorded in the store as a
    ///   high-water mark so a later, older build can tell it is looking at a newer store. Defaults
    ///   to `ControlAPI.releaseVersion`, which `Scripts/package_release.sh` holds equal to the
    ///   bundle's `MARKETING_VERSION` at release time.
    public static func open(
        makeOnDisk: () throws -> DatabaseQueue = { try DatabaseFactory.makeAppDatabaseQueue() },
        makeInMemory: () throws -> DatabaseQueue = { try DatabaseFactory.makeInMemoryDatabaseQueue() },
        runningVersion: String = ControlAPI.releaseVersion
    ) -> Opened {
        do {
            let dbQueue = try makeOnDisk()
            // Best-effort: a store that opened but whose provenance could not be read is still a
            // working store, and refusing to open it over a bookkeeping row would be a worse
            // failure than the one being guarded against.
            let provenance = (try? StoreStamp.readAndStamp(dbQueue, version: runningVersion)) ?? .unknown
            return Opened(
                repository: GRDBProjectRepository(dbQueue: dbQueue),
                failure: nil,
                provenance: provenance
            )
        } catch {
            guard let fallback = try? makeInMemory() else {
                // An empty in-memory queue essentially cannot fail to open, so reaching here means the
                // process is in no state to run at all.
                preconditionFailure("Could not open any project store: \(error.localizedDescription)")
            }
            return Opened(
                repository: GRDBProjectRepository(dbQueue: fallback),
                failure: """
                Mimic could not open its project database, so this session is running in memory — \
                everything works, but nothing will be saved when you quit.

                \(error.localizedDescription)

                This usually means another copy of Mimic is still running, or the disk is full.
                """
            )
        }
    }
}
