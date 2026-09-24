import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import Domain
@testable import MockServerEngine

@Suite("Proxy failures", .serialized, .timeLimit(.minutes(1)))
struct ProxyFailureTests {
    @Test("A backend pointed at this listener is refused once")
    func selfLoop() async throws {
        try await Self.checkFailure(
            .selfLoop,
            messagePrefix: "The real backend points back to a Mimic listener in this project."
        )
    }

    @Test("An unreachable backend returns 502 without stopping the listener")
    func unreachableBackend() async throws {
        try await Self.checkFailure(
            .unreachable,
            messagePrefix: "Could not reach the real backend:"
        )
    }

    private enum Backend { case selfLoop, unreachable }

    private static func checkFailure(_ backend: Backend, messagePrefix: String) async throws {
        let localPort = try #require(PlatformSocket.freePort())
        let engine = MockServerEngine()
        await engine.updateConfiguration(endpoints: [
            JourneyServingTests.endpoint(.get, "/alive", 200, body: "still serving")
        ])
        try await engine.start(configuration: .init(port: localPort, globalDelayMs: 0))

        do {
            // Pick the unused port only after the listener binds, so it cannot be the local port.
            let upstreamPort: Int
            switch backend {
            case .selfLoop: upstreamPort = localPort
            case .unreachable: upstreamPort = try #require(PlatformSocket.freePort())
            }
            await engine.updateServerConfiguration(.init(
                port: localPort, globalDelayMs: 0,
                upstreamURL: "http://127.0.0.1:\(upstreamPort)"
            ))

            let baseURL = try #require(URL(string: "http://127.0.0.1:\(localPort)"))
            // The engine can spend up to 10 seconds connecting upstream before it returns 502.
            let session = JourneyServingTests.session(timeout: 20)
            defer { session.invalidateAndCancel() }

            let failure = try await JourneyServingTests.call("GET", "missing", baseURL: baseURL, session: session)
            #expect(failure.status == 502)
            #expect(failure.body.hasPrefix(messagePrefix))

            let alive = try await JourneyServingTests.call("GET", "alive", baseURL: baseURL, session: session)
            #expect(alive.status == 200)
            #expect(alive.body == "still serving")

            // The second request is a sentinel. Both log yields precede their HTTP replies, so
            // requiring it immediately after the failure proves there was exactly one failure log.
            var logs = engine.logStream.makeAsyncIterator()
            let failureLog = try #require(await logs.next())
            let aliveLog = try #require(await logs.next())
            #expect(failureLog.path == "/missing")
            #expect(failureLog.outcome == .proxyFailure)
            #expect(failureLog.responseStatusCode == 502)
            #expect(failureLog.failureLabel == "backend-unavailable")
            #expect(failureLog.responseBody == failure.body)
            #expect(aliveLog.path == "/alive")
            #expect(aliveLog.outcome == .endpoint)
            #expect(aliveLog.responseStatusCode == 200)

            try await engine.stop()
        } catch {
            try? await engine.stop()
            throw error
        }
    }
}
