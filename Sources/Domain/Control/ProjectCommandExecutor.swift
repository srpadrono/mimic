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
        switch command {

        // MARK: Project metadata

        case let .projectRename(name):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ControlError.invalid("Project name must not be empty.")
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
            guard let endpoint = project.endpoint(matching: ref) else {
                throw ControlError.endpointNotFound(ref)
            }
            return read(.init(endpoint: endpoint))

        case let .endpointCreate(name, method, path, spec):
            let endpoint = try makeEndpoint(name: name, method: method, path: path, spec: spec)
            project.endpoints.append(endpoint)
            return mutated(.init(
                message: "Created endpoint \(endpoint.method.rawValue) \(endpoint.path).",
                endpoint: endpoint
            ))

        case let .endpointUpdate(ref, spec):
            guard let index = project.endpointIndex(matching: ref) else {
                throw ControlError.endpointNotFound(ref)
            }
            try applyEndpointSpec(spec, to: &project.endpoints[index])
            return mutated(.init(message: "Updated endpoint.", endpoint: project.endpoints[index]))

        case let .endpointDelete(ref):
            guard let index = project.endpointIndex(matching: ref) else {
                throw ControlError.endpointNotFound(ref)
            }
            let removed = project.endpoints.remove(at: index)
            return mutated(.init(message: "Deleted endpoint \(removed.method.rawValue) \(removed.path)."))

        case let .endpointDuplicate(ref):
            guard let source = project.endpoint(matching: ref) else {
                throw ControlError.endpointNotFound(ref)
            }
            let copy = duplicate(source)
            project.endpoints.append(copy)
            return mutated(.init(message: "Duplicated endpoint as \"\(copy.name)\".", endpoint: copy))

        // MARK: Scenarios

        case let .scenarioList(ref):
            guard let endpoint = project.endpoint(matching: ref) else {
                throw ControlError.endpointNotFound(ref)
            }
            return read(.init(scenarios: endpoint.scenarios))

        case let .scenarioCreate(endpointRef, name, spec):
            guard let index = project.endpointIndex(matching: endpointRef) else {
                throw ControlError.endpointNotFound(endpointRef)
            }
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
            guard let endpointIndex = project.endpointIndex(matching: endpointRef) else {
                throw ControlError.endpointNotFound(endpointRef)
            }
            guard let scenarioIndex = project.scenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            ) else {
                throw ControlError.scenarioNotFound(scenarioRef)
            }
            try applyScenarioSpec(spec, to: &project.endpoints[endpointIndex].scenarios[scenarioIndex])
            return mutated(.init(
                message: "Updated scenario.",
                scenario: project.endpoints[endpointIndex].scenarios[scenarioIndex]
            ))

        case let .scenarioDelete(endpointRef, scenarioRef):
            guard let endpointIndex = project.endpointIndex(matching: endpointRef) else {
                throw ControlError.endpointNotFound(endpointRef)
            }
            guard let scenarioIndex = project.scenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            ) else {
                throw ControlError.scenarioNotFound(scenarioRef)
            }
            let removed = project.endpoints[endpointIndex].scenarios.remove(at: scenarioIndex)
            if project.endpoints[endpointIndex].activeScenarioID == removed.id {
                project.endpoints[endpointIndex].activeScenarioID =
                    project.endpoints[endpointIndex].scenarios.first?.id
            }
            return mutated(.init(message: "Deleted scenario \"\(removed.name)\"."))

        case let .scenarioActivate(endpointRef, scenarioRef):
            guard let endpointIndex = project.endpointIndex(matching: endpointRef) else {
                throw ControlError.endpointNotFound(endpointRef)
            }
            guard let scenarioIndex = project.scenarioIndex(
                in: project.endpoints[endpointIndex],
                matching: scenarioRef
            ) else {
                throw ControlError.scenarioNotFound(scenarioRef)
            }
            let scenario = project.endpoints[endpointIndex].scenarios[scenarioIndex]
            project.endpoints[endpointIndex].activeScenarioID = scenario.id
            return mutated(.init(message: "Activated scenario \"\(scenario.name)\".", scenario: scenario))

        // MARK: Journeys

        case .journeyList:
            return read(.init(journeys: project.journeys))

        case let .journeyGet(ref):
            guard let journey = project.journey(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            return read(.init(journey: journey))

        case let .journeyCreate(name, spec):
            let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ControlError.invalid("Journey name must not be empty.")
            }
            var journey = Journey(name: trimmed)
            try applyJourneySpec(spec ?? JourneySpec(), to: &journey)
            journey.name = spec?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? trimmed
            project.journeys.append(journey)
            return mutated(.init(message: "Created journey \"\(journey.name)\".", journey: journey))

        case .journeyTemplateList:
            return read(.init(journeyTemplates: JourneyTemplates.all))

        case let .journeyAddTemplate(templateID, name):
            guard let template = JourneyTemplates.template(id: templateID) else {
                throw ControlError(
                    code: "journeyTemplate.notFound",
                    message: "No journey template with id \"\(templateID)\". "
                        + "Available: \(JourneyTemplates.all.map(\.id).joined(separator: ", "))."
                )
            }
            var journey = Journey(name: name?.nilIfEmpty ?? template.title)
            try applyJourneySpec(template.spec, to: &journey)
            // The template's own `name` (if any) must not override an explicitly requested one.
            journey.name = name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? template.title
            project.journeys.append(journey)
            return mutated(.init(
                message: "Added journey \"\(journey.name)\" from template \"\(template.id)\".",
                journey: journey
            ))

        case let .journeyUpdate(ref, spec):
            guard let index = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            try applyJourneySpec(spec, to: &project.journeys[index])
            return mutated(.init(message: "Updated journey.", journey: project.journeys[index]))

        case let .journeyDelete(ref):
            guard let index = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            let removed = project.journeys.remove(at: index)
            if project.activeJourneyID == removed.id {
                project.activeJourneyID = nil
            }
            return mutated(.init(message: "Deleted journey \"\(removed.name)\"."))

        case let .journeyDuplicate(ref):
            guard let source = project.journey(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            let copy = duplicate(source)
            project.journeys.append(copy)
            return mutated(.init(message: "Duplicated journey as \"\(copy.name)\".", journey: copy))

        case let .journeyStepAdd(ref, spec, atIndex):
            guard let journeyIndex = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            let step = try makeStep(from: spec, position: project.journeys[journeyIndex].steps.count)
            let insertAt = min(max(0, atIndex ?? project.journeys[journeyIndex].steps.count),
                               project.journeys[journeyIndex].steps.count)
            project.journeys[journeyIndex].steps.insert(step, at: insertAt)
            return mutated(.init(
                message: "Added step \"\(step.name)\" at index \(insertAt).",
                journey: project.journeys[journeyIndex]
            ))

        case let .journeyStepsAdd(ref, specs, atIndex):
            guard let journeyIndex = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
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
            guard let journeyIndex = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            guard let stepIndex = project.journeys[journeyIndex].stepIndex(matching: stepRef) else {
                throw ControlError.journeyStepNotFound(stepRef)
            }
            try applyStepSpec(spec, to: &project.journeys[journeyIndex].steps[stepIndex])
            return mutated(.init(message: "Updated step.", journey: project.journeys[journeyIndex]))

        case let .journeyStepRemove(ref, stepRef):
            guard let journeyIndex = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            guard let stepIndex = project.journeys[journeyIndex].stepIndex(matching: stepRef) else {
                throw ControlError.journeyStepNotFound(stepRef)
            }
            let removed = project.journeys[journeyIndex].steps.remove(at: stepIndex)
            return mutated(.init(
                message: "Removed step \"\(removed.name)\".",
                journey: project.journeys[journeyIndex]
            ))

        case let .journeyStepMove(ref, stepRef, toIndex):
            guard let journeyIndex = project.journeyIndex(matching: ref) else {
                throw ControlError.journeyNotFound(ref)
            }
            guard let stepIndex = project.journeys[journeyIndex].stepIndex(matching: stepRef) else {
                throw ControlError.journeyStepNotFound(stepRef)
            }
            let step = project.journeys[journeyIndex].steps.remove(at: stepIndex)
            let destination = min(max(0, toIndex), project.journeys[journeyIndex].steps.count)
            project.journeys[journeyIndex].steps.insert(step, at: destination)
            return mutated(.init(
                message: "Moved step \"\(step.name)\" to index \(destination).",
                journey: project.journeys[journeyIndex]
            ))

        default:
            // Host-scoped: server lifecycle, project selection, journey runtime, logs, discovery.
            return nil
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
        if let name = spec.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            journey.name = name
        }
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

    static func duplicate(_ source: Endpoint) -> Endpoint {
        // Fresh scenario ids, so editing the copy never mutates the original's responses.
        let scenarios = source.scenarios.map {
            Scenario(
                name: $0.name,
                statusCode: $0.statusCode,
                headers: $0.headers,
                body: $0.body,
                bodyContentType: $0.bodyContentType
            )
        }
        return Endpoint(
            name: "\(source.name) (Copy)",
            method: source.method,
            path: source.path,
            scenarios: scenarios,
            activeScenarioID: scenarios.first?.id,
            delayMs: source.delayMs,
            groupTag: source.groupTag,
            graphqlOperation: source.graphqlOperation
        )
    }

    static func duplicate(_ source: Journey) -> Journey {
        Journey(
            name: "\(source.name) (Copy)",
            summary: source.summary,
            steps: source.steps.map {
                JourneyStep(
                    name: $0.name,
                    method: $0.method,
                    path: $0.path,
                    outcome: $0.outcome,
                    delayMs: $0.delayMs,
                    repeatCount: $0.repeatCount,
                    graphqlOperation: $0.graphqlOperation
                )
            },
            matchMode: source.matchMode,
            completion: source.completion,
            unmatchedBehavior: source.unmatchedBehavior,
            autoAdvance: source.autoAdvance
        )
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
    /// `nil` for an empty (or whitespace-only) string — lets a caller clear an optional field from a
    /// shell without constructing JSON null.
    var nilIfEmpty: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
