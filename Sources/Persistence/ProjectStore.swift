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

        public init(repository: any ProjectRepository, failure: String?) {
            self.repository = repository
            self.failure = failure
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
    public static func open(
        makeOnDisk: () throws -> DatabaseQueue = { try DatabaseFactory.makeAppDatabaseQueue() },
        makeInMemory: () throws -> DatabaseQueue = { try DatabaseFactory.makeInMemoryDatabaseQueue() }
    ) -> Opened {
        do {
            return Opened(repository: GRDBProjectRepository(dbQueue: try makeOnDisk()), failure: nil)
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
