import Testing
import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Domain
@testable import MockServerEngine

@Suite("MockServerEngine", .serialized)
struct MockServerEngineTests {

    /// Every sibling suite in this target already asks the OS for a port; this file was the one
    /// holding 18080–18084 by hand. A fixed port fails on the machine that happens to have something
    /// on it, and fails again on the run that starts while the previous socket is still in
    /// `TIME_WAIT` — both of which read as a broken engine rather than a broken test.
    static func freePort() throws -> Int {
        try #require(PlatformSocket.freePort())
    }

    @Test func startAndStopSucceeds() async throws {
        let engine = MockServerEngine()
        let config = ServerConfiguration(port: try Self.freePort(), globalDelayMs: 0)
        try await engine.start(configuration: config)
        try await engine.stop()
    }

    @Test func doubleStartThrowsAlreadyRunning() async throws {
        let engine = MockServerEngine()
        let config = ServerConfiguration(port: try Self.freePort(), globalDelayMs: 0)
        try await engine.start(configuration: config)
        defer { Task { try? await engine.stop() } }

        await #expect(throws: MockServerError.self) {
            try await engine.start(configuration: config)
        }
    }

    @Test func stopWhenNotRunningThrowsNotRunning() async {
        let engine = MockServerEngine()
        await #expect(throws: MockServerError.self) {
            try await engine.stop()
        }
    }

    @Test func updateConfigurationDoesNotThrow() async {
        let engine = MockServerEngine()
        let scenario = Scenario(name: "Success", statusCode: 200, body: "{}")
        let endpoint = Endpoint(name: "Test", method: .get, path: "/test",
                                scenarios: [scenario], activeScenarioID: scenario.id)
        await engine.updateConfiguration(endpoints: [endpoint])
        await engine.updateConfiguration(endpoints: [])
    }

    @Test func logStreamYieldsEntryAfterHTTPRequest() async throws {
        let engine = MockServerEngine()
        let port = try Self.freePort()
        let config = ServerConfiguration(port: port, globalDelayMs: 0)
        try await engine.start(configuration: config)
        defer { Task { try? await engine.stop() } }

        let stream = engine.logStream

        let logTask: Task<RequestLog?, Never> = Task {
            for await entry in stream {
                return entry
            }
            return nil
        }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/anything"))
        _ = try? await URLSession.shared.data(from: url)

        try await Task.sleep(for: .seconds(1))
        logTask.cancel()

        let receivedLog = await logTask.value
        #expect(receivedLog != nil)
        #expect(receivedLog?.path == "/anything")
    }

    @Test func appliesConfiguredDelayBeforeResponding() async throws {
        let engine = MockServerEngine()
        let scenario = Scenario(name: "OK", statusCode: 200, body: "{}")
        let endpoint = Endpoint(name: "Slow", method: .get, path: "/slow",
                                scenarios: [scenario], activeScenarioID: scenario.id, delayMs: 150)
        // global (120) + per-endpoint (150) = 270ms minimum
        await engine.updateConfiguration(endpoints: [endpoint], globalDelayMs: 120)

        let port = try Self.freePort()
        try await engine.start(configuration: ServerConfiguration(port: port, globalDelayMs: 120))
        defer { Task { try? await engine.stop() } }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/slow"))
        let started = ContinuousClock.now
        let (_, response) = try await URLSession.shared.data(from: url)
        let elapsed = ContinuousClock.now - started

        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        #expect(elapsed >= .milliseconds(250))
    }

    // MARK: - Error mapping

    @Test func mapStartErrorConvertsAddressInUse() {
        // Simulate an error whose description contains the EADDRINUSE indicator
        struct FakeBindError: Error, CustomStringConvertible {
            var description: String { "address already in use (EADDRINUSE)" }
        }
        let mapped = VaporConfigurator.mapStartError(FakeBindError(), port: 9090)
        #expect(mapped is MockServerError)
    }

    @Test func mapStartErrorPassesThroughUnrelatedErrors() {
        struct SomeError: Error {}
        let mapped = VaporConfigurator.mapStartError(SomeError(), port: 9090)
        #expect(mapped is SomeError)
    }

    // MARK: - Route matching integration

    @Test func updateConfigurationAffectsRouteMatching() async throws {
        let engine = MockServerEngine()
        let port = try Self.freePort()
        let config = ServerConfiguration(port: port, globalDelayMs: 0)

        let scenario = Scenario(name: "OK", statusCode: 200, body: "{\"status\":\"ok\"}")
        let endpoint = Endpoint(name: "Health", method: .get, path: "/health",
                                scenarios: [scenario], activeScenarioID: scenario.id)
        await engine.updateConfiguration(endpoints: [endpoint])

        try await engine.start(configuration: config)
        defer { Task { try? await engine.stop() } }

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        // `as!` aborts the whole runner on a surprise; `#require` fails this one test and says why.
        let httpResponse = try #require(response as? HTTPURLResponse)

        #expect(httpResponse.statusCode == 200)
        let body = String(data: data, encoding: .utf8)
        #expect(body == "{\"status\":\"ok\"}")
    }
}
