import Domain
import Foundation
import Vapor

/// The HTTP face of the control plane, bound to loopback only.
///
/// A separate Vapor application from the mock server, on a separate port, for a reason: the mock
/// server answers *as* the API under test, and mixing an admin surface into it would make Mimic's own
/// routes indistinguishable from the mocks — and would leak the control plane to whatever the app
/// under test can reach. This one never binds anything but `127.0.0.1`.
///
/// The surface is deliberately tiny: three reads and one command endpoint. Adding a command adds a
/// `ControlCommand` case, not a route.
public actor ControlServer {

    private let host: any ControlHost
    private let mode: String
    private var app: Application?
    private var isStarting = false
    /// The other half of the `isStarting` guard. `stop()` clears `app` before it awaits the
    /// shutdown, so `app == nil` does not distinguish "never started" from "still closing".
    private var isStopping = false
    private var endpointFileURL: URL?

    /// This instance's token. Fresh per process; see ``ControlToken``.
    public let token: String

    public init(host: any ControlHost, mode: String = "headless", token: String? = nil) {
        self.host = host
        self.mode = mode
        // An explicit token exists for the case where the caller must know it before the server
        // binds — `MIMIC_CONTROL_TOKEN` set by a CI job that configures both sides.
        self.token = token
            ?? ProcessInfo.processInfo.environment[ControlAPI.tokenEnvironmentKey].flatMap {
                $0.isEmpty ? nil : $0
            }
            ?? ControlToken.generate()
    }

    /// Binds the control API.
    ///
    /// - Parameters:
    ///   - port: the port to bind, or `0` to let the OS choose (used by tests).
    ///   - advertise: write a discovery file so the CLI can find this instance without being told.
    /// - Returns: the port actually bound.
    @discardableResult
    public func start(port: Int, advertise: Bool = true) async throws -> Int {
        // `app == nil` alone does not close the window an actor leaves open. This method suspends
        // twice before it assigns `app` — building the application and binding the socket — and an
        // actor admits another call at every suspension, so two overlapping starts both saw `nil`,
        // both bound, and the second overwrote `app` with its own application. The first was then
        // unreachable: still listening on its port, never shut down by `stop()`, and with its
        // discovery file replaced by the second's — a CLI would be pointed at one instance while a
        // stray one held the other port for the life of the process. `MockServerEngine.start`
        // carries this guard for the same reason and in the same shape.
        guard app == nil, !isStarting else { throw ControlServerError.alreadyRunning }
        // And `stop()` opens the same window from the other end: it clears `app` and *then* suspends
        // on the shutdown, so a start arriving mid-stop sees `nil` and binds a port the outgoing
        // application still holds — the eight lines above, reasoned through only for two starts. A
        // separate case rather than `.alreadyRunning`: this one is worth retrying in a moment.
        guard !isStopping else { throw ControlServerError.shuttingDown }
        isStarting = true
        defer { isStarting = false }

        let env = Environment(name: "production", arguments: ["vapor"])
        let application = try await Application.make(env)
        application.logger.logLevel = .warning
        application.http.server.configuration.hostname = "127.0.0.1"
        application.http.server.configuration.port = port

        register(on: application)

        do {
            try await application.server.start(address: .hostname("127.0.0.1", port: port))
        } catch {
            try? await application.asyncShutdown()
            let description = String(describing: error).lowercased()
            if description.contains("address already in use") || description.contains("eaddrinuse") {
                throw ControlServerError.portInUse(port: port)
            }
            throw error
        }

        let boundPort = application.http.server.shared.localAddress?.port ?? port
        app = application

        if advertise {
            let endpoint = ControlEndpoint(
                port: boundPort,
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                mode: mode,
                token: token
            )
            // Reported, not swallowed, and not fatal either.
            //
            // Not fatal because an instance that cannot advertise itself is still perfectly usable:
            // `MIMIC_CONTROL_URL` and `MIMIC_CONTROL_PORT` reach it without the file, and the one
            // caller that throws — `ControlPlaneCoordinator` — drops the server *and* the host when
            // `start` throws, so failing here would turn "the CLI cannot discover me" into "the CLI
            // cannot reach me at all".
            //
            // Reported because the two `try?` this replaces made every failure invisible, and
            // `ControlEndpointFile.write` exists to be strict about exactly this file: it refuses to
            // publish a token at anything but `0600`, and it is the caller's silence that turned
            // "could not create a private file" into a CLI that simply finds no instance running and
            // says so. It goes to this application's own logger — the one whose level is set to
            // `.warning` where the application is built above, which `.error` clears.
            do {
                let url = try ControlEndpointFile.writeURL()
                try ControlEndpointFile.write(endpoint, to: url)
                // Recorded only after the write lands. `stop()` removes whatever this names, and a
                // path we failed to write is a path something else may own.
                endpointFileURL = url
            } catch {
                application.logger.error(
                    """
                    Mimic control plane is listening on 127.0.0.1:\(boundPort) but could not write \
                    its discovery file: \(error.localizedDescription) \
                    The CLI will not find this instance on its own — set \
                    \(ControlAPI.urlEnvironmentKey)=http://127.0.0.1:\(boundPort) to reach it.
                    """
                )
            }
        }

        return boundPort
    }

    public func stop() async throws {
        guard let running = app else { return }
        // Set before anything below can suspend, so an overlapping `start` cannot pass its guard
        // while this application is still holding the port.
        isStopping = true
        app = nil
        defer { isStopping = false }
        // Remove the advertisement first: a CLI must never be pointed at a port that is closing.
        if let endpointFileURL {
            ControlEndpointFile.remove(at: endpointFileURL)
            self.endpointFileURL = nil
        }
        await running.server.shutdown()
        try await running.asyncShutdown()
    }

    public var boundPort: Int? {
        app?.http.server.shared.localAddress?.port
    }

    // MARK: - Routes

    private func register(on application: Application) {
        let host = self.host
        let token = self.token
        let prefix = PathComponent(stringLiteral: ControlAPI.version)

        // Liveness. Cheap enough for a CLI to call before every command.
        application.get(prefix, "health") { request async -> Response in
            if let denial = Self.denial(for: request, token: token) { return denial }
            return await Self.encode(host.execute(.ping))
        }

        // The whole picture in one call: server, project, journey, counts.
        application.get(prefix, "state") { request async -> Response in
            if let denial = Self.denial(for: request, token: token) { return denial }
            return await Self.encode(host.execute(.state))
        }

        // Runtime self-description, so an agent can discover the surface it is talking to.
        application.get(prefix, "commands") { request async -> Response in
            if let denial = Self.denial(for: request, token: token) { return denial }
            return await Self.encode(host.execute(.describeCommands))
        }

        // Everything else. One route, one command vocabulary — see `ControlCommand`.
        //
        // The explicit cap is the whole reason this is `on(.POST, …)` rather than `post(…)`. Vapor's
        // default body strategy is `.collect(maxSize: nil)`, which resolves to
        // `Routes.defaultMaxBodySize` — **16 KB**. `projectImport` posts a whole `MockProject`,
        // captured response bodies and all, and those bodies are what make such a document big: one
        // endpoint holding a 1.4 KB captured response costs about 2 KB encoded — JSON escaping of the
        // body's own quotes is most of the difference — so 16 KB is roughly *eight endpoints*. The
        // fixture in `ControlServerTests.largeProjectImportIsAccepted` measures it.
        //
        // Past the limit, `Request.BodyStream.consume` fails the collect with
        // `Abort(.payloadTooLarge)` *before* this closure runs, so nothing here saw the request and the
        // caller got a 413 carrying Vapor's own `{"error":true,…}` instead of a `ControlResponse` —
        // which `ControlClient.send` reports as `http.413`, an exit-4 "Mimic refused it" that no
        // `ControlCommand` can produce and no error code explains.
        //
        // 4 MB rather than the 10 MB `VaporConfigurator` gives the mock server, because the two are
        // bounding different things: the engine has to absorb whatever the app under test uploads,
        // while everything that reaches this route is a document Mimic itself wrote. At the ~2 KB an
        // endpoint costs above, 4 MB is room for around two thousand of them — far past any project
        // somebody configured by hand, and 256 times what the default allowed.
        //
        // And it stays a bound rather than becoming a bigger round number, because `collect`
        // accumulates the entire body in memory before the handler is called, once per in-flight
        // request, in a process the user opened to mock an API rather than to run a server. Loopback
        // binding and the token keep the number of concurrent callers small; they are admission
        // control, not a memory limit, and the two are not substitutes.
        application.on(
            .POST, prefix, "command",
            body: .collect(maxSize: "4mb")
        ) { request async -> Response in
            if let denial = Self.denial(for: request, token: token) { return denial }
            // `request.body.string` rather than `Data(buffer:)`: the latter lives in
            // NIOFoundationCompat, and this project builds with member-import visibility enabled, so a
            // transitively-available initializer is not actually callable without importing it.
            guard let json = request.body.string else {
                return Self.encode(.failure(.invalid("Expected a JSON command body.")))
            }
            do {
                let command = try ControlCoding.decode(ControlCommand.self, from: Data(json.utf8))
                return await Self.encode(host.execute(command))
            } catch {
                return Self.encode(.failure(ControlError(
                    code: .undecodableRequest,
                    message: "Could not decode the command: \(error). "
                        + "Call GET \(ControlAPI.pathPrefix)/commands for the accepted shapes."
                )))
            }
        }
    }

    // MARK: - Admission

    /// The response to send instead of servicing this request, or `nil` to let it through.
    ///
    /// Every route goes through this, `health` included. A liveness probe that answered without a
    /// token would still confirm "a Mimic is running on this port with this pid" to anything that
    /// asked, and `health` returning `401` is just as good a liveness signal for the CLI.
    ///
    /// Applied in this order deliberately: the browser check first, so a web page gets an answer that
    /// names the real reason rather than a bare "bad token" it could mistake for something worth
    /// retrying.
    static func denial(for request: Request, token: String) -> Response? {
        guard isNonBrowserLoopbackRequest(request) else {
            return encode(.failure(.forbiddenOrigin), status: .forbidden)
        }
        guard ControlToken.matches(
            request.headers.first(name: ControlAPI.tokenHeaderName),
            expected: token
        ) else {
            return encode(.failure(.unauthorized), status: .unauthorized)
        }
        return nil
    }

    /// Rejects the two shapes a browser-driven attack takes.
    ///
    /// Binding to `127.0.0.1` keeps the network out but not the browser: a page the developer visits
    /// can post to a loopback port, and DNS rebinding can make that page same-origin with it. So:
    ///
    /// - **Any `Origin` header at all** is refused. A legitimate caller here is a CLI or a script, and
    ///   those do not send one. Only a browser does, and there is no origin this API wants to talk to.
    /// - **`Host` must be loopback.** Rebinding works by pointing an attacker-controlled *name* at
    ///   `127.0.0.1`; the request then arrives carrying that name in `Host`. Pinning `Host` to the
    ///   addresses this server actually binds is what breaks it.
    ///
    /// The token is the real defence and either check alone would be thin — a page cannot read a
    /// `0600` file. These make the browser path fail early and for a legible reason.
    static func isNonBrowserLoopbackRequest(_ request: Request) -> Bool {
        if request.headers.first(name: .origin) != nil { return false }
        guard let host = request.headers.first(name: .host) else {
            // HTTP/1.1 requires `Host`; HTTP/2 carries `:authority` instead and Vapor maps it here.
            // Absent entirely means a hand-rolled client, which is not a browser.
            return true
        }
        return isLoopbackAuthority(host)
    }

    /// `true` for `127.0.0.1`, `[::1]`, `localhost`, with or without a port.
    static func isLoopbackAuthority(_ authority: String) -> Bool {
        var value = authority.trimmingCharacters(in: .whitespaces).lowercased()

        // `[::1]:8787` — strip the bracketed literal first so the port split below cannot cut inside
        // an IPv6 address.
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return false }
            let literal = String(value[value.index(after: value.startIndex)..<end])
            return literal == "::1" || literal == "0:0:0:0:0:0:0:1"
        }

        // A bare IPv6 authority is not legal HTTP, but checking before the port split costs nothing
        // and avoids `::1` being truncated to `:` by it.
        if value == "::1" { return true }

        if let colon = value.lastIndex(of: ":") {
            value = String(value[value.startIndex..<colon])
        }
        return value == "127.0.0.1" || value == "localhost"
    }

    /// Serialises the envelope and maps the error code onto an HTTP status.
    ///
    /// The body is always the same envelope, so a caller can ignore the status entirely; the status
    /// exists so `curl --fail` and other tooling behave sensibly without parsing JSON.
    static func encode(_ response: ControlResponse, status explicitStatus: HTTPResponseStatus? = nil) -> Response {
        let status = explicitStatus ?? httpStatus(for: response)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")

        guard let data = try? ControlCoding.encoder(pretty: true).encode(response) else {
            // Written out by hand because the encoder is the thing that just failed. The code is
            // still read from the vocabulary rather than typed again here, so a caller branching on
            // `internal.encoding` is branching on the same string every other code comes from.
            let code = ControlErrorCode.encodingFailure.rawValue
            return Response(
                status: .internalServerError,
                headers: headers,
                body: .init(
                    string: #"{"ok":false,"error":{"code":"\#(code)","message":"Could not encode the response."}}"#
                )
            )
        }
        return Response(status: status, headers: headers, body: .init(data: data))
    }

    /// Maps a failure onto the status a `curl --fail` caller sees.
    ///
    /// Over ``ControlErrorCode`` rather than over strings, and that is the point rather than a
    /// tidy-up: this switch used to hold its own copies of eight of Domain's code literals, so
    /// renaming one there left this arm matching a string nothing produces any more and the code fell
    /// through to `500` — the one answer indistinguishable from Mimic having broken. Both ends now
    /// read the same `rawValue`.
    static func httpStatus(for response: ControlResponse) -> HTTPResponseStatus {
        guard let code = response.error?.code else { return .ok }
        guard let declared = ControlErrorCode(rawValue: code) else {
            // A code from outside Domain's vocabulary. `ControlError` takes an arbitrary string —
            // `ControlClient` builds `http.502` that way — so the suffix rule stays, as the one thing
            // that keeps a `<subject>.notFound` spelled somewhere else answering `404` and not `500`.
            return code.hasSuffix(".notFound") ? .notFound : .internalServerError
        }
        // No `default`, deliberately: a code added to `ControlErrorCode` fails this build until
        // somebody has said what a script should see for it. The switch it replaces could not do
        // that — every unhandled string was already spelled `internalServerError`.
        switch declared {
        case .unauthorized:
            return .unauthorized
        case .forbiddenOrigin:
            return .forbidden
        case .invalidRequest, .undecodableRequest:
            return .badRequest
        case .projectNotFound, .endpointNotFound, .scenarioNotFound, .journeyNotFound,
             .journeyStepNotFound, .journeyTemplateNotFound:
            return .notFound
        case .noProjectOpen, .noActiveJourney, .serverPortInUse, .serverBusy:
            // The request was well formed but the instance is not in a state to satisfy it.
            return .conflict
        case .serverStartFailed, .persistenceFailure, .internalFailure, .encodingFailure:
            return .internalServerError
        }
    }
}

public enum ControlServerError: Error, Sendable, LocalizedError, Equatable {
    case alreadyRunning
    /// A `start` that arrived while `stop` was still closing the previous application.
    case shuttingDown
    case portInUse(port: Int)

    public var errorDescription: String? {
        switch self {
        case .alreadyRunning: "The control server is already running."
        case .shuttingDown: "The control server is shutting down; try again in a moment."
        case let .portInUse(port): "Control port \(port) is already in use."
        }
    }
}
