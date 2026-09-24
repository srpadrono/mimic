import Foundation
import Testing
@testable import AppFeatures
@testable import ControlPlane
import Domain

#if DEBUG
/// Holds the real ControlServer immediately before binding, so termination can arrive in a fixed
/// order without sleeps, fixed ports, or a process-wide environment override.
private actor StartupGate {
    private var didEnter = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        didEnter = true
        let waiters = entryWaiters
        entryWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilEntered() async {
        if didEnter { return }
        await withCheckedContinuation { entryWaiters.append($0) }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

private actor EmptyControlHost: ControlHost {
    func execute(_ command: ControlCommand) async -> ControlResponse {
        .success(ControlResult())
    }
}

@Suite("Control plane startup termination", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ControlPlaneStartupTerminationTests {
    private final class ReplyRecorder {
        var didReply = false
    }

    @Test("Termination while startup is suspended leaves no listener or discovery file")
    func terminationBeforePublicationClosesPendingStart() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-coordinator-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let discoveryURL = directory.appendingPathComponent("control.json")

        let gate = StartupGate()
        let server = ControlServer(host: EmptyControlHost(), token: ControlToken.generate())
        await server.setAdvertisementURLForTesting(discoveryURL)
        await server.setBeforeBindingForTesting { await gate.pause() }

        let coordinator = ControlPlaneCoordinator()
        let startup = coordinator.launchControlServer(server, port: 0)
        await gate.waitUntilEntered()

        let reply = ReplyRecorder()
        coordinator.handleTerminationRequest { reply.didReply = true }
        #expect(!reply.didReply, "quit replied before the pending startup was accounted for")

        await gate.release()
        await startup.value

        let deadline = ContinuousClock.now + .seconds(5)
        while !reply.didReply, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reply.didReply)
        #expect(await server.boundPort == nil)
        #expect(!FileManager.default.fileExists(atPath: discoveryURL.path))
        try? await server.stop()
    }

    @Test("A stalled listener startup cannot hold a quit past its deadline")
    func terminationReplyIsBoundedWhenStartupStalls() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-coordinator-stalled-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let discoveryURL = directory.appendingPathComponent("control.json")

        let gate = StartupGate()
        let server = ControlServer(host: EmptyControlHost(), token: ControlToken.generate())
        await server.setAdvertisementURLForTesting(discoveryURL)
        await server.setBeforeBindingForTesting { await gate.pause() }

        let coordinator = ControlPlaneCoordinator()
        let startup = coordinator.launchControlServer(server, port: 0)
        await gate.waitUntilEntered()

        let reply = ReplyRecorder()
        let started = ContinuousClock.now
        coordinator.handleTerminationRequest { reply.didReply = true }
        let deadline = started + .seconds(3)
        while !reply.didReply, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(reply.didReply, "quit waited for a listener startup that had not resumed")
        #expect(ContinuousClock.now - started < .seconds(3))

        // The test keeps the bind gate closed until after the reply, then lets the pending task
        // finish. The termination flag still makes it close without ever publishing a credential.
        await gate.release()
        await startup.value
        #expect(await server.boundPort == nil)
        #expect(!FileManager.default.fileExists(atPath: discoveryURL.path))
        try? await server.stop()
    }
}
#endif
