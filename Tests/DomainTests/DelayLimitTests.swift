import Foundation
import Testing
@testable import Domain

@Suite("Five-minute effective wait")
struct DelayLimitTests {
    private static func project(global: Int, endpoint: Int = 0, step: Int = 0, hold: Int = 0) -> MockProject {
        let scenario = Scenario(name: "OK", statusCode: 200)
        return MockProject(
            name: "Timing",
            serverConfiguration: .init(port: 8080, globalDelayMs: global),
            endpoints: [Endpoint(
                name: "Route", method: .get, path: "/route", scenarios: [scenario],
                activeScenarioID: scenario.id, delayMs: endpoint
            )],
            journeys: [Journey(name: "Flow", steps: [JourneyStep(
                name: "Step", method: .get, path: "/step",
                outcome: .networkFailure(.timeout(holdMs: hold)), delayMs: step
            )])]
        )
    }

    private static func rejectsImport(_ project: MockProject) {
        #expect(throws: ValidationError.self) { try ProjectValidator.validate(project) }
    }

    private static func rejectsWrite(_ command: ControlCommand, project: inout MockProject) {
        let before = project
        var candidate = project
        #expect(throws: ControlError.self) { _ = try ProjectCommandExecutor.apply(command, to: &candidate) }
        project = candidate
        #expect(project == before)
    }

    @Test("The effective budget includes global, endpoint, step, and timeout hold")
    func importedBoundaryAndOverflow() throws {
        try ProjectValidator.validate(Self.project(global: 300_000))
        try ProjectValidator.validate(Self.project(global: 100_000, endpoint: 200_000, step: 150_000, hold: 50_000))
        Self.rejectsImport(Self.project(global: 300_001))
        Self.rejectsImport(Self.project(global: 100_000, endpoint: 200_001))
        Self.rejectsImport(Self.project(global: 100_000, step: 150_000, hold: 50_001))
        Self.rejectsImport(Self.project(global: Int.max, endpoint: Int.max, step: Int.max, hold: Int.max))
        Self.rejectsImport(Self.project(global: 1, endpoint: Int.max))
        Self.rejectsImport(Self.project(global: 1, step: Int.max, hold: Int.max))
    }

    @Test("Control writes reject a new excessive effective delay atomically")
    func controlBoundaryAndOverflow() throws {
        var project = Self.project(global: 100_000, endpoint: 200_000, step: 150_000, hold: 50_000)
        Self.rejectsWrite(.serverConfigure(port: nil, globalDelayMs: 100_001), project: &project)
        Self.rejectsWrite(.serverConfigure(port: nil, globalDelayMs: Int.max), project: &project)
        Self.rejectsWrite(.serverConfigure(port: nil, globalDelayMs: nil,
            configuration: .init(port: 8080, globalDelayMs: Int.max)), project: &project)
        Self.rejectsWrite(.endpointUpdate(endpoint: .route(.get, "/route"), spec: .init(delayMs: 200_001)), project: &project)
        Self.rejectsWrite(.journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: .init(delayMs: 150_001)), project: &project)
        Self.rejectsWrite(.journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: .init(failure: .timeout(holdMs: Int.max))), project: &project)
        Self.rejectsWrite(.endpointCreate(name: "New", method: .get, path: "/new", spec: .init(delayMs: 200_001)), project: &project)
        Self.rejectsWrite(.journeyStepAdd(journey: .name("Flow"), step: .init(method: .get, path: "/new", delayMs: 200_001), atIndex: nil), project: &project)
        #expect(project.endpoints.count == 1)
        #expect(project.journeys[0].steps.count == 1)
    }

    @Test("An older excessive project can be inspected, edited, and repaired in stages")
    func legacyStoredProject() throws {
        var project = Self.project(global: 400_000, endpoint: 350_000, step: 250_000, hold: 250_000)
        let originalEndpointID = project.endpoints[0].id
        _ = try ProjectCommandExecutor.apply(.projectRename(name: "Kept"), to: &project)
        #expect(project.name == "Kept")
        Self.rejectsWrite(.endpointUpdate(endpoint: .id(originalEndpointID), spec: .init(delayMs: 350_001)), project: &project)
        _ = try ProjectCommandExecutor.apply(.serverConfigure(port: nil, globalDelayMs: 300_000), to: &project)
        _ = try ProjectCommandExecutor.apply(.endpointUpdate(endpoint: .id(originalEndpointID), spec: .init(delayMs: 0)), to: &project)
        _ = try ProjectCommandExecutor.apply(.journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: .init(delayMs: 0)), to: &project)
        _ = try ProjectCommandExecutor.apply(.journeyStepUpdate(journey: .name("Flow"), step: .index(0), spec: .init(failure: .timeout(holdMs: 0))), to: &project)
        try ProjectValidator.validate(project)
        #expect(project.endpoints[0].id == originalEndpointID)
    }

    @Test("Direct serving plans cannot exceed the budget even with unvalidated old values")
    func servingClamp() {
        #expect(ResponseDelay.combined(globalMs: Int.max, localMs: Int.max) == 300_000)
        #expect(ResponseDelay.combined(globalMs: Int.max, localMs: Int.max, holdMs: Int.max) == 300_000)
        #expect(ResponseDelay.combined(globalMs: 100_000, localMs: 150_000, holdMs: 100_000) == 300_000)
        #expect(ResponseDelay.combined(globalMs: 100_000, localMs: 150_000, holdMs: 50_000) == 300_000)
    }
}
