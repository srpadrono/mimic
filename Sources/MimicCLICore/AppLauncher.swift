import Domain
import Foundation

/// Finds and launches the Mimic application.
///
/// The CLI deliberately hosts nothing itself — no server, no database — so "start Mimic" means
/// launching the app binary, optionally windowless. That keeps one implementation of the engine and
/// the store, and means `mimic` remains a small, dependency-light client an agent can call from
/// anywhere.
public enum AppLauncher {

    /// A local app should finish starting well within an hour. Bounding the user-supplied value
    /// also keeps nonfinite and enormous Doubles out of Duration and Int conversions.
    public static let maximumReadinessWaitSeconds: TimeInterval = 60 * 60

    public static func validatedReadinessTimeout(_ timeout: TimeInterval) throws -> TimeInterval {
        guard timeout.isFinite, timeout > 0, timeout <= maximumReadinessWaitSeconds else {
            throw CLIFailure.badArgument(
                "--wait-seconds must be a finite number greater than 0 and at most \(Int(maximumReadinessWaitSeconds))."
            )
        }
        return timeout
    }

    /// Set this to run against a build that is not installed, e.g. Xcode's products directory.
    public static let appPathEnvironmentKey = "MIMIC_APP_PATH"
    /// Read by the app to suppress its window.
    public static let headlessEnvironmentKey = "MIMIC_HEADLESS"

    public static func launch(
        headless: Bool,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [URL]? = nil
    ) throws -> Process {
        let executable = try resolveExecutable(environment: environment, candidates: candidates)

        var childEnvironment = environment
        if headless {
            childEnvironment[headlessEnvironmentKey] = "1"
        }

        let process = Process()
        process.executableURL = executable
        process.environment = childEnvironment
        // Detach the child's streams: a launcher that inherits stdout would interleave the app's
        // logging into the JSON an agent is parsing.
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw CLIFailure.appUnavailable(
                "Could not launch \(executable.path): \(error.localizedDescription)"
            )
        }
        return process
    }

    /// Polls the control API until it answers or the deadline passes.
    ///
    /// Polling rather than sleeping a fixed interval: startup time varies with disk cache and machine
    /// load, and a script that guesses wrong is either slow or flaky.
    public static func waitForReadiness(
        explicitURL: String? = nil,
        timeout: TimeInterval,
        pollInterval: Duration = .milliseconds(150)
    ) async throws -> ControlClient {
        let timeout = try validatedReadinessTimeout(timeout)
        guard pollInterval > .zero else {
            throw CLIFailure.badArgument("The readiness poll interval must be greater than zero.")
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        var lastURL = URL(string: "http://127.0.0.1:\(ControlAPI.defaultPort)")!
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
            guard seconds > 0 else { break }
            let client: ControlClient?
            do {
                client = try ControlClient.discover(explicitURL: explicitURL, timeout: min(5, seconds))
            } catch CLIFailure.noInstance {
                client = nil
            }
            if let client {
                lastURL = client.baseURL
                let reachable = await client.isReachable()
                try Task.checkCancellation()
                if reachable, ContinuousClock.now < deadline { return client }
            }
            let sleepBudget = ContinuousClock.now.duration(to: deadline)
            if sleepBudget > .zero {
                try await Task.sleep(for: min(pollInterval, sleepBudget))
            }
        }
        try Task.checkCancellation()
        throw CLIFailure.unreachable(
            baseURL: lastURL,
            underlying: "Mimic did not answer within \(timeout)s. "
                + "Check that the app launched, or set \(appPathEnvironmentKey)."
        )
    }

    /// Confirms a discovery record's PID through its authenticated loopback control API before
    /// signalling it. A stale file can name a PID that has since been assigned to another process.
    /// The responding instance must report the same PID; missing, refused or mismatched replies
    /// leave the process untouched. Explicit destination overrides do not participate in this check.
    public static func confirmRunningInstance(
        _ endpoint: ControlEndpoint,
        timeout: TimeInterval = 5
    ) async throws {
        try Task.checkCancellation()
        _ = try ControlClient.validatedTimeout(timeout)
        // The file's own port, and deliberately not `MIMIC_CONTROL_URL`: the pid about to be
        // signalled is the one *this file* names, so the instance that has to confirm it is the one
        // this file advertises. An environment pointing somewhere else describes a different Mimic,
        // whose pid means nothing here.
        guard let baseURL = ControlEndpointDiscovery.resolveBaseURL(
            explicit: nil,
            environment: [:],
            discovered: endpoint
        ) else {
            throw CLIFailure.appUnavailable(refusal(
                endpoint,
                because: "its discovery file names port \(endpoint.port), which is not a port."
            ))
        }

        // Spelled out rather than coalesced, so each branch converts to the declared existential on
        // its own line.
        let client: any ControlTransport
        if let override = ControlTransportOverride.current {
            client = override
        } else {
            client = try ControlClient(baseURL: baseURL, timeout: timeout, token: endpoint.token)
        }

        let response: ControlResponse
        do {
            response = try await client.send(.state)
            try Task.checkCancellation()
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CLIFailure.appUnavailable(refusal(
                endpoint,
                // "did not confirm" rather than "did not answer": a refusal is an answer, and a
                // `401` from an instance whose token this CLI does not have arrives here too.
                because: "the control API did not confirm it — "
                    + ((error as? any LocalizedError)?.errorDescription ?? error.localizedDescription)
            ))
        }

        guard response.ok, let state = response.result?.state else {
            throw CLIFailure.appUnavailable(refusal(
                endpoint,
                because: "\(baseURL.absoluteString) answered, but not with the state a Mimic reports."
            ))
        }
        guard state.pid == endpoint.pid else {
            throw CLIFailure.appUnavailable(refusal(
                endpoint,
                because: "the instance answering at \(baseURL.absoluteString) is pid \(state.pid), "
                    + "not \(endpoint.pid)."
            ))
        }
    }

    /// One shape for every refusal, so the part that tells the caller what to do next cannot be the
    /// part that gets left out of one of them.
    private static func refusal(
        _ endpoint: ControlEndpoint,
        because reason: String
    ) -> String {
        """
        Refusing to signal pid \(endpoint.pid): \(reason)
        That pid comes from Mimic's discovery file, and a file left behind by a crashed instance can \
        name a pid the system has since given to something else.
        If you are sure it is Mimic, stop it by hand: kill \(endpoint.pid)
        """
    }

    /// Asks the instance to quit. `SIGTERM` rather than `SIGKILL` so it can flush pending saves and
    /// remove its discovery file.
    ///
    /// This signals whatever it is told to. `confirmRunningInstance` is what establishes that the pid
    /// is Mimic's, and `AppCommand.Stop` calls it first — do not add a caller here that skips it.
    public static func terminate(pid: Int) throws {
        guard let systemPID = pid_t(exactly: pid), systemPID > 0 else {
            throw CLIFailure.appUnavailable("Invalid pid \(pid).")
        }
        // Named rather than called inline, so a test can assert the one thing a refusal is *about*:
        // that nothing was signalled at all. See `SignalDeliveryOverride`. Nothing in production
        // binds it, so this is the same `kill(2)` call it has always been.
        //
        // Spelled out rather than coalesced, matching `confirmRunningInstance` above: each branch
        // converts to the declared function type on its own line.
        let deliver: @Sendable (pid_t, Int32) -> Int32
        if let override = SignalDeliveryOverride.current {
            deliver = override
        } else {
            deliver = { kill($0, $1) }
        }
        guard deliver(systemPID, SIGTERM) == 0 else {
            throw CLIFailure.appUnavailable(
                "Could not stop pid \(pid): \(String(cString: strerror(errno)))."
            )
        }
    }

    /// Locations to try, most explicit first. `MIMIC_APP_PATH` accepts either the bundle or the
    /// executable inside it, because both are things a developer has to hand.
    public static func candidateBundles(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var candidates: [URL] = []
        if let override = environment[appPathEnvironmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: (override as NSString).expandingTildeInPath))
        }
        candidates.append(URL(fileURLWithPath: "/Applications/Mimic.app"))
        candidates.append(homeDirectory.appendingPathComponent("Applications/Mimic.app"))
        return candidates
    }

    /// `candidates` is injectable so this can be tested without depending on what happens to be
    /// installed on the machine running the suite.
    static func resolveExecutable(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        candidates: [URL]? = nil,
        fileManager: FileManager = .default
    ) throws -> URL {
        let searched = candidates ?? candidateBundles(environment: environment)
        for candidate in searched {
            // A path straight to the executable.
            if isExecutableFile(candidate, fileManager: fileManager),
               candidate.pathExtension != "app" {
                return candidate
            }
            let inner = candidate.appendingPathComponent("Contents/MacOS/Mimic")
            if isExecutableFile(inner, fileManager: fileManager) {
                return inner
            }
        }
        throw CLIFailure.appUnavailable(
            """
            Could not find Mimic.app. Looked in:
            \(searched.map { "  \($0.path)" }.joined(separator: "\n"))
            Set \(appPathEnvironmentKey) to the app bundle, or install Mimic in /Applications.
            """
        )
    }

    private static func isExecutableFile(_ url: URL, fileManager: FileManager) -> Bool {
        var directory: ObjCBool = false
        return fileManager.fileExists(atPath: url.path, isDirectory: &directory)
            && !directory.boolValue && fileManager.isExecutableFile(atPath: url.path)
    }
}

/// Replaces signal delivery for one task tree so command tests cannot terminate a live app.
/// Production leaves this unset; task-local storage keeps parallel fixtures independent.
public enum SignalDeliveryOverride {
    @TaskLocal public static var current: (@Sendable (pid_t, Int32) -> Int32)?
}
