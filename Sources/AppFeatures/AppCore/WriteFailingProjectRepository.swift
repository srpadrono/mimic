#if DEBUG
import Domain
import Foundation

/// A store that reads normally and refuses every write — the seam that makes the autosave
/// indicator's failure arm reachable from a UI test.
///
/// `AutosaveStatusIndicator` has four arms and the suite could only ever see three of them.
/// `.failed` is set from a thrown repository error, in `ProjectWorkspace`, and both production
/// stores are GRDB queues that succeed: the on-disk one and the in-memory fallback alike. So the one
/// arm that reports *lost work* — the red "Save failed" a user must not miss — had no path a running
/// app could take, and the screen that shows it was covered by nothing.
///
/// Reads are forwarded rather than refused, deliberately. A store that also failed to load would
/// never get a project on screen, and the flow under test is "edit something in an open project and
/// watch the save fail", not "fail to open".
///
/// `projectCounts` is forwarded explicitly even though `ProjectRepository` supplies a default. The
/// default is the correct-but-slow one — it loads every project to count it — and `GRDBProjectRepository`
/// overrides it with a query; inheriting the default here would quietly take a decorated session off
/// the fast path for no reason.
///
/// This whole file is `#if DEBUG`. It is wired only through
/// ``UITestSupport/projectRepositoryFailingWritesIfRequested(_:environment:)``, which is itself
/// gated on ``UITestSupport/isRunningUITests(environment:arguments:)`` — a store that swallows saves
/// is exactly the sort of convenience that must never be reachable by an environment variable alone.
///
/// `nonisolated`, the same opt-out `ImportCommitter` takes and for a sharper reason: this module
/// defaults to `MainActor`, `ProjectRepository` is a `Sendable` port whose real conformance runs its
/// transactions on GRDB's own queue, and a decorator that quietly pulled every call onto the main
/// actor would be a test hook that changes the thing it is meant to observe.
nonisolated struct WriteFailingProjectRepository: ProjectRepository {
    let base: any ProjectRepository

    func load(id: UUID) async throws -> MockProject {
        try await base.load(id: id)
    }

    func allProjects() async throws -> [MockProject] {
        try await base.allProjects()
    }

    func projectCounts() async throws -> [UUID: ProjectCounts] {
        try await base.projectCounts()
    }

    func save(_ project: MockProject) async throws {
        throw Failure.writesRefused
    }

    func delete(id: UUID) async throws {
        throw Failure.writesRefused
    }

    /// The text the indicator's tooltip shows, so a run that hits this by accident says why rather
    /// than reading as a real disk failure.
    nonisolated enum Failure: LocalizedError {
        case writesRefused

        var errorDescription: String? {
            "Writes are disabled for this UI test run (MIMIC_FAIL_PROJECT_WRITES=1)."
        }
    }
}
#endif
