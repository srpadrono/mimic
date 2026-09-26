import ArgumentParser
import Domain
import Foundation

struct EndpointCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "endpoint",
        abstract: "Define the routes the mock server answers.",
        discussion: """
        Endpoints can be addressed by route; use --id when several share one:
          mimic endpoint create GET /account-summary --status 200 --body '{"balance":10}'
          mimic endpoint delete GET /account-summary
        """,
        subcommands: [List.self, Get.self, Create.self, Update.self, Delete.self, Duplicate.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the open project's endpoints.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.endpointList))
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one endpoint and its scenarios.")

        @OptionGroup var selector: EndpointSelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.endpointGet(endpoint: try selector.resolve())))
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add an endpoint, with its default response.",
            discussion: """
            The endpoint is created with one active scenario, so it answers immediately. Response
            options here configure that first scenario.
            """
        )

        @Argument(help: "HTTP method, e.g. GET.")
        var method: String

        @Argument(help: "Path, e.g. /account-summary. Use :name for a wildcard segment.")
        var path: String

        @Option(name: .long, help: "Display name. Defaults to \"METHOD /path\".")
        var name: String?

        @Option(name: .long, help: "Per-endpoint delay in milliseconds.")
        var delay: Int?

        @Option(name: .long, help: "Group tag for the sidebar. Pass \"\" to clear.")
        var group: String?

        @Option(name: .long, help: "Answer only this GraphQL operation. GraphQL routes everything through one path, so this is what tells two calls apart.")
        var graphqlOperation: String?

        @Option(name: .long, help: "Backend UUID, or 'primary'.")
        var backend: String?

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let resolvedMethod = try ArgumentParsing.method(method)

            // Response options describe the endpoint's default scenario. Applying them as a second
            // command keeps `endpointCreate` a single-purpose operation while still letting one CLI
            // invocation produce a fully configured, serving endpoint.
            //
            // **Resolved before anything is sent**, which is where it used to sit — after the create.
            // `scenarioSpec()` reads `--body-file` off disk and converts `--content-type`, so
            // `--body-file missing.json` and `--content-type xml` both threw *after* the endpoint
            // existed: the run exited non-zero having left behind an endpoint answering the
            // placeholder 200 `makeEndpoint` gives it — a mock nobody asked for, standing in for the
            // one they did. `Update.run` below resolves its spec before it sends anything; this now
            // matches it.
            let spec = try response.scenarioSpec()

            let created = try await client.send(.endpointCreate(
                name: name,
                method: resolvedMethod,
                path: path,
                spec: EndpointSpec(delayMs: delay, groupTag: group, graphqlOperation: graphqlOperation, backend: backend)
            ))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Create failed."))
            }

            let touchesResponse = spec != ScenarioSpec()
            guard touchesResponse else {
                try Output(options).emit(created)
                return
            }
            guard let endpoint = created.result?.endpoint else {
                throw CLIFailure.commandFailed(.internalFailure("Create returned no endpoint to configure."))
            }

            let updated = try await client.send(.scenarioUpdate(
                endpoint: .id(endpoint.id),
                scenario: .id(endpoint.activeScenarioID ?? endpoint.id),
                spec: spec
            ))
            guard updated.ok else {
                throw await rollBack(endpoint: endpoint, after: updated, using: client)
            }
            try Output(options).emit(try await client.send(.endpointGet(endpoint: .id(endpoint.id))))
        }

        /// Undoes the create when the response half is refused, and reports why it was refused.
        ///
        /// Resolving the spec first cannot cover this: `--status 700` and a header carrying CR or LF
        /// are refused by `applyScenarioSpec` in the executor, on the instance, and only the instance
        /// can say so. Validating them a second time here would put the same rule in two places and
        /// hold this build's `EndpointValidator` against a possibly different build's — so the pair
        /// is made atomic instead, the way `ImportCommitter` makes its own create-then-respond pair
        /// atomic by restoring the project it started from.
        ///
        /// The refusal the caller sees is the instance's, unchanged, so the exit code stays `4` and
        /// matches what `endpoint update --status 700` already reports. Only when the rollback itself
        /// fails does the message grow: the endpoint is still there, and saying nothing about it
        /// would be the silent orphan again under a different name.
        private func rollBack(
            endpoint: Endpoint,
            after refusal: ControlResponse,
            using client: any ControlTransport
        ) async -> CLIFailure {
            let failure = refusal.error ?? .internalFailure("Response update failed.")
            let removed = try? await client.send(.endpointDelete(endpoint: .id(endpoint.id)))
            guard removed?.ok == true else {
                return CLIFailure.commandFailed(ControlError(
                    code: failure.code,
                    message: """
                    \(failure.message)
                    The endpoint \(endpoint.method.rawValue) \(endpoint.path) was created before this \
                    failed and could not be removed again, so it is still answering its placeholder \
                    response. Delete it with `mimic endpoint delete \(endpoint.method.rawValue) \
                    \(endpoint.path)`.
                    """,
                    details: failure.details
                ))
            }
            return CLIFailure.commandFailed(failure)
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change an endpoint's route, delay, group, or active response."
        )

        @OptionGroup var selector: EndpointSelector

        @Option(name: .long, help: "New display name.")
        var newName: String?

        @Option(name: .long, help: "New path.")
        var newPath: String?

        @Option(name: .long, help: "New HTTP method.")
        var newMethod: String?

        @Option(name: .long, help: "Per-endpoint delay in milliseconds.")
        var delay: Int?

        @Option(name: .long, help: "Group tag. Pass \"\" to clear.")
        var group: String?

        @Option(name: .long, help: "Answer only this GraphQL operation. Pass \"\" to clear.")
        var graphqlOperation: String?

        @Option(name: .long, help: "Backend UUID, or 'primary'.")
        var backend: String?

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let ref = try selector.resolve()

            let endpointSpec = EndpointSpec(
                name: newName,
                method: try newMethod.map(ArgumentParsing.method),
                path: newPath,
                delayMs: delay,
                groupTag: group,
                graphqlOperation: graphqlOperation,
                backend: backend
            )
            let responseSpec = try response.scenarioSpec()

            guard endpointSpec != EndpointSpec() || responseSpec != ScenarioSpec() else {
                throw CLIFailure.badArgument(
                    "Nothing to change. Pass --new-path, --delay, --group, --graphql-operation, "
                        + "--status, --body, or --header."
                )
            }

            if responseSpec != ScenarioSpec() {
                // Keep familiar local errors for malformed response options and an endpoint with no
                // active scenario. The host chooses the active scenario when it applies the edit;
                // a concurrent activation must not redirect the edit to an inactive response.
                do {
                    if let status = responseSpec.statusCode {
                        try EndpointValidator.validateStatusCode(status)
                    }
                    if let headers = responseSpec.headers {
                        try EndpointValidator.validateHeaders(headers)
                    }
                } catch {
                    throw CLIFailure.commandFailed(.invalid(error.localizedDescription))
                }
                let fetched = try await client.send(.endpointGet(endpoint: ref))
                guard fetched.ok, let endpoint = fetched.result?.endpoint else {
                    throw CLIFailure.commandFailed(fetched.error ?? .internalFailure("Endpoint not found."))
                }
                guard endpoint.activeScenarioID != nil else {
                    throw CLIFailure.badArgument(
                        "\(endpoint.method.rawValue) \(endpoint.path) has no active scenario to edit. "
                            + "Create one with `mimic scenario create`."
                    )
                }

                let updated = try await client.send(.endpointUpdateWithActiveScenario(
                    endpoint: .id(endpoint.id),
                    spec: endpointSpec,
                    scenarioSpec: responseSpec
                ))
                guard updated.ok else {
                    throw CLIFailure.commandFailed(updated.error ?? .internalFailure("Update failed."))
                }
                guard let changed = updated.result?.endpoint else {
                    throw CLIFailure.commandFailed(.internalFailure("Update returned no endpoint."))
                }
                // The mutation result is the complete endpoint. A second read can fail if another
                // client deletes it after this successful edit, or show a later unrelated change.
                // Emit the same endpoint-only shape that `endpoint get` returned previously.
                try Output(options).emit(.success(.init(endpoint: changed)))
                return
            }

            let updated = try await client.send(.endpointUpdate(endpoint: ref, spec: endpointSpec))
            guard updated.ok else {
                throw CLIFailure.commandFailed(updated.error ?? .internalFailure("Update failed."))
            }
            guard let endpoint = updated.result?.endpoint else {
                throw CLIFailure.commandFailed(.internalFailure("Update returned no endpoint."))
            }
            try Output(options).emit(.success(.init(endpoint: endpoint)))
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove an endpoint and its scenarios.")

        @OptionGroup var selector: EndpointSelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.endpointDelete(endpoint: try selector.resolve())))
        }
    }

    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Copy an endpoint and its scenarios.")

        @OptionGroup var selector: EndpointSelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.endpointDuplicate(endpoint: try selector.resolve())))
        }
    }
}

struct ScenarioCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scenario",
        abstract: "Manage an endpoint's alternative responses.",
        discussion: """
        A scenario is one possible response for an endpoint; exactly one is active at a time.
        Journeys override scenarios while they are running — use a scenario for "this route always
        answers X", and a journey for "this route answers X then Y".
        """,
        subcommands: [List.self, Create.self, Update.self, Delete.self, Activate.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List an endpoint's scenarios.")

        @OptionGroup var selector: EndpointSelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.scenarioList(endpoint: try selector.resolve())))
        }
    }

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add a response variant to an endpoint.")

        @OptionGroup var target: ScenarioTarget

        @Flag(name: .long, help: "Make this the active response immediately.")
        var activate: Bool = false

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let (ref, name) = try target.resolve()

            let created = try await client.send(.scenarioCreate(
                endpoint: ref,
                name: name,
                spec: try response.scenarioSpec()
            ))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Create failed."))
            }
            guard activate else {
                try Output(options).emit(created)
                return
            }
            guard let scenario = created.result?.scenario else {
                throw CLIFailure.commandFailed(.internalFailure("Create returned no scenario to activate."))
            }
            try Output(options).emit(
                try await client.send(.scenarioActivate(endpoint: ref, scenario: .id(scenario.id)))
            )
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a scenario's response.")

        @OptionGroup var target: ScenarioTarget

        @Option(name: .long, help: "Rename the scenario.")
        var newName: String?

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (ref, name) = try target.resolve()
            let spec = try response.scenarioSpec(name: newName)
            guard spec != ScenarioSpec() else {
                throw CLIFailure.badArgument("Nothing to change. Pass --status, --body, --header, or --new-name.")
            }
            try Output(options).emit(await options.client().send(.scenarioUpdate(
                endpoint: ref,
                scenario: .name(name),
                spec: spec
            )))
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a scenario.")

        @OptionGroup var target: ScenarioTarget

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (ref, name) = try target.resolve()
            try Output(options).emit(await options.client().send(.scenarioDelete(
                endpoint: ref,
                scenario: .name(name)
            )))
        }
    }

    struct Activate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a scenario the live response for its endpoint."
        )

        @OptionGroup var target: ScenarioTarget

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let (ref, name) = try target.resolve()
            try Output(options).emit(await options.client().send(.scenarioActivate(
                endpoint: ref,
                scenario: .name(name)
            )))
        }
    }
}

/// The route spelling remains convenient when unique; a UUID selects an endpoint when several
/// backends or GraphQL operations share the same route. Only the handle changes here. The host
/// still owns scenario lookup and mutation rules.
struct ScenarioTarget: ParsableArguments {
    @Argument(help: "METHOD PATH SCENARIO, or SCENARIO with --id.")
    var components: [String] = []

    @Option(name: .long, help: "Endpoint UUID when its route is shared.")
    var id: String?

    func resolve() throws -> (EndpointRef, String) {
        if let id {
            guard components.count == 1 else {
                throw CLIFailure.badArgument("With --id, provide only the scenario name.")
            }
            return (.id(try ArgumentParsing.uuid(id, flag: "--id")), components[0])
        }
        guard components.count == 3 else {
            throw CLIFailure.badArgument("Provide <METHOD> <PATH> <SCENARIO>, or --id <UUID> <SCENARIO>.")
        }
        return (.route(try ArgumentParsing.method(components[0]), components[1]), components[2])
    }
}
