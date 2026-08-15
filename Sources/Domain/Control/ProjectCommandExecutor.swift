import Foundation

/// The result of applying a project-scoped command.
public struct ProjectCommandOutcome: Sendable, Equatable {
    public let result: ControlResult
    /// `false` for pure reads, so a host knows whether to persist and push to the engine.
    public let didMutate: Bool

    public init(result: ControlResult, didMutate: Bool) {
        self.result = result
        self.didMutate = didMutate
    }
}

/// Applies every command that is a function of the open project — endpoints, scenarios, journeys,
/// project metadata — as a pure transformation.
///
/// This is where the CLI and the GUI stop being two implementations of the same rules. A host is
/// left with only the genuinely stateful commands (server lifecycle, opening/deleting projects, the
/// live journey cursor, the request log); everything else lands here, is `inout MockProject -> Result`,
/// and is unit-testable without a database, a server, or a window.
public enum ProjectCommandExecutor {

    /// Applies `command` if it is project-scoped.
    ///
    /// - Returns: the outcome, or `nil` when the command belongs to the host (server lifecycle,
    ///   project selection, journey runtime, logs). `nil` is the signal to keep looking, not a failure.
    /// - Throws: ``ControlError`` when the command is project-scoped but cannot be satisfied.
    public static func apply(
        _ command: ControlCommand,
        to project: inout MockProject
    ) throws -> ProjectCommandOutcome? {
        // Host-scoped commands — server lifecycle, project selection, journey runtime, logs,
        // discovery — reach state a pure `inout MockProject` transformation cannot see, so they are
        // the host's to answer. `nil` is the signal to keep looking, not a failure.
        //
        // This check used to be twenty-one cases named one by one at the bottom of the switch below,
        // with the complementary twenty-six named at the bottom of `MimicControlService.run` and
        // again at the bottom of `AppControlHost.perform`: one fact — which side of the line a
        // command falls on — written out three times and kept in agreement by hand. It is written
        // once now, as `CommandKind.scope`, whose own switch has no `default`, so a command added
        // later still cannot compile until somebody has decided which side it belongs on. That
        // decision is the only thing the three lists were really buying.
        guard command.kind.scope == .project else { return nil }

        switch command {

        // MARK: Project metadata

        case let .projectRename(name):
            guard let trimmed = name.nilIfEmpty else {
                throw ControlError.emptyProjectName
            }
            project.name = trimmed
            return mutated(.init(message: "Renamed project to \"\(trimmed)\".", project: project))

        case let .serverConfigure(port, globalDelayMs):
            if let port {
                try validate { try EndpointValidator.validatePort(port) }
                project.serverConfiguration.port = port
            }
            if let globalDelayMs {
                guard globalDelayMs >= 0 else {
                    throw ControlError.invalid("Global delay must be zero or greater.")
                }
                project.serverConfiguration.globalDelayMs = globalDelayMs
            }
            guard port != nil || globalDelayMs != nil else {
                throw ControlError.invalid("Provide at least one of port or globalDelayMs.")
            }
            return mutated(.init(message: "Updated server configuration.", project: project))

        // MARK: Endpoints

        case .endpointList:
            return read(.init(endpoints: project.endpoints))

        case let .endpointGet(ref):
            let endpoint = try project.requireEndpoint(ref)
            return read(.init(endpoint: endpoint))

        case let .endpointCreate(name, method, path, spec):
            let endpoint = try makeEndpoint(name: name, method: method, path: path, spec: spec)
            project.endpoints.append(endpoint)
            return mutated(.init(
                message: "Created endpoint \(endpoint.method.rawValue) \(endpoint.path).",
                endpoint: endpoint
            ))

        case let .endpointUpdate(ref, spec):
            let index = try project.requireEndpointIndex(ref)
            try applyEndpointSpec(spec, to: &project.endpoints[index])
            return mutated(.init(message: "Updated endpoint.", endpoint: project.endpoints[index]))

        case let .endpointDelete(ref):
            let index = try project.requireEndpointIndex(ref)
            let removed = project.endpoints.remove(at: index)
            return mutated(.init(message: "Deleted endpoint \(removed.method.rawValue) \(removed.path)."))

        case let .endpointDuplicate(ref):
            let source = try project.requireEndpoint(ref)
            let copy = duplicate(source)
            project.endpoints.append(copy)
            return mutated(.init(message: "Duplicated endpoint as \"\(copy.name)\".", endpoint: copy))

        // MARK: Scenarios

        case let .scenarioList(ref):
            let endpoint = try project.requireEndpoint(ref)
            return read(.init(scenarios: endpoint.scenarios))

        case let .scenarioCreate(endpointRef, name, spec):
            let index = try project.requireEndpointIndex(endpointRef)
            var scenario = Scenario(name: name)
            try applyScenarioSpec(spec ?? ScenarioSpec(), to: &scenario)
            project.endpoints[index].scenarios.append(scenario)
            // First scenario becomes active — an endpoint with responses but no active one would
            // silently 404, which is never what the caller meant.
            if project.endpoints[index].activeScenarioID == nil {
                project.endpoints[index].activeScenarioID = scenario.id
            }
            return mutated(.init(message: "Created scenario \"\(scenario.name)\".", scenario: scenario))

        case let .scenarioUpdate(endpointRef, scenarioRef, spec):
            let endpointIndex = try project.requireEndpointIndex(endpointRef)
            let scenarioIndex = try project.requireScenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            )
            try applyScenarioSpec(spec, to: &project.endpoints[endpointIndex].scenarios[scenarioIndex])
            return mutated(.init(
                message: "Updated scenario.",
                scenario: project.endpoints[endpointIndex].scenarios[scenarioIndex]
            ))

        case let .scenarioDelete(endpointRef, scenarioRef):
            let endpointIndex = try project.requireEndpointIndex(endpointRef)
            let scenarioIndex = try project.requireScenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            )
            let removed = project.endpoints[endpointIndex].scenarios.remove(at: scenarioIndex)
            if project.endpoints[endpointIndex].activeScenarioID == removed.id {
                project.endpoints[endpointIndex].activeScenarioID =
                    project.endpoints[endpointIndex].scenarios.first?.id
            }
            return mutated(.init(message: "Deleted scenario \"\(removed.name)\"."))

        case let .scenarioActivate(endpointRef, scenarioRef):
            let endpointIndex = try project.requireEndpointIndex(endpointRef)
            let scenarioIndex = try project.requireScenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            )
            let scenario = project.endpoints[endpointIndex].scenarios[scenarioIndex]
            project.endpoints[endpointIndex].activeScenarioID = scenario.id
            return mutated(.init(message: "Activated scenario \"\(scenario.name)\".", scenario: scenario))

        // MARK: Journeys

        case .journeyList:
            return read(.init(journeys: project.journeys))

        case let .journeyGet(ref):
            let journey = try project.requireJourney(ref)
            return read(.init(journey: journey))

        case let .journeyCreate(name, spec):
            guard let trimmed = name.nilIfEmpty else {
                throw ControlError.invalid("Journey name must not be empty.")
            }
            var journey = Journey(name: trimmed)
            // `applyJourneySpec` already prefers the spec's name over the one the journey was built
            // with, so there is nothing left to reconcile afterwards.
            try applyJourneySpec(spec ?? JourneySpec(), to: &journey)
            project.journeys.append(journey)
            return mutated(.init(message: "Created journey \"\(journey.name)\".", journey: journey))

        case .journeyTemplateList:
            return read(.init(journeyTemplates: JourneyTemplates.all))

        case let .journeyAddTemplate(templateID, name):
            guard let template = JourneyTemplates.template(id: templateID) else {
                throw ControlError(
                    code: .journeyTemplateNotFound,
                    message: "No journey template with id \"\(templateID)\". "
                        + "Available: \(JourneyTemplates.all.map(\.id).joined(separator: ", "))."
                )
            }
            var journey = Journey(name: name?.nilIfEmpty ?? template.title)
            try applyJourneySpec(template.spec, to: &journey)
            // Applied after the spec, because the template's own `name` must not override a name the
            // caller asked for explicitly.
            journey.name = name?.nilIfEmpty ?? template.title
            project.journeys.append(journey)
            return mutated(.init(
                message: "Added journey \"\(journey.name)\" from template \"\(template.id)\".",
                journey: journey
            ))

        case let .journeyUpdate(ref, spec):
            let index = try project.requireJourneyIndex(ref)
            try applyJourneySpec(spec, to: &project.journeys[index])
            return mutated(.init(message: "Updated journey.", journey: project.journeys[index]))

        case let .journeyDelete(ref):
            let index = try project.requireJourneyIndex(ref)
            let removed = project.journeys.remove(at: index)
            if project.activeJourneyID == removed.id {
                project.activeJourneyID = nil
            }
            return mutated(.init(message: "Deleted journey \"\(removed.name)\"."))

        case let .journeyDuplicate(ref):
            let source = try project.requireJourney(ref)
            let copy = duplicate(source)
            project.journeys.append(copy)
            return mutated(.init(message: "Duplicated journey as \"\(copy.name)\".", journey: copy))

        case let .journeyStepAdd(ref, spec, atIndex):
            let journeyIndex = try project.requireJourneyIndex(ref)
            let step = try makeStep(from: spec, position: project.journeys[journeyIndex].steps.count)
            let insertAt = min(max(0, atIndex ?? project.journeys[journeyIndex].steps.count),
                               project.journeys[journeyIndex].steps.count)
            project.journeys[journeyIndex].steps.insert(step, at: insertAt)
            return mutated(.init(
                message: "Added step \"\(step.name)\" at index \(insertAt).",
                journey: project.journeys[journeyIndex]
            ))

        case let .journeyStepsAdd(ref, specs, atIndex):
            let journeyIndex = try project.requireJourneyIndex(ref)
            // Every step is built before any is inserted, so a bad one in the middle leaves the
            // journey untouched rather than half-appended. `project` is `inout`; a throw partway
            // through a loop of inserts would commit the steps that came first.
            let existingCount = project.journeys[journeyIndex].steps.count
            let steps = try specs.enumerated().map { offset, spec in
                try makeStep(from: spec, position: existingCount + offset)
            }
            let insertAt = min(max(0, atIndex ?? existingCount), existingCount)
            project.journeys[journeyIndex].steps.insert(contentsOf: steps, at: insertAt)
            return mutated(.init(
                message: steps.count == 1
                    ? "Added step \"\(steps[0].name)\" at index \(insertAt)."
                    : "Added \(steps.count) steps at index \(insertAt).",
                journey: project.journeys[journeyIndex]
            ))

        case let .journeyStepUpdate(ref, stepRef, spec):
            let journeyIndex = try project.requireJourneyIndex(ref)
            let stepIndex = try project.journeys[journeyIndex].requireStepIndex(stepRef)
            try applyStepSpec(spec, to: &project.journeys[journeyIndex].steps[stepIndex])
            return mutated(.init(message: "Updated step.", journey: project.journeys[journeyIndex]))

        case let .journeyStepRemove(ref, stepRef):
            let journeyIndex = try project.requireJourneyIndex(ref)
            let stepIndex = try project.journeys[journeyIndex].requireStepIndex(stepRef)
            let removed = project.journeys[journeyIndex].steps.remove(at: stepIndex)
            return mutated(.init(
                message: "Removed step \"\(removed.name)\".",
                journey: project.journeys[journeyIndex]
            ))

        case let .journeyStepMove(ref, stepRef, toIndex):
            let journeyIndex = try project.requireJourneyIndex(ref)
            let stepIndex = try project.journeys[journeyIndex].requireStepIndex(stepRef)
            let step = project.journeys[journeyIndex].steps.remove(at: stepIndex)
            let destination = min(max(0, toIndex), project.journeys[journeyIndex].steps.count)
            project.journeys[journeyIndex].steps.insert(step, at: destination)
            return mutated(.init(
                message: "Moved step \"\(step.name)\" to index \(destination).",
                journey: project.journeys[journeyIndex]
            ))

        // MARK: Declared project-scoped, not applied above
        //
        // Unreachable while `CommandKind.scope` and this switch agree, and the compiler cannot
        // check that they do: the guard narrows by `CommandKind` while the switch is over
        // `ControlCommand`. It throws rather than returning `nil` because `nil` sends the command on
        // to the host, which would answer "no project is open" — with a project open, which is
        // exactly the misdirection the old hand-written lists existed to prevent. Saying what is
        // actually wrong is worth more than a plausible lie.
        //
        // `ControlCommandTests` runs one sample of every kind through here and fails when a
        // project-scoped command is declined, so this arm costs a red suite rather than a broken
        // script.
        default:
            throw ControlError.internalFailure(
                "\(command.kind.rawValue) is project-scoped but ProjectCommandExecutor does not apply it."
            )
        }
    }

    // MARK: - Spec application

    static func makeEndpoint(
        name: String?,
        method: HTTPMethod,
        path: String,
        spec: EndpointSpec?
    ) throws -> Endpoint {
        let resolvedPath = spec?.path ?? path
        try validate { try EndpointValidator.validatePath(resolvedPath) }

        let scenario = Scenario(name: "Default", statusCode: 200, body: nil)
        var endpoint = Endpoint(
            name: (name ?? spec?.name)?.nilIfEmpty ?? defaultName(method: method, path: resolvedPath),
            method: spec?.method ?? method,
            path: resolvedPath,
            scenarios: [scenario],
            activeScenarioID: scenario.id
        )
        if let delayMs = spec?.delayMs {
            guard delayMs >= 0 else { throw ControlError.invalid("Endpoint delay must be zero or greater.") }
            endpoint.delayMs = delayMs
        }
        if let groupTag = spec?.groupTag {
            endpoint.groupTag = groupTag.nilIfEmpty
        }
        if let operation = spec?.graphqlOperation {
            endpoint.graphqlOperation = operation.nilIfEmpty
        }
        return endpoint
    }

    static func applyEndpointSpec(_ spec: EndpointSpec, to endpoint: inout Endpoint) throws {
        if let path = spec.path {
            try validate { try EndpointValidator.validatePath(path) }
            endpoint.path = path
        }
        if let name = spec.name?.nilIfEmpty { endpoint.name = name }
        if let method = spec.method { endpoint.method = method }
        if let delayMs = spec.delayMs {
            guard delayMs >= 0 else { throw ControlError.invalid("Endpoint delay must be zero or greater.") }
            endpoint.delayMs = delayMs
        }
        // An empty string is the documented way to clear the group from a shell, where passing a
        // JSON null is awkward. Same for the GraphQL operation.
        if let groupTag = spec.groupTag { endpoint.groupTag = groupTag.nilIfEmpty }
        if let operation = spec.graphqlOperation { endpoint.graphqlOperation = operation.nilIfEmpty }
    }

    static func applyScenarioSpec(_ spec: ScenarioSpec, to scenario: inout Scenario) throws {
        if let name = spec.name?.nilIfEmpty { scenario.name = name }
        if let statusCode = spec.statusCode {
            try validate { try EndpointValidator.validateStatusCode(statusCode) }
            scenario.statusCode = statusCode
        }
        if let headers = spec.headers {
            // A CR or LF in a value does not stay inside the header — it ends it, and what follows is
            // read by the client as further headers. Rejected here so the caller learns which header
            // is wrong, rather than having it silently dropped when the response is written.
            try validate { try EndpointValidator.validateHeaders(headers) }
            scenario.headers = headers
        }
        if let body = spec.body { scenario.body = body }
        if let contentType = spec.contentType { scenario.bodyContentType = contentType }
    }

    static func applyJourneySpec(_ spec: JourneySpec, to journey: inout Journey) throws {
        if let name = spec.name?.nilIfEmpty { journey.name = name }
        if let summary = spec.summary { journey.summary = summary.nilIfEmpty }
        if let matchMode = spec.matchMode { journey.matchMode = matchMode }
        if let completion = spec.completion { journey.completion = completion }
        if let unmatched = spec.unmatchedBehavior { journey.unmatchedBehavior = unmatched }
        if let autoAdvance = spec.autoAdvance { journey.autoAdvance = autoAdvance }
        if let steps = spec.steps {
            journey.steps = try steps.enumerated().map { try makeStep(from: $1, position: $0) }
        }
    }

    /// Builds a step from the flat spec, deciding response-vs-failure from whether `failure` is set.
    static func makeStep(from spec: JourneyStepSpec, position: Int) throws -> JourneyStep {
        guard let path = spec.path?.nilIfEmpty else {
            throw ControlError.invalid("Journey step requires a path.")
        }
        try validate { try EndpointValidator.validatePath(path) }

        let method = spec.method ?? .get
        let outcome: JourneyStepOutcome
        if let failure = spec.failure {
            if case let .timeout(holdMs) = failure, holdMs < 0 {
                throw ControlError.invalid("Timeout hold must be zero or greater.")
            }
            outcome = .networkFailure(failure)
        } else {
            let statusCode = spec.statusCode ?? 200
            try validate { try EndpointValidator.validateStatusCode(statusCode) }
            try validate { try EndpointValidator.validateHeaders(spec.headers ?? [:]) }
            outcome = .respond(JourneyResponse(
                statusCode: statusCode,
                headers: spec.headers ?? [:],
                body: spec.body,
                contentType: spec.contentType ?? .json
            ))
        }

        if let delayMs = spec.delayMs, delayMs < 0 {
            throw ControlError.invalid("Journey step delay must be zero or greater.")
        }
        if let repeatCount = spec.repeatCount, repeatCount < 1 {
            throw ControlError.invalid("Journey step repeatCount must be at least 1.")
        }

        return JourneyStep(
            name: spec.name?.nilIfEmpty ?? defaultStepName(spec: spec, position: position, method: method, path: path),
            method: method,
            path: path,
            outcome: outcome,
            delayMs: spec.delayMs ?? 0,
            repeatCount: spec.repeatCount ?? 1,
            graphqlOperation: spec.graphqlOperation?.nilIfEmpty
        )
    }

    /// Names a step after its operation when it has one — "POST /graphql" four times over tells the
    /// reader nothing about which call is which.
    static func defaultStepName(
        spec: JourneyStepSpec,
        position: Int,
        method: HTTPMethod,
        path: String
    ) -> String {
        if let operation = spec.graphqlOperation?.nilIfEmpty {
            return "Step \(position + 1): \(operation)"
        }
        return "Step \(position + 1): \(method.rawValue) \(path)"
    }

    /// Applies a partial spec to an existing step. Response fields are merged into the existing
    /// response so `--status 500` alone does not wipe a carefully written body; providing `failure`
    /// converts the step to a failure, and providing any response field converts it back.
    static func applyStepSpec(_ spec: JourneyStepSpec, to step: inout JourneyStep) throws {
        if let name = spec.name?.nilIfEmpty { step.name = name }
        if let method = spec.method { step.method = method }
        if let path = spec.path?.nilIfEmpty {
            try validate { try EndpointValidator.validatePath(path) }
            step.path = path
        }
        if let delayMs = spec.delayMs {
            guard delayMs >= 0 else { throw ControlError.invalid("Journey step delay must be zero or greater.") }
            step.delayMs = delayMs
        }
        if let repeatCount = spec.repeatCount {
            guard repeatCount >= 1 else {
                throw ControlError.invalid("Journey step repeatCount must be at least 1.")
            }
            step.repeatCount = repeatCount
        }
        if let operation = spec.graphqlOperation { step.graphqlOperation = operation.nilIfEmpty }

        if let failure = spec.failure {
            if case let .timeout(holdMs) = failure, holdMs < 0 {
                throw ControlError.invalid("Timeout hold must be zero or greater.")
            }
            step.outcome = .networkFailure(failure)
            return
        }

        let touchesResponse = spec.statusCode != nil
            || spec.headers != nil
            || spec.body != nil
            || spec.contentType != nil
        guard touchesResponse else { return }

        var response: JourneyResponse
        if case let .respond(existing) = step.outcome {
            response = existing
        } else {
            response = JourneyResponse()
        }
        if let statusCode = spec.statusCode {
            try validate { try EndpointValidator.validateStatusCode(statusCode) }
            response.statusCode = statusCode
        }
        if let headers = spec.headers {
            try validate { try EndpointValidator.validateHeaders(headers) }
            response.headers = headers
        }
        if let body = spec.body { response.body = body }
        if let contentType = spec.contentType { response.contentType = contentType }
        step.outcome = .respond(response)
    }

    // MARK: - Duplication

    /// A copy of `source` named "… (Copy)", reminted by ``Endpoint/copyingWithFreshIdentifiers()``.
    ///
    /// The reminting is not repeated here, and that is the whole point. This arm used to build its own
    /// copy, and it and the shared helper disagreed about one field: it pointed the copy at
    /// `scenarios.first`, while the helper follows whichever scenario the source has *active*. So
    /// `mimic endpoint duplicate` and `mimic project duplicate` produced different copies of the same
    /// endpoint whenever its active scenario was not its first — duplicating an endpoint serving
    /// "Server error" handed back one serving "Default".
    ///
    /// Following the source is the correct half: a duplicate should answer the way the original
    /// answers. The rename is the only thing left that is specific to duplicating *within* a project,
    /// where the copy lands in the same list as its original and two identical names tell the reader
    /// nothing about which is which.
    static func duplicate(_ source: Endpoint) -> Endpoint {
        var copy = source.copyingWithFreshIdentifiers()
        copy.name = "\(source.name) (Copy)"
        return copy
    }

    /// A copy of `source` named "… (Copy)", reminted by ``Journey/copyingWithFreshIdentifiers()``.
    /// Same division of labour as the endpoint arm above: the helper owns identity, this owns the name.
    static func duplicate(_ source: Journey) -> Journey {
        var copy = source.copyingWithFreshIdentifiers()
        copy.name = "\(source.name) (Copy)"
        return copy
    }

    // MARK: - Helpers

    static func defaultName(method: HTTPMethod, path: String) -> String {
        "\(method.rawValue) \(path)"
    }

    private static func mutated(_ result: ControlResult) -> ProjectCommandOutcome {
        ProjectCommandOutcome(result: result, didMutate: true)
    }

    private static func read(_ result: ControlResult) -> ProjectCommandOutcome {
        ProjectCommandOutcome(result: result, didMutate: false)
    }

    /// Re-labels domain validation failures as control errors so callers see one error vocabulary.
    private static func validate(_ body: () throws -> Void) throws {
        do {
            try body()
        } catch {
            throw ControlError.validation(error)
        }
    }
}

extension String {
    /// The trimmed string, or `nil` when nothing survives the trim — which lets a caller clear an
    /// optional field from a shell without constructing JSON null.
    ///
    /// It returns the *trimmed* value, not the original. Trimming only to decide emptiness and then
    /// handing back the untrimmed string is how `mimic endpoint create --name " Login "` stored a
    /// name with the spaces still on it while `journey create` — which trimmed a second time by hand
    /// — did not, and how `--path " /login "` reached `validatePath` with the spaces attached. Every
    /// caller here wants the trimmed form; a body is never passed through this property.
    /// `public` because it is not only the executor's any more: both hosts call it to trim a project
    /// name before deciding whether it is empty, where each used to spell the trim out itself. Two
    /// copies of "what counts as empty" is exactly the kind of rule that drifts a space at a time.
    public var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
