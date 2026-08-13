import Foundation

/// The parts of a host-scoped answer that are a pure function of values the host already holds.
///
/// ``ProjectCommandExecutor`` is the repository's answer for the project-scoped majority: one
/// implementation, so the window and a script cannot drift. The host-scoped minority genuinely needs
/// state the open document does not hold — which project is open, whether the engine is bound, where
/// the live cursor sits, what has been logged. What answering does *not* need is a private copy of
/// the arithmetic and shaping applied to those values afterwards, and this type exists because that
/// copy demonstrably drifts: while the tree carried two hosts, `makeServerStatus` was the same
/// switch written twice and `makeState` derived the same three fields from the same project in two
/// places, and they had come apart. The second host is deleted now (AGENTS.md, "One host"); this
/// split survives it, because it is the same discipline the executor applies to the other side of
/// the line — the host reads its own state and hands the values over, and everything downstream —
/// the state string, the loopback URL, the counts, the summary merge, the log's filter and trim —
/// happens here, once, where `DomainTests` can reach it without standing up a session.
///
/// Foundation only, and deliberately: nothing here may reach an engine, a store or a window. A helper
/// that needs one of those is not a report, it is the host's own work, and it belongs in the host.
public enum HostReport {

    // MARK: - Server

    /// The address a caller points a client at while the mock server is bound.
    ///
    /// Loopback is not a default here, it is the contract — the mock server binds `127.0.0.1` and the
    /// control plane refuses to widen (see AGENTS.md). Built in one place because it used to be
    /// built in three, across the two hosts the tree then carried, and the copies had drifted.
    public static func loopbackBaseURL(port: Int) -> String {
        "http://127.0.0.1:\(port)"
    }

    /// The wire report for a server state.
    ///
    /// `configuredPort` is the port the *project* is set to serve on, which is what a caller needs
    /// while nothing is listening; a running server reports the port it actually bound instead, and
    /// the two can differ when the configuration was changed under a live server. `baseURL` is
    /// present only while running, so a caller can point a client at it without string-building.
    ///
    /// Where each host gets those two values from is the genuine difference between them and stays
    /// theirs: the service falls back to ``ServerConfiguration/default`` with no project open, the
    /// window reads the session's configuration.
    public static func serverStatus(
        state: ServerState,
        configuredPort: Int,
        globalDelayMs: Int
    ) -> ServerStatusReport {
        switch state {
        case let .running(runningPort):
            return ServerStatusReport(
                state: "running",
                port: runningPort,
                baseURL: loopbackBaseURL(port: runningPort),
                globalDelayMs: globalDelayMs
            )
        case .stopped:
            return ServerStatusReport(
                state: "stopped",
                port: configuredPort,
                baseURL: nil,
                globalDelayMs: globalDelayMs
            )
        case .starting:
            return ServerStatusReport(
                state: "starting",
                port: configuredPort,
                baseURL: nil,
                globalDelayMs: globalDelayMs
            )
        case .stopping:
            return ServerStatusReport(
                state: "stopping",
                port: configuredPort,
                baseURL: nil,
                globalDelayMs: globalDelayMs
            )
        case let .error(message):
            return ServerStatusReport(
                state: "error",
                port: configuredPort,
                baseURL: nil,
                globalDelayMs: globalDelayMs,
                message: message
            )
        }
    }

    // MARK: - Instance state

    /// The answer to `mimic state`, from what the host has already read.
    ///
    /// The three fields derived from the open document — the summary and the two counts — are the
    /// reason this is shared rather than left to each host: they are a function of `project` and
    /// nothing else, and each host was computing all three from its own copy of the same expression.
    /// Everything a host genuinely knows on its own is a parameter.
    public static func state(
        appVersion: String?,
        mode: String,
        pid: Int,
        server: ServerStatusReport,
        project: MockProject?,
        activeJourney: JourneyStatus?,
        requestLogCount: Int
    ) -> ControlState {
        ControlState(
            appVersion: appVersion,
            mode: mode,
            pid: pid,
            server: server,
            project: project.map(ProjectSummary.init),
            endpointCount: project?.endpoints.count ?? 0,
            journeyCount: project?.journeys.count ?? 0,
            activeJourney: activeJourney,
            requestLogCount: requestLogCount
        )
    }

    // MARK: - Project listing

    /// Stored project stubs turned into the listing `mimic project list` answers with.
    ///
    /// `allProjects()` returns stubs with no children, so the counts come from the store's own
    /// grouped query. A project with neither endpoint nor journey has no row in `counts` and the
    /// stub's own zeroes are already the right answer, which is why a missing entry is left alone
    /// rather than defaulted.
    ///
    /// `openProject` is the one asymmetry, and it is a real one rather than an accident: the window
    /// answers the open project from the session because an edit made a moment ago is still sitting
    /// in the autosave debounce, so the stored row is the one that can be behind. A caller whose
    /// store is never behind its session passes `nil` and the listing is the store, unmodified.
    public static func projectSummaries(
        of stored: [MockProject],
        counts: [UUID: ProjectCounts],
        openProject: MockProject? = nil
    ) -> [ProjectSummary] {
        stored.map { project -> ProjectSummary in
            if let openProject, openProject.id == project.id {
                return ProjectSummary(openProject)
            }
            var summary = ProjectSummary(project)
            if let count = counts[project.id] {
                summary.endpointCount = count.endpoints
                summary.journeyCount = count.journeys
            }
            return summary
        }
    }

    // MARK: - Request log

    /// The entries `logList` answers with: filtered, trimmed, and redacted, in that order.
    ///
    /// **The order is the contract.** Filtering before the limit is the useful reading of
    /// `--limit 20 --unmatched`: "the last 20 requests I have no mock for", not "whichever of the
    /// last 20 happened to be unmatched".
    ///
    /// **Redaction is not optional and not the caller's to skip.** The log holds whatever the app
    /// under test sent, and what it sends is real — a staging bearer token, a session cookie, an API
    /// key. Inside the app's own window that is exactly what you want to see; `logList` is the one
    /// command that hands captured traffic to somebody else, so it is applied on the way out here
    /// rather than trusted to a host arm to remember. See ``RequestLog/redactingCredentials()``.
    ///
    /// A negative `limit` is floored at zero rather than refused: a caller asking for -1 entries
    /// gets none, not an error about arithmetic.
    public static func requestLog(
        from logs: [RequestLog],
        limit: Int?,
        unmatchedOnly: Bool?
    ) -> [RequestLog] {
        var entries = logs
        if unmatchedOnly == true {
            entries = entries.filter(\.outcome.isMissingConfiguration)
        }
        if let limit {
            entries = Array(entries.suffix(max(0, limit)))
        }
        return entries.map { $0.redactingCredentials() }
    }
}
