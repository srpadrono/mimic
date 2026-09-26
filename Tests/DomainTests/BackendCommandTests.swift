import Foundation
import Testing
@testable import Domain

@Suite("Backend project commands")
struct BackendCommandTests {
    private static let accountsID = UUID(uuidString: "00000000-0000-0000-0000-000000000101")!
    private static let billingID = UUID(uuidString: "00000000-0000-0000-0000-000000000102")!

    private static var configuredProject: MockProject {
        MockProject(
            name: "Checkout",
            serverConfiguration: ServerConfiguration(
                port: 8080,
                globalDelayMs: 0,
                backends: [
                    BackendConfiguration(id: accountsID, name: "Accounts", port: 8081),
                    BackendConfiguration(id: billingID, name: "Billing", port: 8082),
                ]
            )
        )
    }

    @Test("Creating and updating a backend keeps its listener identity and requested settings")
    func createAndUpdate() throws {
        var project = MockProject(name: "Checkout")
        let created = try #require(ProjectCommandExecutor.apply(
            .backendUpsert(
                id: nil,
                name: " Accounts ",
                port: 8081,
                upstreamURL: "https://accounts.example.com",
                captureResponses: true
            ),
            to: &project
        ))

        #expect(created.didMutate)
        #expect(project.serverConfiguration.backends.count == 1)
        let backend = try #require(project.serverConfiguration.backends.first)
        #expect(backend.id != ServerConfiguration.primaryID)
        #expect(backend.name == "Accounts")
        #expect(backend.port == 8081)
        #expect(backend.upstreamURL == "https://accounts.example.com")
        #expect(backend.passthroughEnabled)
        #expect(backend.captureResponses)

        let updated = try #require(ProjectCommandExecutor.apply(
            .backendUpsert(
                id: backend.id,
                name: " Billing ",
                port: 8083,
                upstreamURL: "https://billing.example.com",
                passthroughEnabled: false,
                captureResponses: false
            ),
            to: &project
        ))

        #expect(updated.didMutate)
        #expect(project.serverConfiguration.backends.count == 1)
        let changed = try #require(project.serverConfiguration.backends.first)
        #expect(changed.id == backend.id)
        #expect(changed.name == "Billing")
        #expect(changed.port == 8083)
        #expect(changed.upstreamURL == "https://billing.example.com")
        #expect(changed.passthroughEnabled == false)
        #expect(changed.captureResponses == false)
    }

    @Test("Deleting an unused backend removes only that listener")
    func deleteUnusedBackend() throws {
        var project = Self.configuredProject
        let deleted = try #require(ProjectCommandExecutor.apply(.backendDelete(id: Self.accountsID), to: &project))

        #expect(deleted.didMutate)
        #expect(project.serverConfiguration.port == 8080)
        #expect(project.serverConfiguration.backends.map(\.id) == [Self.billingID])
        #expect(project.serverConfiguration.backends.map(\.name) == ["Billing"])
    }

    @Test("A listener port cannot be shared with primary or another backend")
    func duplicatePortsAreRejectedWithoutMutation() {
        let commands: [ControlCommand] = [
            .backendUpsert(id: nil, name: "New", port: 8080, upstreamURL: nil),
            .backendUpsert(id: nil, name: "New", port: 8081, upstreamURL: nil),
            .backendUpsert(id: Self.accountsID, name: nil, port: 8080, upstreamURL: nil),
            .backendUpsert(id: Self.accountsID, name: nil, port: 8082, upstreamURL: nil),
        ]

        for command in commands {
            var project = Self.configuredProject
            let original = project
            do {
                _ = try ProjectCommandExecutor.apply(command, to: &project)
                Issue.record("\(command.kind.rawValue) accepted a duplicate listener port")
            } catch let error as ControlError {
                #expect(error.message == "The port is already used by another backend.")
            } catch {
                Issue.record("\(command.kind.rawValue) threw \(error) instead of a ControlError")
            }
            #expect(project == original, "\(command.kind.rawValue) changed the project after rejecting a duplicate port")
        }
    }

    @Test("An endpoint or journey step keeps its backend from being deleted")
    func deleteReferencedBackendIsRejected() {
        var withEndpoint = Self.configuredProject
        withEndpoint.endpoints = [
            Endpoint(name: "Account", path: "/account", backendID: Self.accountsID)
        ]
        let endpointOriginal = withEndpoint
        do {
            _ = try ProjectCommandExecutor.apply(.backendDelete(id: Self.accountsID), to: &withEndpoint)
            Issue.record("Deleted a backend still used by an endpoint")
        } catch let error as ControlError {
            #expect(error.message == "Move or delete the backend's endpoints and journey steps first.")
        } catch {
            Issue.record("Deleting an in-use backend threw \(error) instead of a ControlError")
        }
        #expect(withEndpoint == endpointOriginal)

        var withStep = Self.configuredProject
        withStep.journeys = [
            Journey(name: "Account flow", steps: [
                JourneyStep(
                    name: "Account",
                    path: "/account",
                    outcome: .respond(JourneyResponse(statusCode: 200)),
                    backendID: Self.accountsID
                )
            ])
        ]
        let stepOriginal = withStep
        do {
            _ = try ProjectCommandExecutor.apply(.backendDelete(id: Self.accountsID), to: &withStep)
            Issue.record("Deleted a backend still used by a journey step")
        } catch let error as ControlError {
            #expect(error.message == "Move or delete the backend's endpoints and journey steps first.")
        } catch {
            Issue.record("Deleting an in-use backend threw \(error) instead of a ControlError")
        }
        #expect(withStep == stepOriginal)
    }

    @Test("A DNS root dot cannot bypass the upstream loop guard")
    func fullyQualifiedLocalhostIsRejected() {
        var project = Self.configuredProject
        let original = project
        #expect(throws: ControlError.self) {
            _ = try ProjectCommandExecutor.apply(
                .serverConfigure(port: nil, globalDelayMs: nil, upstreamURL: "http://LOCALHOST.:8080"),
                to: &project
            )
        }
        #expect(project == original)
        #expect(EndpointValidator.isLoopbackHost("[::1]"))
        #expect(!EndpointValidator.isLoopbackHost("localhost.example"))
        #expect(!EndpointValidator.isLoopbackHost("127.0.0.1.example"))
    }

    @Test("Numeric aliases of the bound address cannot point an upstream at its own listener",
          arguments: [
            "127.1", "127.0.1", "2130706433", "0177.0.0.1", "0x7f.0.0.1", "0x7f000001",
            "[::ffff:127.0.0.1]", "[0:0:0:0:0:ffff:7f00:1]",
          ])
    func numericSelfLoopIsRejected(host: String) {
        var project = Self.configuredProject
        let original = project
        #expect(throws: ControlError.self) {
            _ = try ProjectCommandExecutor.apply(
                .serverConfigure(port: nil, globalDelayMs: nil, upstreamURL: "http://\(host):8080"),
                to: &project
            )
        }
        #expect(project == original)
    }

    @Test("Numeric addresses that do not name the bound address are not mistaken for self loops")
    func otherNumericAddressIsAllowed() throws {
        var project = Self.configuredProject
        _ = try ProjectCommandExecutor.apply(
            .serverConfigure(port: nil, globalDelayMs: nil, upstreamURL: "http://127.0.0.2:8080"),
            to: &project
        )
        #expect(project.serverConfiguration.upstreamURL == "http://127.0.0.2:8080")
    }

    @Test("Whole-project validation rolls back a backend edit that makes another upstream loop")
    func lateValidationFailureIsAtomic() {
        var project = MockProject(
            name: "Checkout",
            serverConfiguration: ServerConfiguration(
                port: 8080,
                globalDelayMs: 0,
                upstreamURL: "http://127.0.0.1:8082",
                backends: [BackendConfiguration(id: Self.accountsID, name: "Accounts", port: 8081)]
            )
        )
        let original = project

        // The new port does not collide with a listener. The final document check finds that the
        // primary upstream now points back at it, after the candidate's name and port changed.
        #expect(throws: ControlError.self) {
            _ = try ProjectCommandExecutor.apply(
                .backendUpsert(id: Self.accountsID, name: "Renamed", port: 8082, upstreamURL: nil),
                to: &project
            )
        }
        #expect(project == original)
        #expect(project.serverConfiguration.backends[0].name == "Accounts")
        #expect(project.serverConfiguration.backends[0].port == 8081)
    }
}
