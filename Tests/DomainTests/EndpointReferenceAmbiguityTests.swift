import Foundation
import Testing
@testable import Domain

@Suite("Endpoint references across backends")
struct EndpointReferenceAmbiguityTests {
    private static let primaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let secondaryID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!
    private static let backendID = UUID(uuidString: "00000000-0000-0000-0000-000000000103")!

    private static var project: MockProject {
        let primaryScenario = Scenario(name: "Default", statusCode: 200)
        let secondaryScenario = Scenario(name: "Default", statusCode: 201)
        return MockProject(
            name: "Two backends",
            serverConfiguration: ServerConfiguration(
                port: 8080,
                globalDelayMs: 0,
                backends: [BackendConfiguration(id: backendID, name: "Secondary", port: 8081)]
            ),
            endpoints: [
                Endpoint(
                    id: primaryID,
                    name: "Account",
                    method: .get,
                    path: "/account",
                    scenarios: [primaryScenario],
                    activeScenarioID: primaryScenario.id
                ),
                Endpoint(
                    id: secondaryID,
                    name: "Account",
                    method: .get,
                    path: "/account",
                    scenarios: [secondaryScenario],
                    activeScenarioID: secondaryScenario.id,
                    backendID: backendID
                ),
            ]
        )
    }

    @Test("Route, path, and name handles do not silently pick the first matching endpoint")
    func looseReferencesNeedAnID() throws {
        let project = Self.project
        let references: [EndpointRef] = [
            .route(.get, "/ACCOUNT/"),
            EndpointRef(path: "/account"),
            .name(" account "),
        ]

        for ref in references {
            #expect(project.endpointIndex(matching: ref) == nil)
            #expect(project.endpoint(matching: ref) == nil)
            do {
                _ = try project.requireEndpointIndex(ref)
                Issue.record("Expected an ambiguity error for \(ref)")
            } catch let error as ControlError {
                #expect(error.code == "request.invalid")
                #expect(error.message.contains("UUID"))
            }
        }
    }

    @Test("Every endpoint and scenario operation rejects an ambiguous route before changing the project")
    func commandsRejectAmbiguityAtomically() throws {
        let route = EndpointRef.route(.get, "/account")
        let commands: [ControlCommand] = [
            .endpointGet(endpoint: route),
            .endpointUpdate(endpoint: route, spec: EndpointSpec(delayMs: 500)),
            .endpointDelete(endpoint: route),
            .endpointDuplicate(endpoint: route),
            .scenarioList(endpoint: route),
            .scenarioCreate(endpoint: route, name: "Error", spec: ScenarioSpec(statusCode: 500)),
            .scenarioUpdate(endpoint: route, scenario: .name("Default"), spec: ScenarioSpec(statusCode: 500)),
            .scenarioDelete(endpoint: route, scenario: .name("Default")),
            .scenarioActivate(endpoint: route, scenario: .name("Default")),
        ]

        for command in commands {
            var project = Self.project
            let before = project
            do {
                _ = try ProjectCommandExecutor.apply(command, to: &project)
                Issue.record("\(command.kind.rawValue) silently selected one endpoint")
            } catch let error as ControlError {
                #expect(error.code == "request.invalid", "\(command.kind.rawValue) reported \(error.code)")
            }
            #expect(project == before, "\(command.kind.rawValue) changed the project before failing")
        }
    }

    @Test("An id updates and deletes only its selected endpoint when routes overlap")
    func idSelectsExactlyOneEndpoint() throws {
        var project = Self.project
        _ = try ProjectCommandExecutor.apply(
            .endpointUpdate(endpoint: .id(Self.secondaryID), spec: EndpointSpec(delayMs: 500)),
            to: &project
        )
        #expect(project.endpoints.first { $0.id == Self.primaryID }?.delayMs == 0)
        #expect(project.endpoints.first { $0.id == Self.secondaryID }?.delayMs == 500)

        _ = try ProjectCommandExecutor.apply(.endpointDelete(endpoint: .id(Self.primaryID)), to: &project)
        #expect(project.endpoints.map(\.id) == [Self.secondaryID])
        #expect(try project.requireEndpointIndex(.route(.get, "/account")) == 0)
    }
}
