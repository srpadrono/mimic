import Foundation
import GRDB
import Testing
@testable import Domain
@testable import Persistence

/// The degraded path is the one that matters most and the hardest to reach by hand, so it is the one
/// worth pinning: a database that cannot be opened used to kill the app on launch.
@Suite("Project store fallback")
struct ProjectStoreFallbackTests {

    struct OpenFailure: Error, LocalizedError {
        var errorDescription: String? { "disk is full" }
    }

    @Test("A store that opens normally reports no failure")
    func opensCleanly() {
        let opened = ProjectStore.open(
            makeOnDisk: { try DatabaseQueue() },
            makeInMemory: { try DatabaseQueue() }
        )
        #expect(opened.failure == nil)
        #expect(opened.isEphemeral == false)
    }

    @Test("A store that cannot be opened degrades to memory instead of crashing")
    func degradesToMemory() async throws {
        let opened = ProjectStore.open(
            makeOnDisk: { throw OpenFailure() },
            makeInMemory: { try DatabaseFactory.makeInMemoryDatabaseQueue() }
        )

        #expect(opened.isEphemeral)
        // The app stays usable — that is the whole point of degrading rather than dying.
        let project = MockProject(name: "Still works")
        try await opened.repository.save(project)
        #expect(try await opened.repository.load(id: project.id).name == "Still works")
    }

    @Test("The failure explains what happened and what it means for the user's work")
    func failureIsActionable() {
        let opened = ProjectStore.open(
            makeOnDisk: { throw OpenFailure() },
            makeInMemory: { try DatabaseFactory.makeInMemoryDatabaseQueue() }
        )
        let failure = try! #require(opened.failure)

        // Vague is useless here: the user is about to lose work and needs to know why.
        #expect(failure.contains("nothing will be saved"))
        #expect(failure.contains("disk is full"), "the underlying error must survive")
        #expect(failure.contains("another copy of Mimic"), "name the most likely cause")
    }
}
