import ArgumentParser
import Domain
import Foundation

/// `mimic` — the whole of Mimic, without the window.
///
/// Designed for a program to drive: JSON on stdout by default, diagnostics on stderr, and exit codes
/// that mean something (`0` ok, `2` bad usage, `3` no instance reachable, `4` command failed). Every
/// operation the UI offers is here, and `mimic commands` lets a caller discover the surface from the
/// running instance rather than from documentation that may not match it.
public struct MimicCommand: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "mimic",
        abstract: "Drive a local Mimic mock server from scripts and AI agents.",
        discussion: """
        Every command talks to a running Mimic over its loopback control API. Start one with
        `mimic app start` (with the window) or `mimic daemon start` (headless, for CI), or point at a
        specific instance with MIMIC_CONTROL_URL or --url.

        Output is JSON unless --format text is given. Exit codes: 0 success, 2 bad usage,
        3 no reachable instance, 4 the command failed.

        A journey scripts an ordered sequence of responses, so the same route can answer differently
        depending on where the request falls in a flow:

          mimic journey add-template retry-after-failure --activate
          mimic server start
          mimic journey status
        """,
        version: "mimic \(ControlAPI.releaseVersion) (control API \(ControlAPI.version))",
        subcommands: [
            Ping.self,
            State.self,
            Commands.self,
            Reset.self,
            AppCommand.self,
            DaemonCommand.self,
            ServerCommand.self,
            ProjectCommand.self,
            EndpointCommand.self,
            ScenarioCommand.self,
            JourneyCommand.self,
            LogCommand.self,
        ]
    )

    public init() {}

    /// Runs the CLI, mapping thrown failures onto the documented exit codes.
    ///
    /// ArgumentParser's own `main()` would not report what the contract promises; the whole point of
    /// the exit contract is that a script can tell "no instance" from "command failed" without
    /// parsing text.
    public static func run(arguments: [String]? = nil) async -> Int32 {
        do {
            var command = try parseAsRoot(arguments)
            if var asyncCommand = command as? any AsyncParsableCommand {
                try await asyncCommand.run()
            } else {
                try command.run()
            }
            return 0
        } catch let error as CLIFailure {
            Output.writeError(error)
            return error.exitCode
        } catch {
            // Usage errors and --help both arrive here; ArgumentParser knows how to render them.
            let code = exitCode(for: error)
            let message = fullMessage(for: error)
            if !message.isEmpty {
                if code == .success {
                    print(message)
                } else {
                    FileHandle.standardError.write(Data("\(message)\n".utf8))
                }
            }
            // Anything still thrown here came from ArgumentParser itself — an unknown subcommand, a
            // missing argument, a value it could not convert — and every one of those is "bad usage",
            // which the contract fixes at 2. Passing `code.rawValue` through instead was wrong: for a
            // usage error ArgumentParser returns `EX_USAGE`, so `mimic nonsense` and `mimic endpoint
            // create` exited **64** while docs/CLI.md promised 2 for exactly that case. The old code
            // rewrote only 1 → 2, and 1 is a value this path does not produce. `--help` and
            // `--version` arrive here too, but as `.success`, and still exit 0.
            return code == .success ? 0 : 2
        }
    }
}

// MARK: - Discovery and state

struct Ping: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Check that a Mimic instance is reachable.")

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try Output(options).emit(await options.client().send(.ping))
    }
}

struct State: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Report server, project, journey, and log state in one call."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try Output(options).emit(await options.client().send(.state))
    }
}

struct Commands: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "commands",
        abstract: "List every operation the running instance supports."
    )

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        try Output(options).emit(await options.client().send(.describeCommands))
    }
}

struct Reset: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Return the instance to a known state before a test.",
        discussion: """
        Clears the request log and rewinds the active journey. Run this between test cases so each one
        starts from step one with an empty log.
        """
    )

    @Option(name: .long, help: "What to clear: logs, journey, or all (default).")
    var scope: String = "all"

    @OptionGroup var options: GlobalOptions

    func run() async throws {
        let resolved = try ArgumentParsing.resetScope(scope)
        try Output(options).emit(await options.client().send(.reset(scope: resolved)))
    }
}

// MARK: - Instance lifecycle

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Start or stop the Mimic application.",
        subcommands: [Start.self, Stop.self, Status.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch Mimic and wait until its control API answers.",
            discussion: """
            Waiting for readiness is the point: a script that launches Mimic and immediately issues a
            command would otherwise race the app's startup. Set MIMIC_APP_PATH to point at a build
            that is not installed in /Applications.
            """
        )

        @Flag(name: .long, help: "Run without a window (for CI and agent workflows).")
        var headless: Bool = false

        @Option(name: .long, help: "Seconds to wait for the control API to answer.")
        var waitSeconds: Double = 30

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            if let existing = try? options.client(), await existing.isReachable() {
                Output(options).emitMessage("Mimic is already running at \(existing.baseURL.absoluteString).")
                return
            }

            let launched = try AppLauncher.launch(headless: headless)
            let client = try await AppLauncher.waitForReadiness(
                explicitURL: options.url,
                timeout: waitSeconds
            )
            Output(options).emitMessage(
                "Started Mimic (pid \(launched.processIdentifier)\(headless ? ", headless" : "")) "
                    + "at \(client.baseURL.absoluteString)."
            )
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Quit the running Mimic instance.",
            discussion: """
            The instance is the one its discovery file names, so this ignores --url: a pid only means
            something on the machine it was read from. Mimic is asked to confirm that pid is its own
            before anything is signalled — if it cannot, nothing is, and the message says how to stop
            it by hand.
            """
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            guard let endpoint = ControlEndpointFileReader.discover() else {
                throw CLIFailure.noInstance
            }
            // A pid in a file is not evidence — see `AppLauncher.confirmRunningInstance`. Nothing is
            // signalled until the instance itself has answered that it is the process named there.
            try await AppLauncher.confirmRunningInstance(endpoint)
            try AppLauncher.terminate(pid: endpoint.pid)
            Output(options).emitMessage("Stopped Mimic (pid \(endpoint.pid)).")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Report whether an instance is running and where."
        )

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            guard let client = try? options.client(), await client.isReachable() else {
                Output(options).emitMessage("No Mimic instance is reachable.")
                return
            }
            try Output(options).emit(try await client.send(.state))
        }
    }
}

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "Start or stop Mimic headless — the shape CI and agents want.",
        subcommands: [Start.self, Stop.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Launch Mimic without a window and wait until it answers."
        )

        @Option(name: .long, help: "Seconds to wait for the control API to answer.")
        var waitSeconds: Double = 30

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            var start = AppCommand.Start()
            start.headless = true
            start.waitSeconds = waitSeconds
            start.options = options
            try await start.run()
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop the headless instance.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            var stop = AppCommand.Stop()
            stop.options = options
            try await stop.run()
        }
    }
}

// MARK: - Server

struct ServerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "server",
        abstract: "Control the mock HTTP server.",
        subcommands: [Start.self, Stop.self, Status.self, Configure.self]
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Start serving the open project.")

        @Option(name: .long, help: "Port to serve on. Persists to the project.")
        var port: Int?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.serverStart(port: port)))
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Stop serving.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.serverStop))
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Report the server state and base URL.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.serverStatus))
        }
    }

    struct Configure: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Set the port and/or the global response delay."
        )

        @Option(name: .long, help: "Port for the mock server.")
        var port: Int?

        @Option(name: .long, help: "Global delay in milliseconds, added to every response.")
        var delay: Int?

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            guard port != nil || delay != nil else {
                throw CLIFailure.badArgument("Provide --port and/or --delay.")
            }
            try Output(options).emit(
                await options.client().send(.serverConfigure(port: port, globalDelayMs: delay))
            )
        }
    }
}

// MARK: - Logs

struct LogCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "log",
        abstract: "Read or clear the served-request log.",
        subcommands: [List.self, Clear.self]
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List served requests, oldest first.",
            discussion: """
            Each entry records what answered it — an endpoint, a journey step, or nothing at all.

            `--unmatched` narrows the list to requests Mimic had no configuration for, which is the
            quickest way to find a route your client calls but you have not mocked yet:

              mimic log list --unmatched --format text
            """
        )

        @Option(name: .long, help: "Return only the most recent N entries.")
        var limit: Int?

        @Flag(name: .long, help: "Only requests that matched nothing — the mocks you are missing.")
        var unmatched: Bool = false

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(
                await options.client().send(.logList(limit: limit, unmatchedOnly: unmatched ? true : nil))
            )
        }
    }

    struct Clear: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Discard every logged request.")

        @OptionGroup var options: GlobalOptions

        func run() async throws {
            try Output(options).emit(await options.client().send(.logClear))
        }
    }
}
