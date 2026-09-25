import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Vapor
import Domain
@testable import MockServerEngine

@Suite("Backend pass-through", .serialized, .timeLimit(.minutes(1)))
struct PassthroughTests {
    private static func port() throws -> Int { try #require(PlatformSocket.freePort()) }

    private static func endpoint(_ path: String, body: String, backendID: UUID? = nil) -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: 200, body: body)
        return Endpoint(name: path, path: path, scenarios: [scenario], activeScenarioID: scenario.id, backendID: backendID)
    }

    @Test("Complete response files are private and removed when their owner is released")
    func responseFileLifetime() throws {
        var file: CapturedResponseFile? = try CapturedResponseFile(data: Data("complete".utf8))
        let directory = try #require(file?.directory)
        let url = try #require(file?.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "complete")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        file = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("A bounded log consumer receives every request from a parallel burst")
    func burstDoesNotDropLogs() async throws {
        let proxy = MockServerEngine(), upstream = MockServerEngine()
        let local = try Self.port(), real = try Self.port()
        await upstream.updateConfiguration(endpoints: [Self.endpoint("/burst/:id", body: "complete reply")])
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        try await proxy.start(configuration: .init(port: local, globalDelayMs: 0,
            upstreamURL: "http://127.0.0.1:\(real)"))
        let upstreamDrain = Task {
            for await _ in upstream.logStream { await upstream.acknowledgeLog() }
        }
        defer {
            upstreamDrain.cancel()
            Task { try? await proxy.stop(); try? await upstream.stop() }
        }
        // Drain while traffic continues, with each wave below the admission limit.
        let drain = Task { () -> Set<String> in
            var paths = Set<String>()
            for await log in proxy.logStream {
                await proxy.acknowledgeLog()
                if log.path == "/sentinel" { break }
                #expect(log.outcome == .passthrough)
                #expect(log.responseBody == "complete reply")
                paths.insert(log.path)
            }
            return paths
        }
        defer { drain.cancel() }
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for batch in 0..<69 {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for offset in 0..<16 {
                    let index = batch * 16 + offset
                    guard index < 1100 else { continue }
                    group.addTask {
                        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(local)/burst/\(index)")!)
                        #expect((response as? HTTPURLResponse)?.statusCode == 200)
                    }
                }
                try await group.waitForAll()
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(3))
            while await proxy.logGate.outstandingCount != 0 {
                try #require(ContinuousClock.now < deadline, "The consumer fell behind the bounded burst.")
                await Task.yield()
            }
        }
        // Every batch has completed before the sentinel, so all its logs were submitted.
        _ = try await session.data(from: URL(string: "http://127.0.0.1:\(local)/sentinel")!)
        let paths = await drain.value
        #expect(paths.count == 1100)
        #expect(paths.contains("/burst/0"))
        #expect(paths.contains("/burst/1099"))
    }

    @Test("Proxy logs continue on the same stream after stop and restart")
    func proxyLogsSurviveRestart() async throws {
        let proxy = MockServerEngine(), upstream = MockServerEngine()
        let local = try Self.port(), real = try Self.port()
        await upstream.updateConfiguration(endpoints: [Self.endpoint("/restarted", body: "upstream reply")])
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        defer { Task { try? await proxy.stop(); try? await upstream.stop() } }

        let configuration = ServerConfiguration(port: local, globalDelayMs: 0,
            upstreamURL: "http://127.0.0.1:\(real)")
        let url = try #require(URL(string: "http://127.0.0.1:\(local)/restarted"))
        let session = JourneyServingTests.session()
        defer { session.invalidateAndCancel() }
        var logs = proxy.logStream.makeAsyncIterator()
        for _ in 0..<2 {
            try await proxy.start(configuration: configuration)
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(String(decoding: data, as: UTF8.self) == "upstream reply")
            let log = try #require(await logs.next())
            #expect(log.path == "/restarted")
            #expect(log.outcome == .passthrough)
            await proxy.acknowledgeLog()
            try await proxy.stop()
        }
    }

    @Test("Proxy rejects at saturation before contacting its backend and captures after recovery")
    func proxyRejectsBeforeResponsePreview() async throws {
        let proxy = MockServerEngine(), upstream = MockServerEngine()
        let local = try Self.port(), real = try Self.port()
        let largeBody = String(repeating: "x", count: RequestLog.maxLoggedBodyBytes + 1)
        await upstream.updateConfiguration(endpoints: [Self.endpoint("/live", body: largeBody)])
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        defer { Task { try? await proxy.stop(); try? await upstream.stop() } }

        await proxy.updateConfiguration(endpoints: [Self.endpoint("/fill/:id", body: "filled")])
        try await proxy.start(configuration: .init(port: local, globalDelayMs: 0,
            upstreamURL: "http://127.0.0.1:\(real)"))
        let session = JourneyServingTests.session(timeout: 10)
        defer { session.invalidateAndCancel() }
        for index in 0..<RequestLogGate.pendingLogCapacity {
            let url = try #require(URL(string: "http://127.0.0.1:\(local)/fill/\(index)"))
            _ = try await session.data(from: url)
        }
        #expect(await proxy.logGate.outstandingCount == RequestLogGate.pendingLogCapacity)

        let liveURL = try #require(URL(string: "http://127.0.0.1:\(local)/live"))
        let (_, rejected) = try await session.data(from: liveURL)
        #expect((rejected as? HTTPURLResponse)?.statusCode == 503)
        #expect(await upstream.logGate.outstandingCount == 0)

        // Processing one old log frees the proxy to contact the upstream. The accepted retry's
        // complete large response must still be captured.
        var logs = proxy.logStream.makeAsyncIterator()
        let first = try #require(await logs.next())
        #expect(first.path == "/fill/0")
        await proxy.acknowledgeLog()
        let (data, response) = try await session.data(from: liveURL)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(String(decoding: data, as: UTF8.self) == largeBody)

        for index in 1..<RequestLogGate.pendingLogCapacity {
            let log = try #require(await logs.next())
            #expect(log.path == "/fill/\(index)")
            await proxy.acknowledgeLog()
        }
        let captured = try #require(await logs.next())
        #expect(captured.path == "/live")
        #expect(captured.outcome == .passthrough)
        #expect(try captured.capturedResponseBody?.text() == largeBody)
        await proxy.acknowledgeLog()
        #expect(await proxy.logGate.outstandingCount == 0)
    }

    @Test("Each local port uses its own mocks and real backend")
    func twoBackendTraffic() async throws {
        let upstreamA = MockServerEngine()
        let upstreamB = MockServerEngine()
        let proxy = MockServerEngine()
        let realA = try Self.port(), realB = try Self.port()
        let localA = try Self.port(), localB = try Self.port()
        let backendID = UUID()
        await upstreamA.updateConfiguration(endpoints: [Self.endpoint("/live", body: "real-a")])
        await upstreamB.updateConfiguration(endpoints: [Self.endpoint("/live", body: "real-b")])
        try await upstreamA.start(configuration: .init(port: realA, globalDelayMs: 0))
        try await upstreamB.start(configuration: .init(port: realB, globalDelayMs: 0))
        defer {
            Task {
                try? await proxy.stop()
                try? await upstreamA.stop()
                try? await upstreamB.stop()
            }
        }
        await proxy.updateConfiguration(endpoints: [
            Self.endpoint("/same", body: "mock-a"),
            Self.endpoint("/same", body: "mock-b", backendID: backendID),
        ])
        try await proxy.start(configuration: .init(
            port: localA, globalDelayMs: 0, upstreamURL: "http://127.0.0.1:\(realA)",
            backends: [.init(id: backendID, name: "B", port: localB, upstreamURL: "http://127.0.0.1:\(realB)")]
        ))

        func body(_ port: Int, _ path: String) async throws -> String {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)\(path)")!)
            return String(decoding: data, as: UTF8.self)
        }
        #expect(try await body(localA, "/same") == "mock-a")
        #expect(try await body(localB, "/same") == "mock-b")
        #expect(try await body(localA, "/live") == "real-a")
        #expect(try await body(localB, "/live") == "real-b")
    }

    @Test("A strict journey block never reaches the real backend")
    func blockedJourneyDoesNotForward() async throws {
        let proxy = MockServerEngine()
        let local = try Self.port()
        let real = try Self.port()
        let upstream = MockServerEngine()
        await upstream.updateConfiguration(endpoints: [Self.endpoint("/blocked", body: "should-not-arrive")])
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        defer { Task { try? await proxy.stop(); try? await upstream.stop() } }
        let journey = Journey(name: "Strict", steps: [
            JourneyStep(name: "Only", path: "/only", outcome: .respond(JourneyResponse()))
        ], unmatchedBehavior: .notFound)
        await proxy.updateConfiguration(endpoints: [], globalDelayMs: 0, journey: journey)
        try await proxy.start(configuration: .init(port: local, globalDelayMs: 0, upstreamURL: "http://127.0.0.1:\(real)"))
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(local)/blocked")!)
        #expect((response as? HTTPURLResponse)?.statusCode == 404)
        #expect(String(decoding: data, as: UTF8.self) == "Request is not part of the active journey.")
    }
    @Test("Disabling forwarding takes effect without rebinding the listener")
    func disableLive() async throws {
        let upstream = MockServerEngine(), proxy = MockServerEngine()
        let real = try Self.port(), local = try Self.port()
        await upstream.updateConfiguration(endpoints: [Self.endpoint("/live", body: "real")])
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        defer { Task { try? await proxy.stop(); try? await upstream.stop() } }
        var config = ServerConfiguration(port: local, globalDelayMs: 0, upstreamURL: "http://127.0.0.1:\(real)")
        try await proxy.start(configuration: config)
        let url = URL(string: "http://127.0.0.1:\(local)/live")!
        let (before, _) = try await URLSession.shared.data(from: url)
        #expect(String(decoding: before, as: UTF8.self) == "real")
        config.passthroughEnabled = false
        await proxy.updateServerConfiguration(config)
        let (_, after) = try await URLSession.shared.data(from: url)
        #expect((after as? HTTPURLResponse)?.statusCode == 404)
    }

    @Test("Repeated cookies survive and Connection-nominated headers do not")
    func headers() {
        let input = Vapor.HTTPHeaders([("Set-Cookie", "a=one; Path=/"), ("Set-Cookie", "b=two; Path=/"),
            ("Connection", "X-Hop, keep-alive"), ("X-Hop", "private"), ("Content-Encoding", "gzip")])
        let forwarded = ProxyForwarder.endToEndHeaders(input)
        #expect(forwarded["Set-Cookie"] == ["a=one; Path=/", "b=two; Path=/"])
        #expect(forwarded["X-Hop"].isEmpty)
        #expect(forwarded["Connection"].isEmpty)
        #expect(forwarded["Content-Encoding"] == ["gzip"])
    }

}
