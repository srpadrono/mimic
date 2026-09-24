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
    @Test("An incomplete HEAD upload closes despite HEAD suppressing response bodies")
    func stalledHeadUploadCloses() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        let scenario = Scenario(name: "Healthy", statusCode: 200)
        let endpoint = Endpoint(name: "Healthy", path: "/healthy", scenarios: [scenario],
            activeScenarioID: scenario.id)
        let journey = Journey(name: "HEAD upload", steps: [
            JourneyStep(name: "First", method: .head, path: "/healthy",
                outcome: .respond(JourneyResponse(statusCode: 201)))
        ])
        await engine.updateConfiguration(endpoints: [endpoint], globalDelayMs: 0, journey: journey)
        try await engine.start(configuration: .init(port: port, globalDelayMs: 0))
        defer { Task { try? await engine.stop() } }

        let upload = try RawHTTPClient.open(method: "HEAD", path: "/healthy", port: port,
            additionalHeaders: [("Content-Length", String(10 << 20))],
            bodyPrefix: Data([0x61]))
        defer { PlatformSocket.close(upload) }
        let response = RawHTTPClient.receive(on: upload, timeout: 12)
        #expect(response.statusLine.contains("408"))
        #expect(response.didClose)
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.logGate.activeCount != 0 {
            try #require(ContinuousClock.now < deadline, "The timed-out HEAD upload kept a slot.")
            await Task.yield()
        }
        #expect(await engine.logGate.outstandingCount == 0)
        #expect(await engine.journeyStatus()?.totalServed == 0)
        let recovered = try RawHTTPClient.send(method: "GET", path: "/healthy", port: port)
        #expect(recovered.statusLine.contains("200"))
        var logs = engine.logStream.makeAsyncIterator()
        let firstLog = try #require(await logs.next())
        #expect(firstLog.path == "/healthy")
        #expect(firstLog.method == .get)
        await engine.acknowledgeLog()
        try await engine.stop()
    }

    @Test("Incomplete admitted uploads expire, close, and leave journeys and logs untouched")
    func stalledUploadsCannotHoldAllAdmissionSlots() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        let healthyResponse = Scenario(name: "Healthy", statusCode: 200, body: "ready")
        let healthy = Endpoint(name: "Healthy", path: "/healthy", scenarios: [healthyResponse],
            activeScenarioID: healthyResponse.id)
        let journey = Journey(name: "Upload", steps: [
            JourneyStep(name: "First", method: .post, path: "/journey",
                outcome: .respond(JourneyResponse(statusCode: 201)))
        ])
        await engine.updateConfiguration(endpoints: [healthy], globalDelayMs: 0, journey: journey)
        try await engine.start(configuration: .init(port: port, globalDelayMs: 0))
        defer { Task { try? await engine.stop() } }

        var uploads: [Int32] = []
        defer { uploads.forEach(PlatformSocket.close) }
        for _ in 0..<RequestLogGate.capacity {
            uploads.append(try RawHTTPClient.open(method: "POST", path: "/journey", port: port,
                additionalHeaders: [("Content-Length", String(10 << 20))],
                bodyPrefix: Data([0x61])))
        }
        let admissionDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.logGate.activeCount < RequestLogGate.capacity {
            try #require(ContinuousClock.now < admissionDeadline,
                "The partial uploads did not fill admission.")
            await Task.yield()
        }
        #expect(await engine.logGate.outstandingCount == RequestLogGate.capacity)
        #expect(await engine.journeyStatus()?.totalServed == 0)

        let rejected = try RawHTTPClient.send(method: "GET", path: "/healthy", port: port,
            timeout: 2)
        #expect(rejected.statusLine.contains("503"))
        #expect(rejected.raw.lowercased().contains("x-mimic-rejection: admission-capacity"))

        // The first read waits for the ten-second deadline. Every connection must then close;
        // otherwise Vapor can retain its NIO body collector after releasing the admission lease.
        let first = RawHTTPClient.receive(on: uploads[0], timeout: 12)
        #expect(first.statusLine.contains("408"))
        #expect(first.raw.lowercased().contains("content-length: 0"))
        #expect(first.raw.lowercased().contains("connection: close"))
        #expect(!first.isTruncated)
        #expect(first.didClose)
        for socketFD in uploads.dropFirst() {
            let response = RawHTTPClient.receive(on: socketFD, timeout: 0.3)
            #expect(response.statusLine.contains("408"))
            #expect(response.didClose)
        }
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while true {
            let active = await engine.logGate.activeCount
            let pending = await engine.logGate.outstandingCount
            if active == 0, pending == 0 { break }
            try #require(ContinuousClock.now < recoveryDeadline,
                "Expired uploads kept admission or pending-log slots.")
            await Task.yield()
        }
        #expect(await engine.journeyStatus()?.totalServed == 0)

        let recovered = try RawHTTPClient.send(method: "GET", path: "/healthy", port: port)
        #expect(recovered.statusLine.contains("200"))
        let journeyResponse = try RawHTTPClient.send(method: "POST", path: "/journey", port: port)
        #expect(journeyResponse.statusLine.contains("201"))
        #expect(await engine.journeyStatus()?.totalServed == 1)
        var logs = engine.logStream.makeAsyncIterator()
        let firstLog = try #require(await logs.next())
        #expect(firstLog.path == "/healthy")
        await engine.acknowledgeLog()
        let secondLog = try #require(await logs.next())
        #expect(secondLog.path == "/journey")
        await engine.acknowledgeLog()
        #expect(await engine.logGate.outstandingCount == 0)
        try await engine.stop()
    }

    @Test("Accepted bodies still collect and oversized bodies still return 413")
    func bodyLimitAfterAdmission() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        try await engine.start(configuration: .init(port: port, globalDelayMs: 0))
        defer { Task { try? await engine.stop() } }
        let session = JourneyServingTests.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/upload"))
        var ordinary = URLRequest(url: url)
        ordinary.httpMethod = "POST"
        ordinary.httpBody = Data("ordinary".utf8)
        let (_, accepted) = try await session.data(for: ordinary)
        #expect((accepted as? HTTPURLResponse)?.statusCode == 404)
        var logs = engine.logStream.makeAsyncIterator()
        let log = try #require(await logs.next())
        #expect(log.requestBody == "ordinary")
        await engine.acknowledgeLog()

        var oversized = URLRequest(url: url)
        oversized.httpMethod = "POST"
        oversized.httpBody = Data(repeating: 0x61, count: (10 << 20) + 1)
        let (_, rejected) = try await session.data(for: oversized)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 413)
        #expect(await engine.logGate.outstandingCount == 0)
        try await engine.stop()
    }

    @Test("Acknowledged logs do not free handlers still serving delayed responses")
    func delayedHandlersKeepAdmissionSlots() async throws {
        let port = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        let scenario = Scenario(name: "Slow", statusCode: 200, body: "slow")
        let endpoint = Endpoint(name: "Slow", path: "/slow", scenarios: [scenario],
            activeScenarioID: scenario.id)
        await engine.updateConfiguration(endpoints: [endpoint], globalDelayMs: 1_500)
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
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
        }
        let recoveryDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while await engine.logGate.activeCount != 0 {
            try #require(ContinuousClock.now < recoveryDeadline, "Completed delayed handlers kept admission.")
            await Task.yield()
        }
        let (_, recovered) = try await session.data(from: url)
        #expect((recovered as? HTTPURLResponse)?.statusCode == 200)
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

        // This client sends only the first byte of a large declared body. Streaming admission
        // must reject it before waiting for the rest of the upload.
        let slowUpload = try RawHTTPClient.send(method: "POST", path: "/journey", port: port,
            additionalHeaders: [("Content-Length", String(10 << 20))],
            bodyPrefix: Data([0x61]), timeout: 2)
        #expect(slowUpload.statusLine.contains("503"))
        #expect(slowUpload.raw.lowercased().contains("x-mimic-rejection: admission-capacity"))
        #expect(await engine.logGate.outstandingCount == RequestLogGate.capacity)

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
