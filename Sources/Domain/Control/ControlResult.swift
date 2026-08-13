import Foundation

/// The envelope every control call answers with.
///
/// One shape for success and failure means a caller — human or agent — can branch on a single
/// boolean and never has to guess whether the payload is an error.
/// ```json
/// { "ok": true,  "result": { "journeyStatus": { ... } } }
/// { "ok": false, "error":  { "code": "journey.notFound", "message": "..." } }
/// ```
public struct ControlResponse: Codable, Sendable, Equatable {
    public var ok: Bool
    public var result: ControlResult?
    public var error: ControlError?

    public init(ok: Bool, result: ControlResult? = nil, error: ControlError? = nil) {
        self.ok = ok
        self.result = result
        self.error = error
    }

    public static func success(_ result: ControlResult) -> ControlResponse {
        ControlResponse(ok: true, result: result)
    }

    public static func failure(_ error: ControlError) -> ControlResponse {
        ControlResponse(ok: false, error: error)
    }
}

/// The payload of a successful call. Exactly the fields a given command produces are present; the
/// rest are omitted from the JSON entirely (Swift's synthesized encoder skips `nil` optionals), so
/// responses stay small and unambiguous.
public struct ControlResult: Codable, Sendable, Equatable {
    /// Short human-readable confirmation, e.g. `"Activated journey \"Retry after failure\""`.
    public var message: String?
    public var state: ControlState?
    public var projects: [ProjectSummary]?
    public var project: MockProject?
    public var endpoints: [Endpoint]?
    public var endpoint: Endpoint?
    public var scenarios: [Scenario]?
    public var scenario: Scenario?
    public var journeys: [Journey]?
    public var journey: Journey?
    public var journeyStatus: JourneyStatus?
    public var journeyTemplates: [JourneyTemplates.Template]?
    public var server: ServerStatusReport?
    public var logs: [RequestLog]?
    public var commands: [CommandDescriptor]?

    public init(
        message: String? = nil,
        state: ControlState? = nil,
        projects: [ProjectSummary]? = nil,
        project: MockProject? = nil,
        endpoints: [Endpoint]? = nil,
        endpoint: Endpoint? = nil,
        scenarios: [Scenario]? = nil,
        scenario: Scenario? = nil,
        journeys: [Journey]? = nil,
        journey: Journey? = nil,
        journeyStatus: JourneyStatus? = nil,
        journeyTemplates: [JourneyTemplates.Template]? = nil,
        server: ServerStatusReport? = nil,
        logs: [RequestLog]? = nil,
        commands: [CommandDescriptor]? = nil
    ) {
        self.message = message
        self.state = state
        self.projects = projects
        self.project = project
        self.endpoints = endpoints
        self.endpoint = endpoint
        self.scenarios = scenarios
        self.scenario = scenario
        self.journeys = journeys
        self.journey = journey
        self.journeyStatus = journeyStatus
        self.journeyTemplates = journeyTemplates
        self.server = server
        self.logs = logs
        self.commands = commands
    }

    public static func message(_ text: String) -> ControlResult {
        ControlResult(message: text)
    }
}

/// A failure with a stable, greppable code. Codes are dotted `subject.reason` strings so scripts can
/// match on them without parsing English.
public struct ControlError: Codable, Sendable, Equatable, Error, LocalizedError {
    public var code: String
    public var message: String
    /// Optional machine-readable context, e.g. `["path": "/login"]`.
    public var details: [String: String]?

    public init(code: String, message: String, details: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.details = details
    }

    public var errorDescription: String? { message }

    // MARK: Common failures

    public static let noProjectOpen = ControlError(
        code: "project.noneOpen",
        message: "No project is open. Create one with `mimic project create <name>` or open an existing one."
    )

    public static func projectNotFound(_ ref: ProjectRef) -> ControlError {
        ControlError(
            code: "project.notFound",
            message: "No project matches \(describe(id: ref.id, name: ref.name)).",
            details: details(id: ref.id, name: ref.name)
        )
    }

    public static func endpointNotFound(_ ref: EndpointRef) -> ControlError {
        var detail = details(id: ref.id, name: ref.name) ?? [:]
        if let method = ref.method { detail["method"] = method.rawValue }
        if let path = ref.path { detail["path"] = path }
        let descriptor: String
        if let method = ref.method, let path = ref.path {
            descriptor = "route \(method.rawValue) \(path)"
        } else {
            descriptor = describe(id: ref.id, name: ref.name)
        }
        return ControlError(
            code: "endpoint.notFound",
            message: "No endpoint matches \(descriptor).",
            details: detail.isEmpty ? nil : detail
        )
    }

    public static func scenarioNotFound(_ ref: ScenarioRef) -> ControlError {
        ControlError(
            code: "scenario.notFound",
            message: "No scenario matches \(describe(id: ref.id, name: ref.name)).",
            details: details(id: ref.id, name: ref.name)
        )
    }

    public static func journeyNotFound(_ ref: JourneyRef) -> ControlError {
        ControlError(
            code: "journey.notFound",
            message: "No journey matches \(describe(id: ref.id, name: ref.name)).",
            details: details(id: ref.id, name: ref.name)
        )
    }

    public static func journeyStepNotFound(_ ref: JourneyStepRef) -> ControlError {
        var detail = details(id: ref.id, name: ref.name) ?? [:]
        if let index = ref.index { detail["index"] = String(index) }
        let descriptor = ref.index.map { "step index \($0)" } ?? describe(id: ref.id, name: ref.name)
        return ControlError(
            code: "journeyStep.notFound",
            message: "No journey step matches \(descriptor).",
            details: detail.isEmpty ? nil : detail
        )
    }

    public static let noActiveJourney = ControlError(
        code: "journey.noneActive",
        message: "No journey is active. Activate one with `mimic journey activate <name>`."
    )

    /// Two lifecycle commands arriving at once.
    ///
    /// Refused rather than queued: two callers asking for a start or a stop together is a script
    /// racing itself, and a reply saying so is more useful than one that waits and then reports on
    /// somebody else's start. `server.busy` maps to `409` in `ControlServer.httpStatus`, alongside
    /// the other "well-formed, but not right now" codes.
    ///
    /// Declared here rather than once per host. It was a `private static let` in each of
    /// `MimicControlService` and `AppControlHost`, with a comment in the second promising it said
    /// "word for word" what the first said — a promise nothing checked, on a code a script branches
    /// on.
    public static let serverBusy = ControlError(
        code: "server.busy",
        message: "The server is already starting or stopping. Try again in a moment."
    )

    /// A project name that is empty, or is nothing but whitespace.
    ///
    /// Shared by ``ProjectCommandExecutor`` (rename) and both hosts (create), which is three places
    /// that each spelled the sentence out.
    public static let emptyProjectName = ControlError.invalid("Project name must not be empty.")

    /// A ``ProjectRef`` carrying neither an id nor a usable name.
    ///
    /// Distinct from ``projectNotFound(_:)`` on purpose: nothing was searched for, so telling the
    /// caller no project matches would be describing a lookup that never happened.
    public static let projectReferenceRequired = ControlError.invalid("Provide a project id or name.")

    /// A store that could not answer — a locked database, an I/O error, a row that will not decode.
    ///
    /// Kept apart from ``projectNotFound(_:)`` deliberately: reporting a database Mimic cannot open
    /// as a missing project is how "my projects vanished" ends up with no diagnosis.
    public static func persistenceFailure(_ error: any Error) -> ControlError {
        ControlError(code: "persistence.failure", message: error.localizedDescription)
    }

    public static func invalid(_ message: String, code: String = "request.invalid") -> ControlError {
        ControlError(code: code, message: message)
    }

    /// The caller did not present this instance's token.
    ///
    /// The message names the file rather than the value: a token echoed into an error would end up in
    /// terminal scrollback, CI logs, and bug reports.
    public static let unauthorized = ControlError(
        code: "request.unauthorized",
        message: """
        Missing or invalid \(ControlAPI.tokenHeaderName).
        The `mimic` CLI reads the token automatically from the running instance's control.json.
        For a raw HTTP caller, read the `token` field from that file and send it as \
        \(ControlAPI.tokenHeaderName), or set \(ControlAPI.tokenEnvironmentKey) on both sides.
        """
    )

    /// The request carried a browser `Origin`, or a `Host` that is not loopback.
    public static let forbiddenOrigin = ControlError(
        code: "request.forbiddenOrigin",
        message: """
        The control API only answers same-machine, non-browser callers. \
        A request carrying an `Origin` header, or a `Host` that is not 127.0.0.1/[::1]/localhost, \
        is refused so that a web page cannot drive this instance.
        """
    )

    public static func validation(_ error: any Error) -> ControlError {
        ControlError(code: "request.invalid", message: error.localizedDescription)
    }

    public static func internalFailure(_ message: String) -> ControlError {
        ControlError(code: "internal.failure", message: message)
    }

    private static func describe(id: UUID?, name: String?) -> String {
        if let id { return "id \(id.uuidString)" }
        if let name { return "name \"\(name)\"" }
        return "the given reference (no id or name provided)"
    }

    private static func details(id: UUID?, name: String?) -> [String: String]? {
        var detail: [String: String] = [:]
        if let id { detail["id"] = id.uuidString }
        if let name { detail["name"] = name }
        return detail.isEmpty ? nil : detail
    }
}

// MARK: - Reporting DTOs

/// The answer to "what is this Mimic instance doing right now?" — one call, everything a caller
/// needs to decide the next step.
public struct ControlState: Codable, Sendable, Equatable {
    /// The control API contract this instance speaks. A caller checks this, not a marketing version,
    /// before assuming a command exists.
    public var apiVersion: String
    /// The host application's version when there is one; `nil` for a headless daemon.
    public var appVersion: String?
    /// `app` when a GUI instance is hosting the control plane, `headless` when it runs windowless.
    public var mode: String
    public var pid: Int
    public var server: ServerStatusReport
    public var project: ProjectSummary?
    public var endpointCount: Int
    public var journeyCount: Int
    public var activeJourney: JourneyStatus?
    public var requestLogCount: Int

    public init(
        apiVersion: String = ControlAPI.version,
        appVersion: String? = nil,
        mode: String,
        pid: Int,
        server: ServerStatusReport,
        project: ProjectSummary?,
        endpointCount: Int,
        journeyCount: Int,
        activeJourney: JourneyStatus?,
        requestLogCount: Int
    ) {
        self.apiVersion = apiVersion
        self.appVersion = appVersion
        self.mode = mode
        self.pid = pid
        self.server = server
        self.project = project
        self.endpointCount = endpointCount
        self.journeyCount = journeyCount
        self.activeJourney = activeJourney
        self.requestLogCount = requestLogCount
    }
}

public struct ServerStatusReport: Codable, Sendable, Equatable {
    /// `stopped` | `starting` | `running` | `stopping` | `error`
    public var state: String
    public var port: Int
    /// Present only while running, so a caller can point a client at it without string-building.
    public var baseURL: String?
    public var globalDelayMs: Int
    public var message: String?

    public init(state: String, port: Int, baseURL: String?, globalDelayMs: Int, message: String? = nil) {
        self.state = state
        self.port = port
        self.baseURL = baseURL
        self.globalDelayMs = globalDelayMs
        self.message = message
    }
}

public struct ProjectSummary: Codable, Sendable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var port: Int
    public var globalDelayMs: Int
    public var endpointCount: Int
    public var journeyCount: Int
    public var activeJourneyID: UUID?
    public var modifiedAt: Date

    public init(
        id: UUID,
        name: String,
        port: Int,
        globalDelayMs: Int,
        endpointCount: Int,
        journeyCount: Int,
        activeJourneyID: UUID?,
        modifiedAt: Date
    ) {
        self.id = id
        self.name = name
        self.port = port
        self.globalDelayMs = globalDelayMs
        self.endpointCount = endpointCount
        self.journeyCount = journeyCount
        self.activeJourneyID = activeJourneyID
        self.modifiedAt = modifiedAt
    }

    public init(_ project: MockProject) {
        self.init(
            id: project.id,
            name: project.name,
            port: project.serverConfiguration.port,
            globalDelayMs: project.serverConfiguration.globalDelayMs,
            endpointCount: project.endpoints.count,
            journeyCount: project.journeys.count,
            activeJourneyID: project.activeJourneyID,
            modifiedAt: project.modifiedAt
        )
    }
}

/// One entry in the runtime command catalog. Exists so an agent can ask a running instance what it
/// can do — the surface stays discoverable even when the docs are out of date.
public struct CommandDescriptor: Codable, Sendable, Equatable {
    /// The JSON key for the command, e.g. `journeyActivate`.
    public var name: String
    public var summary: String
    /// Parameter names in wire order, `?`-suffixed when optional.
    public var parameters: [String]
    /// The equivalent CLI invocation.
    public var cli: String

    public init(name: String, summary: String, parameters: [String], cli: String) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
        self.cli = cli
    }
}

/// Contract identity for the control plane.
public enum ControlAPI {
    /// Bumped only for a breaking change to the command or response shapes. Callers compare against
    /// this rather than guessing from an application version.
    public static let version = "v1"

    /// The released version of Mimic itself, which moves far more often than the API version above.
    ///
    /// Kept in step with `MARKETING_VERSION` in `Project.swift`. The app can read its own bundle, but
    /// a SwiftPM build of the CLI has no bundle to read — and a `--version` that reports the *API*
    /// version tells a user nothing about which build they installed.
    public static let releaseVersion = "0.9.3"

    /// URL path prefix for the HTTP surface, so the CLI and the server cannot disagree about it.
    public static let pathPrefix = "/\(version)"

    /// The control port used when nothing else is specified. Deliberately far from the mock server's
    /// default 8080 so the two never collide.
    public static let defaultPort = 8787

    /// Environment override for the control port.
    public static let portEnvironmentKey = "MIMIC_CONTROL_PORT"

    /// Environment override for the whole base URL, which is how a caller reaches an instance that
    /// did not write a discovery file (a container, a remote forward).
    public static let urlEnvironmentKey = "MIMIC_CONTROL_URL"

    /// Header carrying the per-instance token.
    ///
    /// A custom header is the point, not a detail. It is not on the CORS safelist, so a browser must
    /// preflight any request that sets it — and the preflight fails, because the control plane sends
    /// no `Access-Control-Allow-*` headers. A web page therefore cannot reach this API even if it
    /// guesses the port, and could not read the token anyway: it lives in a `0600` file.
    public static let tokenHeaderName = "X-Mimic-Token"

    /// Environment override for the token, for a caller that cannot read the discovery file
    /// (a container, a forwarded port, a CI job that sets both sides).
    public static let tokenEnvironmentKey = "MIMIC_CONTROL_TOKEN"
}
