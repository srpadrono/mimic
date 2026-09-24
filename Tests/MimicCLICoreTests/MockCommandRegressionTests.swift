import Domain
import Foundation
import Testing
@testable import MimicCLICore

@Suite("Mock command regressions")
struct MockCommandRegressionTests {
    private static let endpointID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let otherEndpointID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private static let scenarioID = UUID(uuidString: "00000000-0000-0000-0000-000000000201")!

    /// The real project executor gives a renamed endpoint only its new route. This fixture pins the
    /// old route literally, so reverting the CLI's stable-ID follow-up makes the invocation fail.
    @Test("Endpoint update follows the returned ID after changing its route")
    func endpointUpdateAfterRouteChange() async throws {
        let endpoint = Endpoint(
            id: Self.endpointID,
            name: "Old",
            method: .get,
            path: "/old",
            scenarios: [Scenario(id: Self.scenarioID, name: "Default", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let transport = ProjectTransport(project: MockProject(name: "Fixture", endpoints: [endpoint]))

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "503",
            ])
        }

        #expect(status == 0)
        let project = await transport.projectSnapshot()
        #expect(project.endpoints[0].path == "/new")
        #expect(project.endpoints[0].scenarios[0].statusCode == 503)
        let commands = await transport.commandsSnapshot()
        #expect(commands == [
            .endpointGet(endpoint: .route(.get, "/old")),
            .endpointUpdateWithActiveScenario(
                endpoint: .id(Self.endpointID),
                spec: EndpointSpec(path: "/new"),
                scenarioSpec: ScenarioSpec(statusCode: 503)
            ),
        ])
    }

    @Test("A combined edit keeps the endpoint selected before another client reuses its route")
    func combinedUpdateKeepsPreflightEndpointID() async throws {
        let endpoint = Endpoint(
            id: Self.endpointID,
            name: "Original",
            method: .get,
            path: "/old",
            scenarios: [Scenario(id: Self.scenarioID, name: "Default", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let transport = ProjectTransport(
            project: MockProject(name: "Fixture", endpoints: [endpoint]),
            replaceRouteOwnerBeforeCombinedEdit: true
        )

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "503",
            ])
        }

        #expect(status == 0)
        let endpoints = await transport.projectSnapshot().endpoints
        #expect(endpoints.count == 2)
        #expect(endpoints.first(where: { $0.id == Self.endpointID })?.path == "/new")
        #expect(endpoints.first(where: { $0.id == Self.endpointID })?.scenarios.first?.statusCode == 503)
        #expect(endpoints.first(where: { $0.id != Self.endpointID })?.path == "/old")
        #expect(endpoints.first(where: { $0.id != Self.endpointID })?.scenarios.first?.statusCode == 200)
        #expect(await transport.commandsSnapshot() == [
            .endpointGet(endpoint: .route(.get, "/old")),
            .endpointUpdateWithActiveScenario(
                endpoint: .id(Self.endpointID),
                spec: EndpointSpec(path: "/new"),
                scenarioSpec: ScenarioSpec(statusCode: 503)
            ),
        ])
    }

    @Test("A successful combined edit stays successful if another client deletes its endpoint")
    func combinedUpdateDoesNotReadAfterSuccess() async throws {
        let endpoint = Endpoint(
            id: Self.endpointID,
            name: "Original",
            method: .get,
            path: "/old",
            scenarios: [Scenario(id: Self.scenarioID, name: "Default", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let transport = ProjectTransport(
            project: MockProject(name: "Fixture", endpoints: [endpoint]),
            deleteEndpointAfterCombinedEdit: true
        )

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "503",
            ])
        }

        #expect(status == 0)
        #expect(await transport.projectSnapshot().endpoints.isEmpty)
        #expect(await transport.commandsSnapshot().map(\.kind) == [
            .endpointGet, .endpointUpdateWithActiveScenario,
        ])
    }

    @Test("A refused response does not leave the route half of a combined update applied")
    func combinedUpdateRejectsInvalidStatusBeforeRouteChange() async throws {
        let endpoint = Endpoint(
            id: Self.endpointID,
            name: "Original",
            method: .get,
            path: "/old",
            scenarios: [Scenario(id: Self.scenarioID, name: "Default", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let transport = ProjectTransport(project: MockProject(name: "Fixture", endpoints: [endpoint]))

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "700",
            ])
        }

        #expect(status == 4)
        #expect(await transport.projectSnapshot().endpoints[0] == endpoint)
        #expect(await transport.commandsSnapshot().isEmpty)
    }

    @Test("A missing active scenario is reported before changing endpoint fields")
    func combinedUpdateRequiresActiveScenarioBeforeRouteChange() async throws {
        let endpoint = Endpoint(id: Self.endpointID, name: "Original", method: .get, path: "/old")
        let transport = ProjectTransport(project: MockProject(name: "Fixture", endpoints: [endpoint]))

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "503",
            ])
        }

        #expect(status == 2)
        #expect(await transport.projectSnapshot().endpoints[0] == endpoint)
        #expect(await transport.commandsSnapshot() == [.endpointGet(endpoint: .route(.get, "/old"))])
    }

    @Test("Concurrent scenario removal between preflight and write cannot leave a route edit behind")
    func combinedUpdateRemainsAtomicAcrossConcurrentRemoval() async throws {
        let endpoint = Endpoint(
            id: Self.endpointID,
            name: "Original",
            method: .get,
            path: "/old",
            scenarios: [Scenario(id: Self.scenarioID, name: "Default", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let transport = ProjectTransport(
            project: MockProject(name: "Fixture", endpoints: [endpoint]),
            deleteActiveScenarioBeforeEndpointEdit: true
        )

        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: [
                "endpoint", "update", "GET", "/old", "--new-path", "/new", "--status", "503",
            ])
        }

        #expect(status == 4)
        let project = await transport.projectSnapshot()
        #expect(project.endpoints[0].path == "/old")
        #expect(project.endpoints[0].scenarios.isEmpty)
        #expect(await transport.commandsSnapshot().map(\.kind) == [
            .endpointGet, .endpointUpdateWithActiveScenario,
        ])
    }

    @Test("Scenario mutations accept an endpoint ID when two endpoints share a route")
    func scenarioMutationsSelectSharedRouteByID() async throws {
        let first = Endpoint(
            id: Self.endpointID,
            name: "First",
            method: .get,
            path: "/shared",
            scenarios: [Scenario(id: Self.scenarioID, name: "Base", statusCode: 200)],
            activeScenarioID: Self.scenarioID
        )
        let second = Endpoint(
            id: Self.otherEndpointID,
            name: "Second",
            method: .get,
            path: "/shared",
            scenarios: [Scenario(name: "Base", statusCode: 200)]
        )
        let transport = ProjectTransport(project: MockProject(name: "Fixture", endpoints: [first, second]))

        func run(_ arguments: [String]) async -> Int32 {
            await ControlTransportOverride.$current.withValue(transport) {
                await MimicCommand.run(arguments: arguments)
            }
        }

        // The route form is ambiguous, and the executor must refuse it without changing either.
        #expect(await run(["scenario", "update", "GET", "/shared", "Base", "--status", "500"]) == 4)
        #expect(await transport.projectSnapshot().endpoints.map { $0.scenarios[0].statusCode } == [200, 200])

        let id = Self.otherEndpointID.uuidString
        #expect(await run(["scenario", "update", "--id", id, "Base", "--status", "503"]) == 0)
        #expect(await run(["scenario", "create", "--id", id, "Alternate", "--status", "201", "--activate"]) == 0)
        #expect(await run(["scenario", "activate", "--id", id, "Base"]) == 0)
        #expect(await run(["scenario", "delete", "--id", id, "Alternate"]) == 0)

        let project = await transport.projectSnapshot()
        #expect(project.endpoints[0].scenarios.map(\.statusCode) == [200])
        #expect(project.endpoints[1].scenarios.map(\.statusCode) == [503])
        #expect(project.endpoints[1].activeScenarioID == project.endpoints[1].scenarios[0].id)
        let commands = await transport.commandsSnapshot()
        #expect(commands.map(\.kind) == [
            .scenarioUpdate, .scenarioUpdate, .scenarioCreate, .scenarioActivate,
            .scenarioActivate, .scenarioDelete,
        ])
        for command in commands.dropFirst() {
            switch command {
            case let .scenarioCreate(endpoint, _, _),
                 let .scenarioUpdate(endpoint, _, _),
                 let .scenarioActivate(endpoint, _),
                 let .scenarioDelete(endpoint, _):
                #expect(endpoint == .id(Self.otherEndpointID))
            default:
                Issue.record("Unexpected command \(command)")
            }
        }
    }

    @Test("Scenario create --activate refuses a success response without a scenario")
    func scenarioActivationNeedsCreatedScenario() async {
        let transport = MissingScenarioTransport()
        let status = await ControlTransportOverride.$current.withValue(transport) {
            await MimicCommand.run(arguments: ["scenario", "create", "GET", "/target", "Other", "--activate"])
        }

        #expect(status == 4)
        #expect(await transport.commandsSnapshot() == [
            .scenarioCreate(endpoint: .route(.get, "/target"), name: "Other", spec: ScenarioSpec()),
        ])
    }

    private actor MissingScenarioTransport: ControlTransport {
        nonisolated let baseURL = URL(string: "http://127.0.0.1:8787")!
        private var commands: [ControlCommand] = []

        func send(_ command: ControlCommand) async throws -> ControlResponse {
            commands.append(command)
            return .success(.message("Created scenario, but no scenario was returned."))
        }

        func isReachable() async -> Bool { true }
        func commandsSnapshot() -> [ControlCommand] { commands }
    }

    private actor ProjectTransport: ControlTransport {
        nonisolated let baseURL = URL(string: "http://127.0.0.1:8787")!
        private var project: MockProject
        private var commands: [ControlCommand] = []
        private var deleteActiveScenarioBeforeEndpointEdit: Bool
        private var deleteEndpointAfterCombinedEdit: Bool
        private var replaceRouteOwnerBeforeCombinedEdit: Bool

        init(
            project: MockProject,
            deleteActiveScenarioBeforeEndpointEdit: Bool = false,
            deleteEndpointAfterCombinedEdit: Bool = false,
            replaceRouteOwnerBeforeCombinedEdit: Bool = false
        ) {
            self.project = project
            self.deleteActiveScenarioBeforeEndpointEdit = deleteActiveScenarioBeforeEndpointEdit
            self.deleteEndpointAfterCombinedEdit = deleteEndpointAfterCombinedEdit
            self.replaceRouteOwnerBeforeCombinedEdit = replaceRouteOwnerBeforeCombinedEdit
        }

        func send(_ command: ControlCommand) async throws -> ControlResponse {
            commands.append(command)
            do {
                if replaceRouteOwnerBeforeCombinedEdit, command.kind == .endpointUpdateWithActiveScenario {
                    replaceRouteOwnerBeforeCombinedEdit = false
                    _ = try ProjectCommandExecutor.apply(
                        .endpointUpdate(
                            endpoint: .id(MockCommandRegressionTests.endpointID),
                            spec: EndpointSpec(path: "/moved")
                        ),
                        to: &project
                    )
                    _ = try ProjectCommandExecutor.apply(
                        .endpointCreate(name: "Replacement", method: .get, path: "/old", spec: nil),
                        to: &project
                    )
                }
                if deleteActiveScenarioBeforeEndpointEdit,
                   command.kind == .endpointUpdate || command.kind == .endpointUpdateWithActiveScenario {
                    deleteActiveScenarioBeforeEndpointEdit = false
                    _ = try ProjectCommandExecutor.apply(
                        .scenarioDelete(
                            endpoint: .id(MockCommandRegressionTests.endpointID),
                            scenario: .id(MockCommandRegressionTests.scenarioID)
                        ),
                        to: &project
                    )
                }
                guard let outcome = try ProjectCommandExecutor.apply(command, to: &project) else {
                    return .failure(.internalFailure("This test expected a project command."))
                }
                if deleteEndpointAfterCombinedEdit, command.kind == .endpointUpdateWithActiveScenario {
                    deleteEndpointAfterCombinedEdit = false
                    _ = try ProjectCommandExecutor.apply(
                        .endpointDelete(endpoint: .id(MockCommandRegressionTests.endpointID)),
                        to: &project
                    )
                }
                return .success(outcome.result)
            } catch let error as ControlError {
                return .failure(error)
            }
        }

        func isReachable() async -> Bool { true }
        func projectSnapshot() -> MockProject { project }
        func commandsSnapshot() -> [ControlCommand] { commands }
    }
}
