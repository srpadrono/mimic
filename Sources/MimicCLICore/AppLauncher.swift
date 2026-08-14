import Domain
import Foundation

/// Finds and launches the Mimic application.
///
/// The CLI deliberately hosts nothing itself — no server, no database — so "start Mimic" means
/// launching the app binary, optionally windowless. That keeps one implementation of the engine and
/// the store, and means `mimic` remains a small, dependency-light client an agent can call from
/// anywhere.
public enum AppLauncher {

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
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            if let client = try? ControlClient.discover(explicitURL: explicitURL, timeout: 5),
               await client.isReachable() {
                return client
            }
            try? await Task.sleep(for: pollInterval)
        }
        throw CLIFailure.unreachable(
            baseURL: URL(string: "http://127.0.0.1:\(ControlAPI.defaultPort)")!,
            underlying: "Mimic did not answer within \(Int(timeout))s. "
                + "Check that the app launched, or set \(appPathEnvironmentKey)."
        )
    }

    /// Confirms that the pid in a discovery file belongs to the Mimic that wrote it, before anything
    /// signals it.
    ///
    /// `mimic app stop` read a pid out of `control.json` and handed it straight to `kill(2)`. Two
    /// facts make that unsafe together: the file outlives a crash, and the liveness check that is
    /// meant to catch a stale one — `ControlEndpointDiscovery.isProcessAlive(_:)` — returns `true`
    /// on `EPERM`, which means "a process with that id exists and is *not* yours". So a file left by
    /// an instance that died, naming a pid the kernel has since recycled, reads as live and collects
    /// a `SIGTERM` meant for Mimic. Whoever owns that pid now finds out when their editor closes.
    ///
    /// The file cannot settle it — every field in it is the thing in doubt. The instance can: it is
    /// asked for its own state, on the loopback port the file names, presenting the token the file
    /// carries, and the pid it reports back must be the pid about to be signalled. A process that is
    /// not Mimic cannot answer that at all; a *different* Mimic answers with a different pid; a dead
    /// one does not answer. For a genuine instance the two numbers are the same by construction —
    /// `ControlServer` writes `ProcessInfo.processInfo.processIdentifier` into the file and
    /// `AppControlHost` reports that same value as `state.pid`.
    ///
    /// When it cannot be confirmed, nothing is signalled and the refusal names the pid so the caller
    /// can decide for themselves. That is the safe direction to fail in: refusing costs one `kill`
    /// typed by hand, and proceeding costs an unrelated process a signal it never asked for.
    ///
    /// A test replaces the instance the same way it replaces one anywhere else in this module, by
    /// binding `ControlTransportOverride` — one seam rather than a second injection point that only
    /// this function would understand.
    ///
    /// `timeout` is 5s and not `--timeout`: the instance is on loopback and answers in milliseconds
    /// if it is there at all, a stale file refuses the connection immediately, and the only case that
    /// waits out the clock is a wedged instance — which is the case this is about to refuse anyway.
    public static func confirmRunningInstance(
        _ endpoint: ControlEndpoint,
        timeout: TimeInterval = 5
    ) async throws {
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
            client = ControlClient(baseURL: baseURL, timeout: timeout, token: endpoint.token)
        }

        let response: ControlResponse
        do {
            response = try await client.send(.state)
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
        guard pid > 0 else { throw CLIFailure.appUnavailable("Invalid pid \(pid).") }
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
        guard deliver(pid_t(pid), SIGTERM) == 0 else {
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
            if fileManager.isExecutableFile(atPath: candidate.path),
               candidate.pathExtension != "app" {
                return candidate
            }
            let inner = candidate.appendingPathComponent("Contents/MacOS/Mimic")
            if fileManager.isExecutableFile(atPath: inner.path) {
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
}

/// Where `AppLauncher.terminate` delivers its signal, replaceable for the length of one task tree.
///
/// The guard above it — `confirmRunningInstance`, and the `pid > 0` check inside `terminate` — exists
/// to *not* signal, and the only honest assertion about that is "nothing was signalled". While the
/// delivery was a bare `kill(2)` there was no way to write one, and the attempt was worse than the
/// gap: `AppCommand.Stop` reads the machine's real `control.json` and takes no injection, so a test
/// driving `mimic app stop` far enough to reach the guard would, on a developer's machine with Mimic
/// open and the guard one day removed, have discovered the regression by SIGTERMing their instance. A
/// test that performs the harm it exists to prevent is not a test. Bound, the pid still travels the
/// whole production path and the signal stops at the recorder.
///
/// It cannot send a signal anywhere one would not otherwise go, and it does not soften the guard:
/// nothing in production binds it, so `current` is `nil` for every real invocation.
///
/// ```bash
/// # The claim above, in one command — binding is `$current.withValue` and nothing else can do it.
/// # Prints nothing; exits 1. Written with a character class so this comment is not its own hit.
/// grep -rn 'SignalDeliveryOverride[.]\$current' Sources Tools App/Sources
/// ```
///
/// A task local rather than a stored property or a mutable static, for the same two reasons
/// `ControlTransportOverride` is one: ArgumentParser builds each subcommand out of argv, so there is
/// no call site a test could hand a stub to, and a mutable global would be shared mutable state in a
/// module that compiles nonisolated — two suites in parallel would overwrite each other's.
public enum SignalDeliveryOverride {
    @TaskLocal public static var current: (@Sendable (pid_t, Int32) -> Int32)?
}
