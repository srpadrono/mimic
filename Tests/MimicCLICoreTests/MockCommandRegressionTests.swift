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
            .endpointUpdate(endpoint: .route(.get, "/old"), spec: EndpointSpec(path: "/new")),
            .endpointGet(endpoint: .id(Self.endpointID)),
            .scenarioUpdate(
                endpoint: .id(Self.endpointID),
                scenario: .id(Self.scenarioID),
                spec: ScenarioSpec(statusCode: 503)
            ),
            .endpointGet(endpoint: .id(Self.endpointID)),
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

        init(project: MockProject) { self.project = project }

        func send(_ command: ControlCommand) async throws -> ControlResponse {
            commands.append(command)
            do {
                guard let outcome = try ProjectCommandExecutor.apply(command, to: &project) else {
                    return .failure(.internalFailure("This test expected a project command."))
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
