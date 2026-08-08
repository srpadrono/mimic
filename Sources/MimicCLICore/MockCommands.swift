import ArgumentParser
import Domain
import Foundation

struct EndpointCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "endpoint",
        abstract: "Define the routes the mock server answers.",
        discussion: """
        Endpoints are addressed by route, so no command needs a UUID:
          mimic endpoint create GET /account-summary --status 200 --body '{"balance":10}'
          mimic endpoint delete GET /account-summary
        """,
        subcommands: [List.self, Get.self, Create.self, CreateFromLog.self, Update.self, Delete.self, Duplicate.self]
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

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let resolvedMethod = try ArgumentParsing.method(method)

            let created = try await client.send(.endpointCreate(
                name: name,
                method: resolvedMethod,
                path: path,
                spec: EndpointSpec(delayMs: delay, groupTag: group, graphqlOperation: graphqlOperation)
            ))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Create failed."))
            }

            // Response options describe the endpoint's default scenario. Applying them as a second
            // command keeps `endpointCreate` a single-purpose operation while still letting one CLI
            // invocation produce a fully configured, serving endpoint.
            let spec = try response.scenarioSpec()
            let touchesResponse = spec != ScenarioSpec()
            guard touchesResponse, let endpoint = created.result?.endpoint else {
                try Output(options).emit(created)
                return
            }

            let updated = try await client.send(.scenarioUpdate(
                endpoint: .id(endpoint.id),
                scenario: .id(endpoint.activeScenarioID ?? endpoint.id),
                spec: spec
            ))
            guard updated.ok else {
                throw CLIFailure.commandFailed(updated.error ?? .internalFailure("Response update failed."))
            }
            try Output(options).emit(try await client.send(.endpointGet(endpoint: .id(endpoint.id))))
        }
    }

    struct CreateFromLog: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "create-from-log",
            abstract: "Add an endpoint that would have answered a logged request.",
            discussion: """
            The one-step version of "this call had no mock, give it one". Takes an entry id from
            `mimic log list` and creates an endpoint with that request's method and route:

              mimic log list --unmatched --format json | jq -r '.logs[0].id' | xargs mimic endpoint create-from-log

            The query string is stripped, because a query is not part of a route here — an endpoint
            created from `/orders?page=2` has to answer `/orders?page=3` as well.

            Needs a running window: the request log is the app's, not the store's, so a headless
            daemon cannot resolve the id. Create the endpoint directly there instead.
            """
        )

        @Argument(help: "The log entry id, from `mimic log list`.")
        var entryID: String

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            guard let id = UUID(uuidString: entryID) else {
                throw ValidationError("\(entryID) is not a log entry id. Take one from `mimic log list`.")
            }
            try Output(options).emit(await options.client().send(.endpointCreateFromLog(entryID: id)))
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
                graphqlOperation: graphqlOperation
            )
            let responseSpec = try response.scenarioSpec()

            guard endpointSpec != EndpointSpec() || responseSpec != ScenarioSpec() else {
                throw CLIFailure.badArgument(
                    "Nothing to change. Pass --new-path, --delay, --group, --graphql-operation, "
                        + "--status, --body, or --header."
                )
            }

            if endpointSpec != EndpointSpec() {
                let result = try await client.send(.endpointUpdate(endpoint: ref, spec: endpointSpec))
                guard result.ok else {
                    throw CLIFailure.commandFailed(result.error ?? .internalFailure("Update failed."))
                }
            }

            if responseSpec != ScenarioSpec() {
                // Editing "the endpoint's response" means editing whichever scenario is active — the
                // one a request would actually get.
                let fetched = try await client.send(.endpointGet(endpoint: ref))
                guard fetched.ok, let endpoint = fetched.result?.endpoint else {
                    throw CLIFailure.commandFailed(fetched.error ?? .internalFailure("Endpoint not found."))
                }
                guard let activeID = endpoint.activeScenarioID else {
                    throw CLIFailure.badArgument(
                        "\(endpoint.method.rawValue) \(endpoint.path) has no active scenario to edit. "
                            + "Create one with `mimic scenario create`."
                    )
                }
                let result = try await client.send(.scenarioUpdate(
                    endpoint: .id(endpoint.id),
                    scenario: .id(activeID),
                    spec: responseSpec
                ))
                guard result.ok else {
                    throw CLIFailure.commandFailed(result.error ?? .internalFailure("Response update failed."))
                }
            }

            try Output(options).emit(try await client.send(.endpointGet(endpoint: ref)))
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

        @Argument(help: "HTTP method.")
        var method: String

        @Argument(help: "Endpoint path.")
        var path: String

        @Argument(help: "Scenario name, e.g. \"Server error\".")
        var name: String

        @Flag(name: .long, help: "Make this the active response immediately.")
        var activate: Bool = false

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let ref = EndpointRef.route(try ArgumentParsing.method(method), path)

            let created = try await client.send(.scenarioCreate(
                endpoint: ref,
                name: name,
                spec: try response.scenarioSpec()
            ))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Create failed."))
            }
            guard activate, let scenario = created.result?.scenario else {
                try Output(options).emit(created)
                return
            }
            try Output(options).emit(
                try await client.send(.scenarioActivate(endpoint: ref, scenario: .id(scenario.id)))
            )
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change a scenario's response.")

        @Argument(help: "HTTP method.")
        var method: String

        @Argument(help: "Endpoint path.")
        var path: String

        @Argument(help: "Scenario name.")
        var name: String

        @Option(name: .long, help: "Rename the scenario.")
        var newName: String?

        @OptionGroup var response: ResponseOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let spec = try response.scenarioSpec(name: newName)
            guard spec != ScenarioSpec() else {
                throw CLIFailure.badArgument("Nothing to change. Pass --status, --body, --header, or --new-name.")
            }
            try Output(options).emit(await options.client().send(.scenarioUpdate(
                endpoint: .route(try ArgumentParsing.method(method), path),
                scenario: .name(name),
                spec: spec
            )))
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Remove a scenario.")

        @Argument(help: "HTTP method.")
        var method: String

        @Argument(help: "Endpoint path.")
        var path: String

        @Argument(help: "Scenario name.")
        var name: String

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.scenarioDelete(
                endpoint: .route(try ArgumentParsing.method(method), path),
                scenario: .name(name)
            )))
        }
    }

    struct Activate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Make a scenario the live response for its endpoint."
        )

        @Argument(help: "HTTP method.")
        var method: String

        @Argument(help: "Endpoint path.")
        var path: String

        @Argument(help: "Scenario name.")
        var name: String

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.scenarioActivate(
                endpoint: .route(try ArgumentParsing.method(method), path),
                scenario: .name(name)
            )))
        }
    }
}
