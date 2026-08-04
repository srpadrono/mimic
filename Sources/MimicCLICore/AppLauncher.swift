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
            throw CLIFailure.badArgument(
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

    /// Asks the instance to quit. `SIGTERM` rather than `SIGKILL` so it can flush pending saves and
    /// remove its discovery file.
    public static func terminate(pid: Int) throws {
        guard pid > 0 else { throw CLIFailure.badArgument("Invalid pid \(pid).") }
        guard kill(pid_t(pid), SIGTERM) == 0 else {
            throw CLIFailure.badArgument("Could not stop pid \(pid): \(String(cString: strerror(errno))).")
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
        throw CLIFailure.badArgument(
            """
            Could not find Mimic.app. Looked in:
            \(searched.map { "  \($0.path)" }.joined(separator: "\n"))
            Set \(appPathEnvironmentKey) to the app bundle, or install Mimic in /Applications.
            """
        )
    }
}
