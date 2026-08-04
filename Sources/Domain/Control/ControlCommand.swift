import Foundation

/// Every operation Mimic can perform, as data.
///
/// This is the contract the CLI, the HTTP control API, and the app's own menus all speak. Modelling
/// operations as values rather than as method calls buys three things the goal depends on:
/// determinism (a command is replayable and diffable), a single implementation of the rules
/// (``ProjectCommandExecutor`` applies the project-scoped majority purely), and self-description
/// (see ``CommandCatalog``) so an AI agent can discover the surface at runtime.
///
/// **Wire format.** Swift's synthesized `Codable` for enums with associated values gives a stable,
/// readable JSON shape: a single-key object whose key is the case name and whose value is the
/// labelled parameters.
/// ```json
/// { "endpointCreate": { "name": "Login", "method": "POST", "path": "/login" } }
/// { "journeyActivate": { "journey": { "name": "Retry after failure" } } }
/// { "serverStop": {} }
/// ```
/// Every associated value is labelled deliberately — unlabelled values would encode as `_0`.
public enum ControlCommand: Codable, Sendable, Equatable {

    // MARK: Discovery

    /// Liveness + identity. Always succeeds against a reachable instance.
    case ping
    /// The machine-readable command catalog, so a caller can learn the surface without docs.
    case describeCommands

    // MARK: Whole-instance state

    /// Everything a caller needs to decide what to do next: server, project, journey, counts.
    case state
    case reset(scope: ResetScope)

    // MARK: Projects

    case projectList
    case projectCreate(name: String, port: Int?)
    case projectOpen(project: ProjectRef)
    case projectClose
    case projectDelete(project: ProjectRef)
    case projectRename(name: String)
    case projectDuplicate(project: ProjectRef)
    /// Exports the open project (or a named one) as a portable document.
    case projectExport(project: ProjectRef?)
    /// Imports a document as a new project, optionally opening it immediately.
    case projectImport(project: MockProject, activate: Bool)

    // MARK: Server

    case serverStart(port: Int?)
    case serverStop
    case serverStatus
    case serverConfigure(port: Int?, globalDelayMs: Int?)

    // MARK: Endpoints

    case endpointList
    case endpointGet(endpoint: EndpointRef)
    case endpointCreate(name: String?, method: HTTPMethod, path: String, spec: EndpointSpec?)
    case endpointUpdate(endpoint: EndpointRef, spec: EndpointSpec)
    case endpointDelete(endpoint: EndpointRef)
    case endpointDuplicate(endpoint: EndpointRef)

    // MARK: Scenarios

    case scenarioList(endpoint: EndpointRef)
    case scenarioCreate(endpoint: EndpointRef, name: String, spec: ScenarioSpec?)
    case scenarioUpdate(endpoint: EndpointRef, scenario: ScenarioRef, spec: ScenarioSpec)
    case scenarioDelete(endpoint: EndpointRef, scenario: ScenarioRef)
    case scenarioActivate(endpoint: EndpointRef, scenario: ScenarioRef)

    // MARK: Journeys

    case journeyList
    case journeyGet(journey: JourneyRef)
    case journeyCreate(name: String, spec: JourneySpec?)
    /// The built-in journey library — the shipped answers to the common scenarios.
    case journeyTemplateList
    /// Instantiates a built-in template as a new journey, optionally under a different name.
    case journeyAddTemplate(templateID: String, name: String?)
    case journeyUpdate(journey: JourneyRef, spec: JourneySpec)
    case journeyDelete(journey: JourneyRef)
    case journeyDuplicate(journey: JourneyRef)
    case journeyStepAdd(journey: JourneyRef, step: JourneyStepSpec, atIndex: Int?)
    /// Inserts several steps as one mutation.
    ///
    /// Not sugar for looping ``journeyStepAdd``: one user action has to be one mutation and one save.
    /// Two saves in quick succession schedule two autosaves, the second cancelling the first, which
    /// surfaces as a spurious "Save failed" — and capturing a session means N of them at once.
    case journeyStepsAdd(journey: JourneyRef, steps: [JourneyStepSpec], atIndex: Int?)
    case journeyStepUpdate(journey: JourneyRef, step: JourneyStepRef, spec: JourneyStepSpec)
    case journeyStepRemove(journey: JourneyRef, step: JourneyStepRef)
    case journeyStepMove(journey: JourneyRef, step: JourneyStepRef, toIndex: Int)
    /// Selects the journey that overlays endpoint resolution. `nil` clears it.
    case journeyActivate(journey: JourneyRef?)
    /// Rewinds the active journey to step one.
    case journeyRestart
    /// Retires the current step without serving it.
    case journeyAdvance
    case journeyStatus

    // MARK: Request log

    case logList(limit: Int?, unmatchedOnly: Bool?)
    case logClear
}

/// How much live state `reset` clears.
public enum ResetScope: String, Codable, Sendable, CaseIterable {
    /// Request log only.
    case logs
    /// Rewind the active journey; keep the log.
    case journey
    /// Log + journey — the "put this instance back to a known state" default for test setup.
    case all
}

// MARK: - References

/// Identifies a project by id or by name. Names are matched case-insensitively so an agent can work
/// from the names a human used without tracking UUIDs.
public struct ProjectRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String?

    public init(id: UUID? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public static func id(_ id: UUID) -> ProjectRef { ProjectRef(id: id) }
    public static func name(_ name: String) -> ProjectRef { ProjectRef(name: name) }
}

/// Identifies an endpoint by id, by route (`GET /users/:id`), or by name.
/// Route lookup is what makes the CLI usable by hand: `mimic endpoint delete --method GET --path /login`.
public struct EndpointRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String?
    public var method: HTTPMethod?
    public var path: String?

    public init(id: UUID? = nil, name: String? = nil, method: HTTPMethod? = nil, path: String? = nil) {
        self.id = id
        self.name = name
        self.method = method
        self.path = path
    }

    public static func id(_ id: UUID) -> EndpointRef { EndpointRef(id: id) }
    public static func route(_ method: HTTPMethod, _ path: String) -> EndpointRef {
        EndpointRef(method: method, path: path)
    }
    public static func name(_ name: String) -> EndpointRef { EndpointRef(name: name) }
}

public struct ScenarioRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String?

    public init(id: UUID? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public static func id(_ id: UUID) -> ScenarioRef { ScenarioRef(id: id) }
    public static func name(_ name: String) -> ScenarioRef { ScenarioRef(name: name) }
}

public struct JourneyRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var name: String?

    public init(id: UUID? = nil, name: String? = nil) {
        self.id = id
        self.name = name
    }

    public static func id(_ id: UUID) -> JourneyRef { JourneyRef(id: id) }
    public static func name(_ name: String) -> JourneyRef { JourneyRef(name: name) }
}

/// Identifies a step by id, by zero-based position, or by name. Position is the natural handle for
/// a journey a human is reading off a list.
public struct JourneyStepRef: Codable, Sendable, Equatable {
    public var id: UUID?
    public var index: Int?
    public var name: String?

    public init(id: UUID? = nil, index: Int? = nil, name: String? = nil) {
        self.id = id
        self.index = index
        self.name = name
    }

    public static func id(_ id: UUID) -> JourneyStepRef { JourneyStepRef(id: id) }
    public static func index(_ index: Int) -> JourneyStepRef { JourneyStepRef(index: index) }
    public static func name(_ name: String) -> JourneyStepRef { JourneyStepRef(name: name) }
}

// MARK: - Partial specs

/// Fields to set on an endpoint. Absent fields are left untouched, which is what makes one type
/// serve both create and update. An empty `groupTag` clears the group.
public struct EndpointSpec: Codable, Sendable, Equatable {
    public var name: String?
    public var method: HTTPMethod?
    public var path: String?
    public var delayMs: Int?
    public var groupTag: String?
    /// Restricts the endpoint to one GraphQL operation. Empty string clears it.
    public var graphqlOperation: String?

    public init(
        name: String? = nil,
        method: HTTPMethod? = nil,
        path: String? = nil,
        delayMs: Int? = nil,
        groupTag: String? = nil,
        graphqlOperation: String? = nil
    ) {
        self.name = name
        self.method = method
        self.path = path
        self.delayMs = delayMs
        self.groupTag = groupTag
        self.graphqlOperation = graphqlOperation
    }
}

/// Fields to set on a scenario. Absent fields are left untouched.
public struct ScenarioSpec: Codable, Sendable, Equatable {
    public var name: String?
    public var statusCode: Int?
    public var headers: [String: String]?
    public var body: String?
    public var contentType: Scenario.ContentType?

    public init(
        name: String? = nil,
        statusCode: Int? = nil,
        headers: [String: String]? = nil,
        body: String? = nil,
        contentType: Scenario.ContentType? = nil
    ) {
        self.name = name
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.contentType = contentType
    }
}

/// Fields to set on a journey. Providing `steps` replaces the whole sequence — the shape a journey
/// file on disk takes, so `mimic journey import flow.json` is a single command.
public struct JourneySpec: Codable, Sendable, Equatable {
    public var name: String?
    public var summary: String?
    public var matchMode: JourneyMatchMode?
    public var completion: JourneyCompletion?
    public var unmatchedBehavior: JourneyUnmatchedBehavior?
    public var autoAdvance: Bool?
    public var steps: [JourneyStepSpec]?

    public init(
        name: String? = nil,
        summary: String? = nil,
        matchMode: JourneyMatchMode? = nil,
        completion: JourneyCompletion? = nil,
        unmatchedBehavior: JourneyUnmatchedBehavior? = nil,
        autoAdvance: Bool? = nil,
        steps: [JourneyStepSpec]? = nil
    ) {
        self.name = name
        self.summary = summary
        self.matchMode = matchMode
        self.completion = completion
        self.unmatchedBehavior = unmatchedBehavior
        self.autoAdvance = autoAdvance
        self.steps = steps
    }
}

/// A step in the flat shape callers actually author: the response fields inline, and a `failure`
/// that — when present — turns the step into a transport failure instead of a reply.
///
/// Flattening ``JourneyStepOutcome`` here keeps hand-written journey JSON obvious:
/// ```json
/// { "name": "Summary fails", "method": "GET", "path": "/account-summary", "statusCode": 500 }
/// { "name": "Offline",       "method": "GET", "path": "/inbox", "failure": { "connectionDrop": {} } }
/// ```
public struct JourneyStepSpec: Codable, Sendable, Equatable {
    public var name: String?
    public var method: HTTPMethod?
    public var path: String?
    public var statusCode: Int?
    public var headers: [String: String]?
    public var body: String?
    public var contentType: Scenario.ContentType?
    public var failure: NetworkFailure?
    public var delayMs: Int?
    public var repeatCount: Int?
    /// Restricts the step to one GraphQL operation, so a flow can script several otherwise-identical
    /// calls to the same path.
    public var graphqlOperation: String?

    public init(
        name: String? = nil,
        method: HTTPMethod? = nil,
        path: String? = nil,
        statusCode: Int? = nil,
        headers: [String: String]? = nil,
        body: String? = nil,
        contentType: Scenario.ContentType? = nil,
        failure: NetworkFailure? = nil,
        delayMs: Int? = nil,
        repeatCount: Int? = nil,
        graphqlOperation: String? = nil
    ) {
        self.name = name
        self.method = method
        self.path = path
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
        self.contentType = contentType
        self.failure = failure
        self.delayMs = delayMs
        self.repeatCount = repeatCount
        self.graphqlOperation = graphqlOperation
    }
}

extension JourneyStepSpec {
    /// Builds a step that reproduces a request the server already answered.
    ///
    /// Turning an observed call into a scripted one is the natural way to grow a journey: you are
    /// debugging, you see the exact exchange you want to replay, and retyping its status, headers and
    /// body by hand is both tedious and a chance to get it wrong.
    ///
    /// Two details are deliberate. The query string is dropped, because it belongs to the call rather
    /// than the route a step matches. And for a request nothing answered — `unmatched`, or one an
    /// active journey blocked — the *status* is copied but the body is not: that body is Mimic's own
    /// diagnostic text, and baking "No mock endpoint matched." into a journey would be nonsense.
    public static func capturing(_ log: RequestLog, name: String? = nil) -> JourneyStepSpec {
        let path = log.path.firstIndex(of: "?").map { String(log.path[log.path.startIndex..<$0]) } ?? log.path
        let route = path.hasPrefix("/") ? path : "/\(path)"

        let carriesRealResponse = log.outcome == .endpoint || log.outcome == .journey
        let contentType: Scenario.ContentType? = log.responseHeaders
            .first { $0.key.caseInsensitiveCompare("Content-Type") == .orderedSame }
            .map { $0.value.lowercased().contains("json") ? .json : .plainText }

        return JourneyStepSpec(
            name: name ?? "\(log.method.rawValue) \(route)",
            method: log.method,
            path: route,
            statusCode: log.responseStatusCode,
            // `Content-Type` is carried by `contentType`; repeating it as a header would emit it twice.
            headers: carriesRealResponse ? replayableHeaders(log.responseHeaders) : nil,
            body: carriesRealResponse ? log.responseBody : nil,
            contentType: carriesRealResponse ? contentType : nil,
            // A GraphQL call is only distinguishable by its operation, so a step captured from one
            // must carry it or it would match every other call to the same path.
            graphqlOperation: GraphQLRequest.operation(inBody: log.requestBody)?.name
        )
    }

    /// Headers worth scripting: everything except the content type, which the step models separately.
    private static func replayableHeaders(_ headers: [String: String]) -> [String: String]? {
        let filtered = headers.filter { $0.key.caseInsensitiveCompare("Content-Type") != .orderedSame }
        return filtered.isEmpty ? nil : filtered
    }

    /// Builds the ordered steps that reproduce a run of observed requests — a session, rather than the
    /// single exchange ``capturing(_:name:)`` handles.
    ///
    /// Three rules, each of which is a defect if left out:
    ///
    /// - **Order is chronological. Never the order the rows were picked, nor the order they were
    ///   drawn.** The request log sorts by any column in either direction, so a selection's on-screen
    ///   order is whatever header the user last clicked, and the order they clicked *rows* in is
    ///   arbitrary. ``JourneyMatchMode/orderedPerEndpoint`` resolves against step order, so a journey
    ///   captured in display order would replay the flow backwards for anyone sorted newest-first —
    ///   which is the default.
    /// - **Requests an active journey already answered are dropped.** They are steps in a journey by
    ///   definition, so capturing one only duplicates it. The single-request menu hides itself for the
    ///   same reason; here the selection is likely to be mixed, so they are filtered rather than
    ///   refused.
    /// - **A consecutive run of identical exchanges collapses into one step** carrying
    ///   ``JourneyStep/repeatCount``. Six polls of `/status` are one step repeated six times, which is
    ///   exactly what that field models. Only *consecutive*, and only when the response matches too:
    ///   a poll returning `202, 202, 202, 200` is two steps, and collapsing it into one would erase
    ///   the transition the journey exists to reproduce.
    public static func capturing(_ logs: [RequestLog]) -> [JourneyStepSpec] {
        // `enumerated()` before sorting because `sorted(by:)` guarantees no stability: two requests
        // logged in the same instant would otherwise land in either order from one run to the next,
        // and a captured journey has to be reproducible.
        let ordered = logs.enumerated()
            .filter { $0.element.outcome != .journey }
            .sorted { lhs, rhs in
                lhs.element.timestamp == rhs.element.timestamp
                    ? lhs.offset < rhs.offset
                    : lhs.element.timestamp < rhs.element.timestamp
            }

        return ordered.reduce(into: []) { steps, entry in
            let step = capturing(entry.element)
            guard let previous = steps.last, previous.isAnotherOccurrence(of: step) else {
                steps.append(step)
                return
            }
            steps[steps.index(before: steps.endIndex)].repeatCount = (previous.repeatCount ?? 1) + 1
        }
    }

    /// Whether `other` is a repeat of this exchange, and so belongs in this step's
    /// ``JourneyStep/repeatCount`` rather than in a step of its own.
    ///
    /// Compared on every field except the count itself, so a differing status, body or header keeps
    /// the two apart. The name is derived from the method and path, so identical exchanges always
    /// agree on it.
    private func isAnotherOccurrence(of other: JourneyStepSpec) -> Bool {
        var lhs = self
        var rhs = other
        lhs.repeatCount = nil
        rhs.repeatCount = nil
        return lhs == rhs
    }
}
