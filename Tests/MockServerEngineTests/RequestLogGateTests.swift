import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Domain
import Testing
import Vapor
@testable import MockServerEngine

@Suite("Request log backpressure", .timeLimit(.minutes(1)))
struct RequestLogGateTests {
    private func waitForEmpty(_ gate: RequestLogGate) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let pending = await gate.outstandingCount
            let active = await gate.activeCount
            if pending == 0, active == 0 { break }
            try #require(ContinuousClock.now < deadline, "A released request kept its slot.")
            await Task.yield()
        }
    }

    @Test("A full gate rejects immediately and recovers after a log is processed")
    func saturationAndRecovery() async throws {
        let gate = RequestLogGate()
        var leases: [RequestLogLease] = []
        for _ in 0..<RequestLogGate.capacity {
            leases.append(try #require(await gate.tryAcquireLease()))
        }
        #expect(await gate.outstandingCount == RequestLogGate.capacity)
        #expect(await gate.tryAcquireLease() == nil)
        #expect(await gate.outstandingCount == RequestLogGate.capacity)

        #expect(leases[0].transferToConsumer())
        await gate.acknowledge()
        #expect(await gate.tryAcquireLease() == nil, "The first handler still owns an active slot.")
        leases[0].release()
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await gate.activeCount == RequestLogGate.capacity {
            try #require(ContinuousClock.now < deadline, "The completed handler kept its active slot.")
            await Task.yield()
        }
        let recovered = try #require(await gate.tryAcquireLease())
        recovered.release()
        for lease in leases.dropFirst() { lease.release() }
        try await waitForEmpty(gate)
    }

    @Test("A terminated stream rejects new admissions even after slots are returned")
    func terminationRejectsAdmission() async throws {
        let gate = RequestLogGate()
        let lease = try #require(await gate.tryAcquireLease())
        await gate.terminate()
        #expect(await gate.tryAcquireLease() == nil)
        lease.release()
        try await waitForEmpty(gate)
        #expect(await gate.tryAcquireLease() == nil)
    }

    @Test("Dropping an unconsumed Vapor response returns its proxy slot")
    func unconsumedResponseReturnsSlot() async throws {
        let gate = RequestLogGate()
        func makeResponse() async throws -> Response {
            let lease = try #require(await gate.tryAcquireLease())
            return Response(status: .ok, body: .init(managedAsyncStream: { _ in
                lease.release()
            }))
        }

        var response: Response? = try await makeResponse()
        #expect(response != nil)
        #expect(await gate.outstandingCount == 1)
        response = nil

        try await waitForEmpty(gate)
    }
}

@Suite("Request log wire backpressure", .serialized, .timeLimit(.minutes(1)))
struct RequestLogBackpressureWireTests {
    @Test("Acknowledged logs do not free handlers still serving delayed responses")
    func delayedHandlersKeepAdmissionSlots() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        try await engine.start(configuration: .init(port: port, globalDelayMs: 1_500))
        defer { Task { try? await engine.stop() } }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpMaximumConnectionsPerHost = RequestLogGate.capacity + 1
        configuration.timeoutIntervalForRequest = 5
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let drain = Task {
            for await _ in engine.logStream { await engine.acknowledgeLog() }
        }
        defer { drain.cancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/slow"))
        let active = (0..<RequestLogGate.capacity).map { _ in
            Task { try await session.data(from: url) }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let handlers = await engine.logGate.activeCount
            let pending = await engine.logGate.outstandingCount
            if handlers == RequestLogGate.capacity, pending == 0 { break }
            try #require(ContinuousClock.now < deadline, "The delayed handlers did not fill admission.")
            await Task.yield()
        }

        let (_, rejected) = try await session.data(from: url)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 503)
        #expect(await engine.logGate.activeCount == RequestLogGate.capacity)

        for call in active {
            let (_, response) = try await call.value
            #expect((response as? HTTPURLResponse)?.statusCode == 404)
        }
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.logGate.activeCount != 0 {
            try #require(ContinuousClock.now < recoveryDeadline, "Completed delayed handlers kept admission.")
            await Task.yield()
        }
        let (_, recovered) = try await session.data(from: url)
        #expect((recovered as? HTTPURLResponse)?.statusCode == 404)
        try await engine.stop()
    }

    @Test("Saturation rejects before journey resolution and recovers without losing accepted logs")
    func fullQueueRejectsWithoutAdvancingJourney() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        let fillScenario = Scenario(name: "Fill", statusCode: 200)
        let fill = Endpoint(name: "Fill", path: "/queued/:id", scenarios: [fillScenario],
            activeScenarioID: fillScenario.id)
        let journey = Journey(name: "Admission", steps: [
            JourneyStep(name: "First", path: "/journey", outcome: .respond(JourneyResponse(statusCode: 201)))
        ])
        await engine.updateConfiguration(endpoints: [fill], globalDelayMs: 0, journey: journey)
        try await engine.start(configuration: .init(port: port, globalDelayMs: 0))
        defer { Task { try? await engine.stop() } }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }

        for index in 0..<RequestLogGate.capacity {
            let url = try #require(URL(string: "http://127.0.0.1:\(port)/queued/\(index)"))
            let (_, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        #expect(await engine.logGate.outstandingCount == RequestLogGate.capacity)
        #expect(await engine.journeyStatus()?.totalServed == 0)

        let journeyURL = try #require(URL(string: "http://127.0.0.1:\(port)/journey"))
        let (_, rejected) = try await session.data(from: journeyURL)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 503)
        #expect(await engine.logGate.outstandingCount == RequestLogGate.capacity)
        #expect(await engine.journeyStatus()?.totalServed == 0)

        var logs = engine.logStream.makeAsyncIterator()
        let first = try #require(await logs.next())
        #expect(first.path == "/queued/0")
        await engine.acknowledgeLog()

        let (_, admitted) = try await session.data(from: journeyURL)
        #expect((admitted as? HTTPURLResponse)?.statusCode == 201)
        #expect(await engine.journeyStatus()?.totalServed == 1)
        for index in 1..<RequestLogGate.capacity {
            let log = try #require(await logs.next())
            #expect(log.path == "/queued/\(index)")
            await engine.acknowledgeLog()
        }
        // The rejected attempt did not take a log slot; the next entry is the accepted retry.
        let last = try #require(await logs.next())
        #expect(last.path == "/journey")
        await engine.acknowledgeLog()
        #expect(await engine.logGate.outstandingCount == 0)
        try await engine.stop()
    }
}
