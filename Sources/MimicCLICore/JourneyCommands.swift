import ArgumentParser
import Domain
import Foundation

struct JourneyCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "journey",
        abstract: "Script ordered sequences of responses to reproduce whole flows.",
        discussion: """
        A journey answers "what does this route return *the second time*?". While one is active it
        overlays the endpoints, so the same route can fail then succeed:

          mimic journey add-template retry-after-failure --activate
          mimic server start
          mimic journey status          # where the run stands
          mimic journey restart         # rewind between test cases

        Requests the journey does not script fall through to the endpoints, so a journey only has to
        describe the steps that matter.
        """,
        subcommands: [
            List.self, Get.self, Create.self, Update.self, Delete.self, Duplicate.self,
            Templates.self, AddTemplate.self,
            Activate.self, Deactivate.self, Restart.self, Advance.self, Status.self,
            Export.self, Import.self,
            StepCommand.self,
        ]
    )

    // MARK: Inspecting

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the project's journeys.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyList))
        }
    }

    struct Get: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show a journey and every step.")

        @OptionGroup var selector: JourneySelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyGet(journey: try selector.resolve())))
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report where the active journey's run currently stands.",
            discussion: """
            Shows which step is next, how many times each step has answered, and whether the run is
            complete — the assertion surface for a test that drives a flow.
            """
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyStatus))
        }
    }

    // MARK: Authoring

    struct Create: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create a journey, optionally with all its steps from a file."
        )

        @Argument(help: "Journey name.")
        var name: String

        @Option(name: .long, help: "Description of the scenario this journey reproduces.")
        var summary: String?

        @Option(name: .long, help: "Read steps and options from a journey JSON file (or - for stdin).")
        var file: String?

        @OptionGroup var behavior: JourneyBehaviorOptions
        @Flag(name: .long, help: "Activate the journey once created.")
        var activate: Bool = false

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            var spec = try file.map(JourneyFile.readSpec) ?? JourneySpec()
            if let summary { spec.summary = summary }
            try behavior.apply(to: &spec)
            // The name argument is authoritative; a file's own name must not silently win.
            spec.name = nil

            let client = try options.client()
            let created = try await client.send(.journeyCreate(name: name, spec: spec))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Create failed."))
            }
            guard activate else {
                try Output(options).emit(created)
                return
            }
            try Output(options).emit(try await client.send(.journeyActivate(journey: .name(name))))
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Change a journey's options, or replace its steps from a file."
        )

        @OptionGroup var selector: JourneySelector

        @Option(name: .long, help: "Rename the journey.")
        var newName: String?

        @Option(name: .long, help: "Replace the description.")
        var summary: String?

        @Option(name: .long, help: "Replace every step from a journey JSON file (or - for stdin).")
        var file: String?

        @OptionGroup var behavior: JourneyBehaviorOptions
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            var spec = try file.map(JourneyFile.readSpec) ?? JourneySpec()
            if let newName { spec.name = newName }
            if let summary { spec.summary = summary }
            try behavior.apply(to: &spec)

            guard spec != JourneySpec() else {
                throw CLIFailure.badArgument(
                    "Nothing to change. Pass --new-name, --summary, --file, --match-mode, --completion, "
                        + "--unmatched, or --auto-advance/--no-auto-advance."
                )
            }
            try Output(options).emit(
                await options.client().send(.journeyUpdate(journey: try selector.resolve(), spec: spec))
            )
        }
    }

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Delete a journey.")

        @OptionGroup var selector: JourneySelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyDelete(journey: try selector.resolve())))
        }
    }

    struct Duplicate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Copy a journey, e.g. to vary one step without losing the original."
        )

        @OptionGroup var selector: JourneySelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyDuplicate(journey: try selector.resolve())))
        }
    }

    // MARK: Templates

    struct Templates: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List the built-in journey templates."
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyTemplateList))
        }
    }

    struct AddTemplate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add-template",
            abstract: "Create a journey from a built-in template.",
            discussion: """
            The fastest path to a working flow. `mimic journey templates` lists the ids; each template
            is also a worked example of the step vocabulary to copy when writing your own.
            """
        )

        @Argument(help: "Template id, e.g. retry-after-failure.")
        var template: String

        @Option(name: .long, help: "Name for the new journey. Defaults to the template's title.")
        var name: String?

        @Flag(name: .long, help: "Activate the journey once created.")
        var activate: Bool = false

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let client = try options.client()
            let created = try await client.send(.journeyAddTemplate(templateID: template, name: name))
            guard created.ok else {
                throw CLIFailure.commandFailed(created.error ?? .internalFailure("Add failed."))
            }
            guard activate, let journey = created.result?.journey else {
                try Output(options).emit(created)
                return
            }
            try Output(options).emit(try await client.send(.journeyActivate(journey: .id(journey.id))))
        }
    }

    // MARK: Runtime

    struct Activate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Select the journey that overlays the endpoints.",
            discussion: """
            Activating always starts a fresh run, so switching journeys between test cases needs no
            separate reset. Pass no name to clear the selection.
            """
        )

        @OptionGroup var selector: JourneySelector
        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(
                await options.client().send(.journeyActivate(journey: try selector.resolveOptional()))
            )
        }
    }

    struct Deactivate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Clear the active journey; endpoints answer directly again."
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyActivate(journey: nil)))
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Rewind the active journey to step one."
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyRestart))
        }
    }

    struct Advance: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Retire the current step without serving it.",
            discussion: """
            The manual control for a journey with autoAdvance off — how a held state such as
            maintenance mode is lifted on cue.
            """
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.journeyAdvance))
        }
    }

    // MARK: Files

    struct Export: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Write a journey out as a reusable JSON file."
        )

        @OptionGroup var selector: JourneySelector

        @Option(name: [.customShort("o"), .long], help: "Write to this file instead of stdout.")
        var output: String?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            let response = try await options.client().send(.journeyGet(journey: try selector.resolve()))
            guard response.ok, let journey = response.result?.journey else {
                throw CLIFailure.commandFailed(response.error ?? .internalFailure("No journey returned."))
            }

            // Exported as a spec, not as a journey: a spec has no ids, so the file is portable between
            // projects and readable in a diff.
            let json = try ControlCoding.string(JourneyFile.spec(from: journey), pretty: true)
            guard let output else {
                print(json)
                return
            }
            do {
                try json.write(toFile: output, atomically: true, encoding: .utf8)
            } catch {
                throw CLIFailure.fileUnreadable(path: output, underlying: error.localizedDescription)
            }
            Output(options).emitMessage("Exported journey \"\(journey.name)\" to \(output).")
        }
    }

    struct Import: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Create or replace a journey from a JSON file."
        )

        @Argument(help: "Path to a journey JSON file, or - for stdin.")
        var file: String

        @Option(name: .long, help: "Name for the journey. Defaults to the file's own name.")
        var name: String?

        @Flag(name: .long, help: "Replace an existing journey with the same name instead of failing.")
        var replace: Bool = false

        @Flag(name: .long, help: "Activate the journey once imported.")
        var activate: Bool = false

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            var spec = try JourneyFile.readSpec(file)
            let resolvedName = name ?? spec.name
            guard let resolvedName, !resolvedName.isEmpty else {
                throw CLIFailure.badArgument("\(file) has no \"name\"; pass --name.")
            }
            spec.name = nil

            let client = try options.client()
            let existing = try await client.send(.journeyGet(journey: .name(resolvedName)))

            let response: ControlResponse
            if existing.ok {
                guard replace else {
                    throw CLIFailure.badArgument(
                        "A journey named \"\(resolvedName)\" already exists. Pass --replace to overwrite it."
                    )
                }
                response = try await client.send(.journeyUpdate(journey: .name(resolvedName), spec: spec))
            } else {
                response = try await client.send(.journeyCreate(name: resolvedName, spec: spec))
            }
            guard response.ok else {
                throw CLIFailure.commandFailed(response.error ?? .internalFailure("Import failed."))
            }

            guard activate else {
                try Output(options).emit(response)
                return
            }
            try Output(options).emit(try await client.send(.journeyActivate(journey: .name(resolvedName))))
        }
    }

    // MARK: Steps

    struct StepCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "step",
            abstract: "Add, change, reorder, or remove one step of a journey.",
            subcommands: [Add.self, AddBatch.self, Update.self, Remove.self, Move.self]
        )

        struct AddBatch: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                commandName: "add-batch",
                abstract: "Append or insert several steps as one change.",
                discussion: """
                Takes the same journey JSON `mimic journey export` writes and appends its steps to an
                existing journey, rather than replacing them the way `journey update --file` does.
                One change, so a run that captures a whole session saves once.

                  mimic journey step add-batch "Retry flow" captured.json
                  mimic journey export "Checkout" | mimic journey step add-batch "Retry flow" - --at 0
                """
            )

            @Argument(help: "Journey name.")
            var journey: String

            @Argument(help: "Path to a journey JSON file, or - for stdin.")
            var file: String

            @Option(name: .long, help: "Insert at this zero-based position instead of appending.")
            var at: Int?

            @OptionGroup var options: GlobalOptions

            func run() async throws {
                let steps = try JourneyFile.readSpec(file).steps ?? []
                guard !steps.isEmpty else {
                    throw CLIFailure.badArgument("\(file) has no steps to add.")
                }
                try Output(options).emit(await options.client().send(
                    .journeyStepsAdd(journey: .name(journey), steps: steps, atIndex: at)
                ))
            }
        }

        struct Add: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Append or insert a step.",
                discussion: """
                  mimic journey step add "Retry flow" GET /account-summary --status 500
                  mimic journey step add "Retry flow" GET /inbox --fail timeout --hold-ms 5000
                """
            )

            @Argument(help: "Journey name.")
            var journey: String

            @Argument(help: "HTTP method.")
            var method: String

            @Argument(help: "Path. Use :name for a wildcard segment.")
            var path: String

            @Option(name: .long, help: "Step name. Defaults to its position and route.")
            var name: String?

            @Option(name: .long, help: "Insert at this zero-based position instead of appending.")
            var at: Int?

            @Option(name: .long, help: "Delay before this step answers, in milliseconds.")
            var delay: Int?

            @Option(name: .long, help: "Serve this step this many times before advancing.")
            var repeatCount: Int?

            @Option(name: .long, help: "Match only this GraphQL operation, so a flow can script several calls to the same path.")
            var graphqlOperation: String?

            @OptionGroup var response: ResponseOptions
            @OptionGroup var failure: FailureOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                var spec = try StepBuilder.spec(
                    name: name,
                    method: method,
                    path: path,
                    response: response,
                    failure: failure,
                    delay: delay,
                    repeatCount: repeatCount
                )
                spec.graphqlOperation = graphqlOperation
                try Output(options).emit(await options.client().send(
                    .journeyStepAdd(journey: .name(journey), step: spec, atIndex: at)
                ))
            }
        }

        struct Update: AsyncParsableCommand {
            static let configuration = CommandConfiguration(
                abstract: "Change one step.",
                discussion: """
                Only the fields you pass change: `--status 503` alone keeps the existing body. Passing
                `--fail` converts the step to a transport failure; passing a response field converts it
                back.
                """
            )

            @Argument(help: "Journey name.")
            var journey: String

            @OptionGroup var selector: StepSelector

            @Option(name: .long, help: "Rename the step.")
            var newName: String?

            @Option(name: .long, help: "New HTTP method.")
            var newMethod: String?

            @Option(name: .long, help: "New path.")
            var newPath: String?

            @Option(name: .long, help: "Delay before this step answers, in milliseconds.")
            var delay: Int?

            @Option(name: .long, help: "Serve this step this many times before advancing.")
            var repeatCount: Int?

            @Option(name: .long, help: "Match only this GraphQL operation. Pass \"\" to clear.")
            var graphqlOperation: String?

            @OptionGroup var response: ResponseOptions
            @OptionGroup var failure: FailureOption
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                let spec = JourneyStepSpec(
                    name: newName,
                    method: try newMethod.map(ArgumentParsing.method),
                    path: newPath,
                    statusCode: response.status,
                    headers: try response.resolveHeaders(),
                    body: try response.resolveBody(),
                    contentType: try response.resolveContentType(),
                    failure: try failure.resolve(),
                    delayMs: delay,
                    repeatCount: repeatCount,
                    graphqlOperation: graphqlOperation
                )
                guard spec != JourneyStepSpec() else {
                    throw CLIFailure.badArgument(
                        "Nothing to change. Pass --status, --body, --header, --fail, --delay, "
                            + "--repeat-count, --new-path, --new-method, or --new-name."
                    )
                }
                try Output(options).emit(await options.client().send(
                    .journeyStepUpdate(journey: .name(journey), step: try selector.resolve(), spec: spec)
                ))
            }
        }

        struct Remove: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Remove one step.")

            @Argument(help: "Journey name.")
            var journey: String

            @OptionGroup var selector: StepSelector
            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try Output(options).emit(await options.client().send(
                    .journeyStepRemove(journey: .name(journey), step: try selector.resolve())
                ))
            }
        }

        struct Move: AsyncParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Move a step to another position.")

            @Argument(help: "Journey name.")
            var journey: String

            @OptionGroup var selector: StepSelector

            @Option(name: .long, help: "Destination zero-based position.")
            var to: Int

            @OptionGroup var options: GlobalOptions

            func run() async throws {
                try Output(options).emit(await options.client().send(
                    .journeyStepMove(journey: .name(journey), step: try selector.resolve(), toIndex: to)
                ))
            }
        }
    }
}

/// Journey-level options shared by `create` and `update`.
struct JourneyBehaviorOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "How requests pair with steps: orderedPerEndpoint (default) or strictSequence.")
    var matchMode: String?

    @Option(name: .long, help: "What happens after the last step: stop (default) or restart.")
    var completion: String?

    @Option(name: .long, help: "Requests the journey does not script: fallThroughToEndpoints (default) or notFound.")
    var unmatched: String?

    @Flag(
        inversion: .prefixedNo,
        help: "Advance automatically as steps are served. Use --no-auto-advance to hold a step until `journey advance`."
    )
    var autoAdvance: Bool = true

    /// Only writes fields the caller actually passed. `autoAdvance` has no natural "absent" value as a
    /// flag, so it is only applied when one of the two spellings appears in the arguments.
    ///
    /// Throws rather than swallowing: these were `try?`, so `--match-mode sequential` — a plausible
    /// misremembering of `strict-sequence` — parsed to `nil`, wrote `nil` over the field, and exited
    /// 0 reporting success. The journey kept whatever mode it already had and the caller was told the
    /// change had been applied. A typo in an enum-valued option is bad usage, and bad usage exits 2.
    func apply(to spec: inout JourneySpec) throws {
        if let matchMode { spec.matchMode = try ArgumentParsing.matchMode(matchMode) }
        if let completion { spec.completion = try ArgumentParsing.completion(completion) }
        if let unmatched { spec.unmatchedBehavior = try ArgumentParsing.unmatchedBehavior(unmatched) }
        if Self.autoAdvanceWasSpecified() { spec.autoAdvance = autoAdvance }
    }

    static func autoAdvanceWasSpecified(
        arguments: [String] = CommandLine.arguments
    ) -> Bool {
        arguments.contains("--auto-advance") || arguments.contains("--no-auto-advance")
    }
}

/// Reading and writing journey files.
enum JourneyFile {
    /// Keys that appear in a serialized ``Journey`` and in no ``JourneySpec``. Both are read from the
    /// JSON before anything is decoded, because the shape has to be *decided* rather than guessed at
    /// by trying decoders in an order — see ``readSpec(_:)``.
    ///
    /// They are string literals because the coding keys they name are `private` on `Journey` and
    /// `JourneyStep`. Two keys rather than one so that neither is load-bearing alone: renaming either
    /// property still leaves a serialized `Journey` classified correctly by the other.
    /// `readsAFullJourney` in `MimicCLICoreTests` round-trips a real `Journey` through this function
    /// and asserts its statuses, headers and bodies survive, so it fails if the classification stops
    /// working at all.
    private static let journeyStepOutcomeKey = "outcome"
    private static let journeyIdentityKey = "id"

    /// Accepts either a bare ``JourneySpec`` — what a caller writes by hand, and what `mimic journey
    /// export` produces — or a serialized ``Journey``.
    ///
    /// The second is not what `mimic journey get` *prints*: that prints a `ControlResult`, so the
    /// journey is the value under its `journey` key. A `Journey` reaches a file by being lifted out
    /// of one (`mimic journey get "X" | jq .journey > flow.json`) or out of the `journeys` array of a
    /// `mimic project export` document, and both are ordinary things to have done.
    ///
    /// **The shape is decided by a key only a `Journey` has, never by which type decodes first.**
    /// This used to try `JourneySpec` and accept it on `spec.steps != nil`, and that can never
    /// distinguish the two: every property of `JourneySpec`/`JourneyStepSpec` is Optional with a
    /// synthesized decoder, and a `Journey` *does* carry a `steps` array, so it decoded as a spec
    /// whose `statusCode`, `headers`, `body`, `contentType` and `failure` were all nil — those live
    /// under each step's `outcome`, which the spec has no property for. The `Journey` branch was
    /// unreachable for exactly the documents it existed to handle, so importing one flattened every
    /// step to a bare 200 with an empty body — `ProjectCommandExecutor.makeStep` reads a nil
    /// `statusCode` as `?? 200` and a nil `failure` as "respond" — and every `connectionDrop` and
    /// `timeout` became a 200. Exit 0.
    ///
    /// So: a step object carrying `outcome`, or a top-level `id`, means the file is a `Journey`, and
    /// it is then decoded as one with `try` — a half-converted document fails loudly naming the key
    /// it lacks instead of quietly losing its responses. Everything else is a `JourneySpec`, also
    /// decoded with `try`, so a malformed field is reported rather than falling through to "this is
    /// not a journey file".
    ///
    /// A `steps` array is still required first. Every field of `JourneySpec` is optional — that is
    /// what makes partial updates work — so *any* JSON object decodes as an empty spec, and without
    /// that check an unrelated file would be accepted and quietly produce a journey with no steps.
    static func readSpec(_ path: String) throws -> JourneySpec {
        let data = try FileInput.read(path)

        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let steps = object["steps"] as? [Any]
        else { throw notAJourneyFile(path) }

        let carriesOutcome = steps.contains { step in
            guard let step = step as? [String: Any] else { return false }
            return step.keys.contains(journeyStepOutcomeKey)
        }
        let looksLikeAJourney = carriesOutcome || object.keys.contains(journeyIdentityKey)

        guard looksLikeAJourney else {
            do {
                return try ControlCoding.decode(JourneySpec.self, from: data)
            } catch {
                throw CLIFailure.badArgument("\(path) is not a valid journey file: \(error)")
            }
        }

        do {
            return spec(from: try ControlCoding.decode(Journey.self, from: data))
        } catch {
            let tell = carriesOutcome ? "a step with an \"outcome\"" : "a top-level \"id\""
            throw CLIFailure.badArgument(
                """
                \(path) looks like a whole journey — it has \(tell) — but it could not be read as \
                one: \(error)
                A file with neither is read as a journey spec, whose steps carry "statusCode", \
                "headers", "body" and "failure" directly instead of an "outcome".
                """
            )
        }
    }

    private static func notAJourneyFile(_ path: String) -> CLIFailure {
        CLIFailure.badArgument(
            """
            \(path) is not a journey file: expected a JSON object with a "steps" array, e.g.
              { "name": "Retry after failure", "steps": [
                  { "method": "POST", "path": "/login", "statusCode": 200 },
                  { "method": "GET", "path": "/account-summary", "statusCode": 500 }
              ]}
            Run `mimic journey templates` for ready-made examples.
            """
        )
    }

    static func spec(from journey: Journey) -> JourneySpec {
        JourneySpec(
            name: journey.name,
            summary: journey.summary,
            matchMode: journey.matchMode,
            completion: journey.completion,
            unmatchedBehavior: journey.unmatchedBehavior,
            autoAdvance: journey.autoAdvance,
            steps: journey.steps.map { step in
                switch step.outcome {
                case let .respond(response):
                    JourneyStepSpec(
                        name: step.name,
                        method: step.method,
                        path: step.path,
                        statusCode: response.statusCode,
                        headers: response.headers.isEmpty ? nil : response.headers,
                        body: response.body,
                        contentType: response.contentType,
                        delayMs: step.delayMs == 0 ? nil : step.delayMs,
                        repeatCount: step.repeatCount == 1 ? nil : step.repeatCount,
                        graphqlOperation: step.graphqlOperation
                    )
                case let .networkFailure(failure):
                    JourneyStepSpec(
                        name: step.name,
                        method: step.method,
                        path: step.path,
                        failure: failure,
                        delayMs: step.delayMs == 0 ? nil : step.delayMs,
                        repeatCount: step.repeatCount == 1 ? nil : step.repeatCount,
                        graphqlOperation: step.graphqlOperation
                    )
                }
            }
        )
    }
}

enum StepBuilder {
    static func spec(
        name: String?,
        method: String,
        path: String,
        response: ResponseOptions,
        failure: FailureOption,
        delay: Int?,
        repeatCount: Int?
    ) throws -> JourneyStepSpec {
        let resolvedFailure = try failure.resolve()
        if resolvedFailure != nil, response.status != nil || response.body != nil || response.bodyFile != nil {
            throw CLIFailure.badArgument(
                "A step either responds or fails: --fail cannot be combined with --status or --body."
            )
        }
        return JourneyStepSpec(
            name: name,
            method: try ArgumentParsing.method(method),
            path: path,
            statusCode: response.status,
            headers: try response.resolveHeaders(),
            body: try response.resolveBody(),
            contentType: try response.resolveContentType(),
            failure: resolvedFailure,
            delayMs: delay,
            repeatCount: repeatCount
        )
    }
}
