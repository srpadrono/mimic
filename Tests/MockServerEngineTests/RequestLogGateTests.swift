import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import MockServerEngine

@Suite("Request log backpressure", .timeLimit(.minutes(1)))
struct RequestLogGateTests {
    private func waitForWaiter(_ gate: RequestLogGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.waitingCount == 0 {
            try #require(ContinuousClock.now < deadline, "The extra publisher never reached the full gate.")
            await Task.yield()
        }
    }

    @Test("A canceled publisher waits for a slot and does not strand it")
    func cancellationPreservesReservation() async throws {
        let gate = RequestLogGate()
        for _ in 0..<RequestLogGate.capacity { #expect(await gate.reserve()) }
        #expect(await gate.outstandingCount == RequestLogGate.capacity)

        let publisher = Task { await gate.reserve() }
        try await waitForWaiter(gate)
        publisher.cancel()
        #expect(await gate.waitingCount == 1)

        await gate.acknowledge()
        #expect(await publisher.value)
        #expect(await gate.outstandingCount == RequestLogGate.capacity)
        for _ in 0..<RequestLogGate.capacity { await gate.acknowledge() }
        #expect(await gate.outstandingCount == 0)
        #expect(await gate.reserve())
    }

    @Test("Stream termination wakes a publisher waiting behind a full gate")
    func terminationReleasesWaiter() async throws {
        let gate = RequestLogGate()
        for _ in 0..<RequestLogGate.capacity { #expect(await gate.reserve()) }
        let publisher = Task { await gate.reserve() }
        try await waitForWaiter(gate)

        await gate.terminate()
        #expect(await publisher.value == false)
        #expect(await gate.reserve() == false)
        #expect(await gate.waitingCount == 0)
    }
}

@Suite("Request log wire backpressure", .serialized, .timeLimit(.minutes(1)))
struct RequestLogBackpressureWireTests {
    @Test("The 33rd response waits until an earlier log has been processed")
    func fullQueueBackpressuresWithoutDropping() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        try await engine.start(configuration: .init(port: port, globalDelayMs: 0))
        defer { Task { try? await engine.stop() } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        for index in 0..<RequestLogGate.capacity {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/queued/\(index)"))
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
        #expect(await engine.logGate.outstandingCount == RequestLogGate.capacity)

        let lastURL = try #require(URL(string: "http://127.0.0.1:\(port)/queued/last"))
        let blocked = Task { try await session.data(from: lastURL) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while await engine.logGate.waitingCount == 0 {
            try #require(ContinuousClock.now < deadline, "The extra HTTP request never reached the full log queue.")
            try await Task.sleep(for: .milliseconds(2))
        }

        var logs = engine.logStream.makeAsyncIterator()
        let first = try #require(await logs.next())
        #expect(first.path == "/queued/0")
        await engine.acknowledgeLog()

        let (_, response) = try await blocked.value
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        for index in 1..<RequestLogGate.capacity {
            let log = try #require(await logs.next())
            #expect(log.path == "/queued/\(index)")
            await engine.acknowledgeLog()
        }
        let last = try #require(await logs.next())
        #expect(last.path == "/queued/last")
        await engine.acknowledgeLog()
        #expect(await engine.logGate.outstandingCount == 0)
        try await engine.stop()
    }
}
