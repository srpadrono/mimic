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

    private static func withProxy(
        endpoints: [Endpoint], basePath: String = "",
        operation: (MockServerEngine, MockServerEngine, Int, Int) async throws -> Void
    ) async throws {
        let proxy = MockServerEngine(), upstream = MockServerEngine()
        let real = try port()
        await upstream.updateConfiguration(endpoints: endpoints)
        try await upstream.start(configuration: .init(port: real, globalDelayMs: 0))
        do {
            // Allocate the second port after the upstream binds, so they cannot be the same.
            let local = try port()
            try await proxy.start(configuration: .init(port: local, globalDelayMs: 0,
                upstreamURL: "http://127.0.0.1:\(real)\(basePath)"))
            try await operation(proxy, upstream, local, real)
            try await proxy.stop()
            try await upstream.stop()
        } catch {
            try? await proxy.stop()
            try? await upstream.stop()
            throw error
        }
    }

    @Test("Complete response files are private and removed when their owner is released")
    func responseFileLifetime() throws {
        var file: CapturedResponseFile? = try CapturedResponseFile(data: Data("complete".utf8))
        let directory = try #require(file?.directory)
        let url = try #require(file?.url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "complete")
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        #expect((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue == 0o700)
        file = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("The target builder does not parse origin-form path segments as authorities")
    func leadingDoubleSlashTarget() {
        #expect(ProxyForwarder.target(base: "https://example.test/api/", requestURI: "//segment/thing?value=a%2Fb")?
            .absoluteString == "https://example.test/api//segment/thing?value=a%2Fb")
    }

    @Test("Vapor-normalized double-slash requests retain their first segment and encoded query")
    func leadingDoubleSlashPath() async throws {
        try await Self.withProxy(
            endpoints: [Self.endpoint("/api/segment/thing", body: "the whole path arrived")], basePath: "/api/"
        ) { proxy, _, local, real in
            let reply = try RawHTTPClient.send(method: "GET", path: "//segment/thing?value=a%2Fb", port: local)
            #expect(reply.statusLine == "HTTP/1.1 200 OK")
            #expect(reply.raw.contains("the whole path arrived"))
            #expect(reply.didClose && !reply.isTruncated)
            var logs = proxy.logStream.makeAsyncIterator()
            let log = try #require(await logs.next())
            // Pinned Vapor constructs URI(path:) and collapses leading slashes before routing.
            // Assert that supported wire behavior rather than inventing raw-path preservation.
            #expect(log.path == "/segment/thing?value=a%2Fb")
            #expect(log.upstreamURL == "http://127.0.0.1:\(real)/api/segment/thing?value=a%2Fb")
            await proxy.acknowledgeLog()
        }
    }

    @Test("A proxied HEAD preserves representation length and releases its log slot without a body")
    func headPreservesMetadata() async throws {
        try await Self.withProxy(endpoints: [
            RealTrafficTests.endpoint(.head, "/metadata", headers: ["X-Trace": "upstream"], body: "hello")
        ]) { proxy, _, local, _ in
            let reply = try RawHTTPClient.send(method: "HEAD", path: "/metadata", port: local)
            #expect(reply.statusLine == "HTTP/1.1 200 OK")
            let parts = reply.raw.components(separatedBy: "\r\n\r\n")
            let head = try #require(parts.first).lowercased()
            #expect(head.components(separatedBy: "\r\n").contains("content-length: 5"))
            #expect(head.components(separatedBy: "\r\n").contains("x-trace: upstream"))
            #expect(parts.dropFirst().joined(separator: "\r\n\r\n").isEmpty)
            #expect(reply.didClose && !reply.isTruncated)
            var logs = proxy.logStream.makeAsyncIterator()
            let log = try #require(await logs.next())
            #expect(log.method == .head)
            #expect(log.outcome == .passthrough)
            #expect(log.responseBody == "")
            #expect(!log.responseBodyTruncated)
            #expect(log.capturedResponseBody == nil)
            #expect(log.responseHeaders.first { $0.key.lowercased() == "content-length" }?.value == "5")
            await proxy.acknowledgeLog()
            #expect(await proxy.logGate.outstandingCount == 0)
        }
    }

    @Test("A preview limit inside a UTF-8 scalar does not mislabel complete text traffic as binary")
    func unicodeAcrossPreviewLimit() async throws {
        let payload = String(repeating: "a", count: ResponseCapture.maxBodyBytes - 1) + "💡"
        try await Self.withProxy(endpoints: [
            RealTrafficTests.endpoint(.get, "/large-unicode", body: payload, contentType: .plainText)
        ]) { proxy, _, local, _ in
            let session = JourneyServingTests.session(timeout: 30)
            defer { session.invalidateAndCancel() }
            let url = try #require(URL(string: "http://127.0.0.1:\(local)/large-unicode"))
            let (data, response) = try await session.data(from: url)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            #expect(data == Data(payload.utf8))
            var logs = proxy.logStream.makeAsyncIterator()
            let log = try #require(await logs.next())
            #expect(log.outcome == .passthrough)
            #expect(log.responseBodyIsBinary == false)
            #expect(log.responseBody == String(repeating: "a", count: RequestLog.maxLoggedBodyBytes))
            #expect(log.responseBodyTruncated)
            #expect(log.capturedResponseBody == nil)
            #expect(throws: ControlError.self) { try ResponseCapture.validate(log) }
            await proxy.acknowledgeLog()
        }
    }

    @Test("Repeated identity encodings still retain the complete text needed to capture a large reply")
    func repeatedIdentityEncoding() async throws {
        let payload = String(repeating: "v", count: RequestLog.maxLoggedBodyBytes + 1)
        try await Self.withProxy(endpoints: [
            RealTrafficTests.endpoint(.get, "/identity", headers: ["Content-Encoding": "identity, identity"],
                body: payload, contentType: .plainText)
        ]) { proxy, _, local, _ in
            let reply = try RawHTTPClient.send(method: "GET", path: "/identity", port: local)
            #expect(reply.statusLine == "HTTP/1.1 200 OK")
            #expect(reply.didClose && !reply.isTruncated)
            var logs = proxy.logStream.makeAsyncIterator()
            let log = try #require(await logs.next())
            #expect(log.outcome == .passthrough)
            #expect(log.responseBodyTruncated)
            #expect(log.capturedResponseBody?.byteCount == RequestLog.maxLoggedBodyBytes + 1)
            #expect(try ResponseCapture.body(log) == payload)
            await proxy.acknowledgeLog()
        }
    }

    @Test("The proxy returns redirects to the client without following them upstream")
    func redirectIsReturnedUnfollowed() async throws {
        try await Self.withProxy(endpoints: [
            RealTrafficTests.endpoint(.get, "/redirect", status: 302, headers: ["Location": "/destination"]),
            Self.endpoint("/destination", body: "the proxy must not fetch this")
        ]) { proxy, upstream, local, _ in
            let reply = try RawHTTPClient.send(method: "GET", path: "/redirect", port: local)
            #expect(reply.statusLine == "HTTP/1.1 302 Found")
            #expect(reply.raw.lowercased().contains("\r\nlocation: /destination\r\n"))
            #expect(reply.didClose && !reply.isTruncated)
            #expect(await upstream.logGate.outstandingCount == 1)
            var logs = proxy.logStream.makeAsyncIterator()
            let log = try #require(await logs.next())
            #expect(log.outcome == .passthrough)
            #expect(log.responseStatusCode == 302)
            await proxy.acknowledgeLog()
        }
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
        #expect(await upstream.logGate.outstandingCount == 0)
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
            ("Connection", "X-Hop, keep-alive"), ("X-Hop", "private"), ("Content-Encoding", "gzip"),
            ("Proxy-Connection", "keep-alive")])
        let forwarded = ProxyForwarder.endToEndHeaders(input)
        #expect(forwarded["Set-Cookie"] == ["a=one; Path=/", "b=two; Path=/"])
        #expect(forwarded["X-Hop"].isEmpty)
        #expect(forwarded["Connection"].isEmpty)
        #expect(forwarded["Proxy-Connection"].isEmpty)
        #expect(forwarded["Content-Encoding"] == ["gzip"])
    }

    @Test("HEAD metadata preservation still removes Connection-nominated content length")
    func headHeaderFiltering() {
        let ordinary = Vapor.HTTPHeaders([("Content-Length", "123"), ("Content-Type", "text/plain")])
        #expect(ProxyForwarder.endToEndHeaders(ordinary, preservingContentLength: true)["Content-Length"] == ["123"])
        let nominated = Vapor.HTTPHeaders([("Connection", "content-length"), ("Content-Length", "123")])
        #expect(ProxyForwarder.endToEndHeaders(nominated, preservingContentLength: true)["Content-Length"].isEmpty)
        #expect(ProxyForwarder.endToEndHeaders(ordinary, request: true)["Content-Length"].isEmpty)
    }

}
