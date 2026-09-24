import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
import Domain
@testable import MockServerEngine

@Suite("Route snapshot", .serialized, .timeLimit(.minutes(1)))
struct RouteSnapshotTests {
    @Test("A resolved response keeps its original project and backend after a later push")
    func resolvedMetadataComesFromTheSameConfiguration() async throws {
        let store = MockRouteStore()
        let backendID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let firstProjectID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
        let secondProjectID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
        let firstScenario = Scenario(name: "First", statusCode: 201, body: "first response")
        let secondScenario = Scenario(name: "Second", statusCode: 202, body: "second response")
        let firstEndpoint = Endpoint(
            name: "First route", path: "/orders", scenarios: [firstScenario],
            activeScenarioID: firstScenario.id, backendID: backendID
        )
        let secondEndpoint = Endpoint(
            name: "Second route", path: "/orders", scenarios: [secondScenario],
            activeScenarioID: secondScenario.id, backendID: backendID
        )
        let firstConfiguration = ServerConfiguration(
            port: 8080, globalDelayMs: 23,
            backends: [BackendConfiguration(id: backendID, name: "First backend", port: 8081)]
        )
        let secondConfiguration = ServerConfiguration(
            port: 8080, globalDelayMs: 7,
            backends: [BackendConfiguration(id: backendID, name: "Second backend", port: 8081)]
        )
        let request = IncomingRequest(method: .get, path: "/orders", backendID: backendID)

        await store.update(
            configuration: firstConfiguration, projectID: firstProjectID,
            endpoints: [firstEndpoint], journey: nil, activationEpoch: 0, revision: 1
        )
        let first = await store.resolve(request: request)

        await store.update(
            configuration: secondConfiguration, projectID: secondProjectID,
            endpoints: [secondEndpoint], journey: nil, activationEpoch: 0, revision: 2
        )
        let second = await store.resolve(request: request)

        #expect(first.response.statusCode == 201)
        #expect(first.response.body == "first response")
        #expect(first.response.delayMs == 23)
        #expect(first.projectID == firstProjectID)
        #expect(first.backend?.name == "First backend")
        #expect(second.response.statusCode == 202)
        #expect(second.response.body == "second response")
        #expect(second.response.delayMs == 7)
        #expect(second.projectID == secondProjectID)
        #expect(second.backend?.name == "Second backend")
    }

    @Test("Settings-only updates preserve the project; explicit nil clears it")
    func nilProjectIDClearsTheStore() async {
        let store = MockRouteStore()
        let projectID = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
        let configuration = ServerConfiguration(port: 8080, globalDelayMs: 0)
        let request = IncomingRequest(method: .get, path: "/missing")

        await store.updateServerConfiguration(configuration, projectID: projectID, revision: 1)
        #expect(await store.resolve(request: request).projectID == projectID)

        await store.updateServerConfiguration(configuration, revision: 2)
        #expect(await store.resolve(request: request).projectID == projectID)

        await store.update(
            configuration: configuration, projectID: nil, endpoints: [],
            journey: nil, activationEpoch: 0, revision: 3
        )
        #expect(await store.resolve(request: request).projectID == nil)

        await store.updateServerConfiguration(configuration, projectID: projectID, revision: 4)
        await store.updateServerConfiguration(configuration, projectID: nil, revision: 5)
        #expect(await store.resolve(request: request).projectID == nil)
    }

    @Test("A late start initialization cannot replace an explicit project snapshot")
    func lateStartKeepsTheNewerConfiguration() async {
        let store = MockRouteStore()
        let projectID = UUID(uuidString: "55555555-5555-5555-5555-555555555555")!
        let scenario = Scenario(name: "Current", statusCode: 200, body: "current response")
        let endpoint = Endpoint(
            name: "Current route", path: "/current", scenarios: [scenario],
            activeScenarioID: scenario.id
        )
        let staleStart = ServerConfiguration(port: 8080, globalDelayMs: 3, primaryName: "Stale")
        let current = ServerConfiguration(port: 8080, globalDelayMs: 11, primaryName: "Current")
        let request = IncomingRequest(method: .get, path: "/current")

        // A direct start initializes a store that has never received an explicit push.
        await store.updateServerConfiguration(staleStart, revision: 1)
        #expect(await store.resolve(request: request).backend?.name == "Stale")

        await store.update(
            configuration: current, projectID: projectID, endpoints: [endpoint],
            journey: nil, activationEpoch: 0, revision: 2
        )
        // This models a start that captured Stale before the push above and reached the store late.
        await store.updateServerConfiguration(staleStart, revision: 1)

        let resolved = await store.resolve(request: request)
        #expect(resolved.response.statusCode == 200)
        #expect(resolved.response.body == "current response")
        #expect(resolved.response.delayMs == 11)
        #expect(resolved.projectID == projectID)
        #expect(resolved.backend?.name == "Current")

        let settingsOnlyStore = MockRouteStore()
        await settingsOnlyStore.updateServerConfiguration(current, revision: 2)
        await settingsOnlyStore.updateServerConfiguration(staleStart, revision: 1)
        #expect(await settingsOnlyStore.resolve(request: request).backend?.name == "Current")
    }

    @Test("A later start can replace settings from an earlier explicit push")
    func laterStartWinsAcrossRestarts() async {
        let store = MockRouteStore()
        let projectID = UUID(uuidString: "66666666-6666-6666-6666-666666666666")!
        let scenario = Scenario(name: "Route", statusCode: 200, body: "unchanged route")
        let endpoint = Endpoint(
            name: "Route", path: "/stable", scenarios: [scenario],
            activeScenarioID: scenario.id
        )
        let pushed = ServerConfiguration(port: 8080, globalDelayMs: 5, primaryName: "Pushed")
        let firstStart = ServerConfiguration(port: 8080, globalDelayMs: 7, primaryName: "First start")
        let restart = ServerConfiguration(port: 8080, globalDelayMs: 9, primaryName: "Restart")
        let request = IncomingRequest(method: .get, path: "/stable")

        await store.update(
            configuration: pushed, projectID: projectID, endpoints: [endpoint],
            journey: nil, activationEpoch: 0, revision: 1
        )
        // The legacy routes API controls effective delay independently of listener settings.
        await store.update(endpoints: [endpoint], globalDelayMs: 17)
        await store.updateServerConfiguration(firstStart, revision: 2)
        #expect(await store.resolve(request: request).backend?.name == "First start")

        await store.updateServerConfiguration(restart, revision: 3)
        let resolved = await store.resolve(request: request)
        #expect(resolved.response.body == "unchanged route")
        #expect(resolved.response.delayMs == 17)
        #expect(resolved.projectID == projectID)
        #expect(resolved.backend?.name == "Restart")

        await store.updateServerConfiguration(restart, projectID: projectID, revision: 4)
        #expect(await store.resolve(request: request).response.delayMs == 17)
    }

    @Test("A real engine restart applies the latest start settings")
    func engineRestartReplacesEarlierSettings() async throws {
        let port = try #require(PlatformSocket.freePort())
        let projectID = UUID(uuidString: "77777777-7777-7777-7777-777777777777")!
        let engine = MockServerEngine()
        let pushed = ServerConfiguration(port: port, globalDelayMs: 0, primaryName: "Pushed")
        let firstStart = ServerConfiguration(port: port, globalDelayMs: 0, primaryName: "First start")
        let restart = ServerConfiguration(port: port, globalDelayMs: 0, primaryName: "Restart")
        let url = try #require(URL(string: "http://127.0.0.1:\(port)/missing"))

        await engine.updateServerConfiguration(pushed, projectID: projectID)
        do {
            try await engine.start(configuration: firstStart)
            _ = try await URLSession.shared.data(from: url)
            let firstLog = await MockServerEngineTests.firstLogEntry(from: engine.logStream, within: .seconds(5))
            #expect(firstLog?.backendName == "First start")

            try await engine.stop()
            try await engine.start(configuration: restart)
            _ = try await URLSession.shared.data(from: url)
            let secondLog = await MockServerEngineTests.firstLogEntry(from: engine.logStream, within: .seconds(5))
            #expect(secondLog?.backendName == "Restart")
            try await engine.stop()
        } catch {
            try? await engine.stop()
            throw error
        }
    }

    @Test("Combined pushes retain a journey run until a new activation")
    func combinedPushPreservesActivationSemantics() async throws {
        let engine = MockServerEngine()
        let configuration = ServerConfiguration(port: 8080, globalDelayMs: 0)
        let journey = Journey(
            name: "Checkout",
            steps: [
                JourneyStep(
                    name: "first", method: .get, path: "/checkout",
                    outcome: .respond(JourneyResponse(statusCode: 409))
                ),
                JourneyStep(
                    name: "second", method: .get, path: "/checkout",
                    outcome: .respond(JourneyResponse(statusCode: 200))
                ),
            ]
        )

        await engine.updateConfiguration(
            configuration: configuration, projectID: nil, endpoints: [],
            journey: journey, activationEpoch: 1
        )
        _ = await engine.advanceJourney()
        #expect(await engine.journeyStatus()?.currentStepIndex == 1)

        await engine.updateConfiguration(
            configuration: configuration, projectID: nil, endpoints: [],
            journey: journey, activationEpoch: 1
        )
        #expect(await engine.journeyStatus()?.currentStepIndex == 1)

        await engine.updateConfiguration(
            configuration: configuration, projectID: nil, endpoints: [],
            journey: journey, activationEpoch: 2
        )
        #expect(await engine.journeyStatus()?.currentStepIndex == 0)
    }
}
