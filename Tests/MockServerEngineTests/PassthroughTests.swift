import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Domain
@testable import MockServerEngine

@Suite("Backend pass-through", .serialized, .timeLimit(.minutes(1)))
struct PassthroughTests {
    private static func port() throws -> Int { try #require(PlatformSocket.freePort()) }

    private static func endpoint(_ path: String, body: String, backendID: UUID? = nil) -> Endpoint {
        let scenario = Scenario(name: "Default", statusCode: 200, body: body)
        return Endpoint(name: path, path: path, scenarios: [scenario], activeScenarioID: scenario.id, backendID: backendID)
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
}
