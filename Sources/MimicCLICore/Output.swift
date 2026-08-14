import ArgumentParser
import Domain
import Foundation

/// How results reach the caller.
///
/// JSON is the default because the primary caller is a program. `--text` exists for the human who is
/// debugging what their agent just did, and never carries information the JSON lacks.
public enum OutputFormat: String, ExpressibleByArgument, CaseIterable, Sendable {
    case json
    case text
}

/// Flags every command shares.
public struct GlobalOptions: ParsableArguments, Sendable {
    @Option(name: .long, help: "Base URL of the Mimic control API. Defaults to MIMIC_CONTROL_URL, then the running instance.")
    public var url: String?

    @Option(name: .long, help: "Output format: json (default, for scripts and agents) or text.")
    public var format: OutputFormat = .json

    @Flag(name: .long, help: "Pretty-print JSON output.")
    public var pretty: Bool = false

    @Option(name: .long, help: "Seconds to wait for the control API.")
    public var timeout: Double = 30

    public init() {}

    /// The transport this invocation talks to — one funnel, so every subcommand resolves `--url` and
    /// `--timeout` the same way.
    ///
    /// It returns `any ControlTransport` rather than `ControlClient` so a test can bind a recording
    /// stub in `ControlTransportOverride` and drive the real subcommand tree. Without that there is
    /// no way in at all: ArgumentParser builds each command from argv, so there is no call site to
    /// hand a client to, and the emitted `ControlCommand` of every runnable verb — 55 of them, the
    /// 65 `AsyncParsableCommand` types in this module less the 10 that only group others — was
    /// unassertable in consequence. The production path is unchanged: with nothing bound, this is the
    /// same `ControlClient.discover` call it always made.
    public func client() throws -> any ControlTransport {
        if let override = ControlTransportOverride.current { return override }
        return try ControlClient.discover(explicitURL: url, timeout: timeout)
    }
}

/// Writes results and errors, and owns the process exit contract.
///
/// The contract matters more than the formatting: **stdout carries the payload, stderr carries
/// diagnostics, and the exit code says what happened**. An agent can therefore capture stdout and
/// parse it without stripping log lines, and can branch on the exit code without parsing at all.
/// `0` success, `2` bad usage, `3` no reachable instance, `4` the command failed.
public struct Output: Sendable {
    public var format: OutputFormat
    public var pretty: Bool

    public init(format: OutputFormat = .json, pretty: Bool = false) {
        self.format = format
        self.pretty = pretty
    }

    public init(_ options: GlobalOptions) {
        self.init(format: options.format, pretty: options.pretty)
    }

    /// Renders a successful response, or throws so the caller exits non-zero on failure.
    public func emit(_ response: ControlResponse) throws {
        guard response.ok, let result = response.result else {
            throw CLIFailure.commandFailed(response.error ?? .internalFailure("Unknown failure."))
        }
        switch format {
        case .json:
            print(try ControlCoding.string(result, pretty: pretty))
        case .text:
            print(TextRenderer.render(result))
        }
    }

    /// For local commands that produce no control response (e.g. launching the app).
    public func emitMessage(_ message: String) {
        switch format {
        case .json:
            let result = ControlResult.message(message)
            print((try? ControlCoding.string(result, pretty: pretty)) ?? message)
        case .text:
            print(message)
        }
    }

    public static func writeError(_ error: any Error) {
        let text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        FileHandle.standardError.write(Data("\(text)\n".utf8))
    }

    public static func exitCode(for error: any Error) -> Int32 {
        (error as? CLIFailure)?.exitCode ?? 1
    }
}

/// Human-readable rendering of a result. Deliberately terse — tables, not prose.
enum TextRenderer {
    static func render(_ result: ControlResult) -> String {
        var lines: [String] = []

        if let state = result.state {
            lines.append(renderState(state))
        }
        if let server = result.server {
            lines.append(renderServer(server))
        }
        if let projects = result.projects {
            lines.append(projects.isEmpty ? "No stored projects." : projects.map(renderProject).joined(separator: "\n"))
        }
        if let project = result.project {
            lines.append("""
            \(project.name)
              port         \(project.serverConfiguration.port)
              global delay \(project.serverConfiguration.globalDelayMs)ms
              endpoints    \(project.endpoints.count)
              journeys     \(project.journeys.count)\
            \(project.activeJourney.map { "\n  active       \($0.name)" } ?? "")
            """)
        }
        if let endpoints = result.endpoints {
            lines.append(endpoints.isEmpty ? "No endpoints." : endpoints.map(renderEndpoint).joined(separator: "\n"))
        }
        if let endpoint = result.endpoint {
            lines.append(renderEndpoint(endpoint))
        }
        if let scenarios = result.scenarios {
            lines.append(scenarios.isEmpty ? "No scenarios." : scenarios.map(renderScenario).joined(separator: "\n"))
        }
        if let scenario = result.scenario {
            lines.append(renderScenario(scenario))
        }
        if let journeys = result.journeys {
            lines.append(journeys.isEmpty ? "No journeys." : journeys.map(renderJourneySummary).joined(separator: "\n"))
        }
        if let journey = result.journey {
            lines.append(renderJourney(journey))
        }
        if let status = result.journeyStatus {
            lines.append(renderStatus(status))
        }
        if let templates = result.journeyTemplates {
            lines.append(templates.map { "\($0.id.padded(to: 24))\($0.title)\n\("".padded(to: 24))\($0.summary)" }
                .joined(separator: "\n"))
        }
        if let logs = result.logs {
            lines.append(logs.isEmpty ? "No requests logged." : logs.map(renderLog).joined(separator: "\n"))
        }
        if let commands = result.commands {
            lines.append(commands.map { "\($0.name.padded(to: 22))\($0.summary)\n\("".padded(to: 22))\($0.cli)" }
                .joined(separator: "\n"))
        }
        if let message = result.message {
            lines.append(message)
        }

        return lines.isEmpty ? "OK" : lines.joined(separator: "\n\n")
    }

    static func renderState(_ state: ControlState) -> String {
        var text = """
        Mimic \(state.mode) (api \(state.apiVersion), pid \(state.pid))
        \(renderServer(state.server))
        """
        // A session on the in-memory fallback has to say so here: the window shows an alert, and a
        // headless run has no window — this line is the only place an unattended caller can learn
        // that every write it was told succeeded evaporates at stop. The reason keeps its own
        // lines, indented the way a server message is; blank lines are dropped, not indented.
        if let storeFailure = state.storeFailure {
            text += "\nstore        in memory — nothing will be saved"
            for line in storeFailure.split(separator: "\n", omittingEmptySubsequences: true) {
                text += "\n             \(line)"
            }
        }
        if let project = state.project {
            text += "\nproject      \(project.name) — \(state.endpointCount) endpoints, \(state.journeyCount) journeys"
        } else {
            text += "\nproject      (none open)"
        }
        if let journey = state.activeJourney {
            text += "\njourney      \(journey.journeyName) — \(runPosition(journey))"
        } else {
            text += "\njourney      (none active)"
        }
        text += "\nrequest log  \(state.requestLogCount) entries"
        return text
    }

    static func renderServer(_ server: ServerStatusReport) -> String {
        var text = "server       \(server.state) on port \(server.port)"
        if let baseURL = server.baseURL { text += " (\(baseURL))" }
        if server.globalDelayMs > 0 { text += ", global delay \(server.globalDelayMs)ms" }
        if let message = server.message { text += "\n             \(message)" }
        return text
    }

    static func renderProject(_ project: ProjectSummary) -> String {
        "\(project.name.padded(to: 28))port \(String(project.port).padded(to: 6))"
            + "\(project.endpointCount) endpoints, \(project.journeyCount) journeys"
    }

    static func renderEndpoint(_ endpoint: Endpoint) -> String {
        let active = endpoint.scenarios.first { $0.id == endpoint.activeScenarioID }
        var text = "\(endpoint.method.rawValue.padded(to: 8))\(route(endpoint.path, endpoint.graphqlOperation).padded(to: 40))"
        text += active.map { "\($0.statusCode) \($0.name)" } ?? "(no active scenario)"
        if endpoint.delayMs > 0 { text += " +\(endpoint.delayMs)ms" }
        if let group = endpoint.groupTag { text += " [\(group)]" }
        return text
    }

    static func renderScenario(_ scenario: Scenario) -> String {
        "\(String(scenario.statusCode).padded(to: 6))\(scenario.name.padded(to: 26))\(scenario.bodyContentType.rawValue)"
    }

    static func renderJourneySummary(_ journey: Journey) -> String {
        "\(journey.name.padded(to: 30))\(journey.steps.count) steps, \(journey.matchMode.rawValue), \(journey.completion.rawValue)"
    }

    static func renderJourney(_ journey: Journey) -> String {
        var lines = ["\(journey.name)  (\(journey.steps.count) steps)"]
        if let summary = journey.summary { lines.append("  \(summary)") }
        lines.append("  match \(journey.matchMode.rawValue) · on completion \(journey.completion.rawValue) "
            + "· unmatched \(journey.unmatchedBehavior.rawValue) · autoAdvance \(journey.autoAdvance)")
        for (index, step) in journey.steps.enumerated() {
            lines.append("  \(String(index).padded(to: 4))\(renderStep(step))")
        }
        return lines.joined(separator: "\n")
    }

    /// A GraphQL route is the same string for every operation, so the path alone identifies nothing.
    /// Appending the operation is what makes a listing readable.
    static func route(_ path: String, _ operation: String?) -> String {
        guard let operation, !operation.isEmpty else { return path }
        return "\(path) \u{00B7} \(operation)"
    }

    static func renderStep(_ step: JourneyStep) -> String {
        var text = "\(step.method.rawValue.padded(to: 8))\(route(step.path, step.graphqlOperation).padded(to: 40))"
        switch step.outcome {
        case let .respond(response):
            text += "→ \(response.statusCode)"
        case let .networkFailure(failure):
            switch failure {
            case .connectionDrop: text += "→ connection drop"
            case let .timeout(holdMs): text += "→ timeout after \(holdMs)ms"
            }
        }
        if step.delayMs > 0 { text += " +\(step.delayMs)ms" }
        if step.repeatCount > 1 { text += " ×\(step.repeatCount)" }
        return text
    }

    /// Where a run stands, in one phrase. Shared because the two renderers that need it read the
    /// same field two different ways, and both readings were wrong in the same place.
    ///
    /// A nil `currentStepIndex` says only that the cursor names no step. `renderStatus` defaulted it
    /// to zero and printed `step 1/0`; `renderState` mapped it to `complete` and reported a journey
    /// that had never run as finished. A journey with no steps is one command away —
    /// `mimic journey create Flow --activate` sends `journeyCreate` with a spec carrying no steps and
    /// then `journeyActivate`, whose reply is `JourneyStatus.make(journey:state: nil)`: `isComplete`
    /// false, cursor `0`, `totalSteps` `0`, so the index is nil — and it renders through both.
    static func runPosition(_ status: JourneyStatus) -> String {
        guard let index = status.currentStepIndex else {
            return status.isComplete ? "complete" : "no current step"
        }
        return "step \(index + 1)/\(status.totalSteps)"
    }

    static func renderStatus(_ status: JourneyStatus) -> String {
        var lines = ["\(status.journeyName) — \(runPosition(status)), \(status.totalServed) served"]
        for step in status.steps {
            let marker = step.isCurrent ? "▶" : (step.isExhausted ? "✓" : " ")
            let outcome = step.failure ?? step.statusCode.map(String.init) ?? "?"
            var line = "  \(marker) \(String(step.index).padded(to: 4))"
            line += "\(step.method.rawValue.padded(to: 8))\(route(step.path, step.graphqlOperation).padded(to: 40))→ \(outcome)"
            if step.repeatCount > 1 { line += "  \(step.servedCount)/\(step.repeatCount)" }
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    static func renderLog(_ log: RequestLog) -> String {
        let result = log.failureLabel ?? log.responseStatusCode.map(String.init) ?? "—"
        let stamp = ISO8601DateFormatter().string(from: log.timestamp)
        var text = "\(stamp)  \(log.method.rawValue.padded(to: 8))\(log.path.padded(to: 34))\(result.padded(to: 6))"
        // Naming the outcome is the point of the column: an unmatched request is a missing mock.
        text += log.outcome.label
        return text
    }
}

extension String {
    /// Left-aligns to a fixed width for column output; over-long values push the row wider rather
    /// than being truncated, because a truncated path is a misleading path.
    func padded(to width: Int) -> String {
        count >= width ? self + " " : self + String(repeating: " ", count: width - count)
    }
}
