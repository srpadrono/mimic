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

    /// Project-import commands carry captured bodies, but still need a finite collection limit.
    static let commandBodyLimit = 4 << 20

    private let host: any ControlHost
    private let mode: String
    private var app: Application?
    private var isStarting = false
    /// The other half of the `isStarting` guard. `stop()` clears `app` before it awaits the
    /// shutdown, so `app == nil` does not distinguish "never started" from "still closing".
    private var isStopping = false
    private var stopRequestedDuringStart = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var endpointFileURL: URL?
    private var advertisedEndpoint: ControlEndpoint?

    #if DEBUG
    private var beforeBindingForTesting: (@Sendable () async -> Void)?
    private var onStopAcceptedForTesting: (@Sendable () -> Void)?
    private var advertisementURLForTesting: URL?

    func setBeforeBindingForTesting(_ action: @escaping @Sendable () async -> Void) {
        beforeBindingForTesting = action
    }

    func setOnStopAcceptedForTesting(_ action: @escaping @Sendable () -> Void) {
        onStopAcceptedForTesting = action
    }

    func setAdvertisementURLForTesting(_ url: URL) {
        advertisementURLForTesting = url
    }
    #endif

    /// This instance's token. Fresh per process; see ``ControlToken``.
    public let token: String

    public init(host: any ControlHost, mode: String = "headless", token: String? = nil) {
        self.host = host
        self.mode = mode
        // An explicit token exists for the case where the caller must know it before the server
        // binds — `MIMIC_CONTROL_TOKEN` set by a CI job that configures both sides.
        self.token = (token ?? ProcessInfo.processInfo.environment[ControlAPI.tokenEnvironmentKey]).flatMap {
            $0.isEmpty ? nil : $0
        } ?? ControlToken.generate()
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
        // `stop()` clears `app` before it awaits shutdown, and can also wait for a pending startup.
        // In both cases a new start should retry after shutdown, not mistake this for an already
        // active server.
        guard !isStopping else { throw ControlServerError.shuttingDown }
        guard app == nil, !isStarting else { throw ControlServerError.alreadyRunning }
        if port != 0 { try EndpointValidator.validatePort(port) }
        isStarting = true
        defer {
            isStarting = false
            stopRequestedDuringStart = false
            let waiters = startWaiters
            startWaiters.removeAll()
            for waiter in waiters { waiter.resume() }
        }

        let env = Environment(name: "production", arguments: ["vapor"])
        let application = try await Application.make(env)
        if stopRequestedDuringStart {
            try? await application.asyncShutdown()
            throw ControlServerError.shuttingDown
        }
        application.logger.logLevel = .warning
        application.http.server.configuration.hostname = "127.0.0.1"
        application.http.server.configuration.port = port

        register(on: application)

        #if DEBUG
        if let beforeBindingForTesting { await beforeBindingForTesting() }
        #endif
        if stopRequestedDuringStart {
            try? await application.asyncShutdown()
            throw ControlServerError.shuttingDown
        }

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

        if stopRequestedDuringStart {
            await application.server.shutdown()
            try? await application.asyncShutdown()
            throw ControlServerError.shuttingDown
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
                #if DEBUG
                let url = try advertisementURLForTesting ?? ControlEndpointFile.writeURL()
                #else
                let url = try ControlEndpointFile.writeURL()
                #endif
                try ControlEndpointFile.write(endpoint, to: url)
                // Recorded only after the write lands. `stop()` removes this instance's exact
                // advertisement; a path we failed to write is a path something else may own.
                endpointFileURL = url
                advertisedEndpoint = endpoint
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
        guard app != nil || isStarting else { return }
        guard !isStopping else { return }
        // This guard also covers the first await in `start`: while it is still making or binding an
        // application, `app` is nil. Wait for that start to finish after requesting its shutdown,
        // and reject any new start until the old one has finished closing.
        isStopping = true
        defer { isStopping = false }
        if isStarting {
            stopRequestedDuringStart = true
            #if DEBUG
            onStopAcceptedForTesting?()
            #endif
            await withCheckedContinuation { continuation in
                startWaiters.append(continuation)
            }
        }
        guard let running = app else { return }
        app = nil
        // Remove the advertisement first: a CLI must never be pointed at a port that is closing.
        if let endpointFileURL, let advertisedEndpoint {
            ControlEndpointFile.remove(expected: advertisedEndpoint, at: endpointFileURL)
        }
        endpointFileURL = nil
        advertisedEndpoint = nil
        await running.server.shutdown()
        try await running.asyncShutdown()
    }

    public var boundPort: Int? {
        app?.http.server.shared.localAddress?.port
    }

    /// The exact discovery record and path this server published, if publication succeeded.
    public var advertisement: (endpoint: ControlEndpoint, url: URL)? {
        guard let advertisedEndpoint, let endpointFileURL else { return nil }
        return (advertisedEndpoint, endpointFileURL)
    }

    // MARK: - Routes

    private func register(on application: Application) {
        let host = self.host
        let prefix = PathComponent(stringLiteral: ControlAPI.version)
        // Middleware runs before each route's body collector, including GET and unknown routes.
        application.middleware.use(ControlAdmissionMiddleware(token: token))

        // Liveness. Cheap enough for a CLI to call before every command.
        application.get(prefix, "health") { request async -> Response in
            return await Self.encode(host.execute(.ping))
        }

        // The whole picture in one call: server, project, journey, counts.
        application.get(prefix, "state") { request async -> Response in
            return await Self.encode(host.execute(.state))
        }

        // Runtime self-description, so an agent can discover the surface it is talking to.
        application.get(prefix, "commands") { request async -> Response in
            return await Self.encode(host.execute(.describeCommands))
        }

        // One route, one command vocabulary. The 4 MiB cap permits realistic project imports
        // while bounding each route collection; admission happens before that collector. Bodies
        // Vapor already buffered are checked too, though their allocation has already happened.
        application.on(
            .POST, prefix, "command",
            body: .collect(maxSize: .init(value: Self.commandBodyLimit))
        ) { request async -> Response in
            guard request.body.data != nil else {
                return Self.encode(.failure(.invalid("Expected a JSON command body.")))
            }
            do {
                // Decode the original bytes. Request.Body.string repairs malformed UTF-8 and
                // could silently turn a damaged upload into a different valid command.
                let command = try request.content.decode(ControlCommand.self, using: ControlCoding.decoder())
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
        let tokens = request.headers[ControlAPI.tokenHeaderName]
        guard tokens.count == 1, ControlToken.matches(
            tokens.first,
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
        let hosts = request.headers["Host"]
        guard let host = hosts.first else {
            // HTTP/1.1 requires `Host`; HTTP/2 carries `:authority` instead and Vapor maps it here.
            // Absent entirely means a hand-rolled client, which is not a browser.
            return true
        }
        return hosts.count == 1 && isLoopbackAuthority(host)
    }

    /// `true` for `127.0.0.1`, `[::1]`, `localhost`, with or without a numeric port.
    static func isLoopbackAuthority(_ authority: String) -> Bool {
        let value = authority.trimmingCharacters(in: .whitespaces).lowercased()

        // `[::1]:8787` — strip the bracketed literal first so the port split below cannot cut inside
        // an IPv6 address.
        if value.hasPrefix("[") {
            guard let end = value.firstIndex(of: "]") else { return false }
            let literal = String(value[value.index(after: value.startIndex)..<end])
            let suffix = value[value.index(after: end)...]
            return (literal == "::1" || literal == "0:0:0:0:0:0:0:1")
                && hasValidOptionalPort(suffix)
        }

        // A bare IPv6 authority is not legal HTTP, but checking before the port split costs nothing
        // and avoids `::1` being truncated to `:` by it.
        if value == "::1" { return true }

        let host = value.prefix { $0 != ":" }
        let suffix = value.dropFirst(host.count)
        return (host == "127.0.0.1" || host == "localhost")
            && hasValidOptionalPort(suffix)
    }

    private static func hasValidOptionalPort(_ suffix: Substring) -> Bool {
        if suffix.isEmpty { return true }
        guard suffix.first == ":" else { return false }
        let port = suffix.dropFirst()
        return !port.isEmpty
            && port.allSatisfy { $0.isASCII && $0.isNumber }
            && UInt16(port) != nil
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
        case .updateCheckFailed:
            // Mimic answered; the service it had to ask did not. 502 rather than 500 so a
            // `curl --fail` caller can tell "the release feed is unreachable" apart from "this
            // instance is broken" — the retry is worth making for one and not for the other.
            return .badGateway
        case .serverStartFailed, .persistenceFailure, .internalFailure, .encodingFailure:
            return .internalServerError
        }
    }
}

/// Authenticate before Vapor collects a body, then keep collection failures in the control wire
/// format. Requests that already arrived in one buffer bypass Vapor's streaming size check.
private struct ControlAdmissionMiddleware: AsyncMiddleware {
    let token: String

    func respond(to request: Request, chainingTo next: AsyncResponder) async throws -> Response {
        if let denial = ControlServer.denial(for: request, token: token) {
            return finishEarly(denial, for: request)
        }
        if let length = request.headers.first(name: .contentLength).flatMap(Int.init),
           length > ControlServer.commandBodyLimit {
            return finishEarly(oversizedBody(), for: request)
        }
        if let body = request.body.data, body.readableBytes > ControlServer.commandBodyLimit {
            return oversizedBody()
        }
        do {
            return try await next.respond(to: request)
        } catch let error as AbortError where error.status == .payloadTooLarge {
            return finishEarly(oversizedBody(), for: request)
        }
    }

    /// Vapor derives keep-alive from the incoming request, so a Connection: close response alone
    /// does not stop a refused upload. Flush the complete response before ending its stream with
    /// an error; Vapor then closes the channel and releases the unfinished request stream.
    private func finishEarly(_ response: Response, for request: Request) -> Response {
        guard request.body.data == nil,
              request.headers.first(name: .transferEncoding) != nil
                || (request.headers.first(name: .contentLength).flatMap(Int.init) ?? 0) > 0,
              let responseBuffer = response.body.buffer else { return response }
        let wasHead = request.method == .HEAD
        let body = wasHead ? request.byteBufferAllocator.buffer(capacity: 0) : responseBuffer
        if wasHead {
            // Vapor skips HEAD stream callbacks. Keep the wire body empty while allowing the
            // callback that closes this rejected upload to run.
            request.method = .GET
        }
        response.body = .init(stream: { writer in
            let flushed = writer.eventLoop.makePromise(of: Void.self)
            writer.write(.buffer(body), promise: flushed)
            flushed.futureResult.whenComplete { _ in
                writer.write(.error(RejectedControlUpload()), promise: nil)
            }
        }, count: body.readableBytes)
        if wasHead {
            response.headers.replaceOrAdd(name: .contentLength, value: String(responseBuffer.readableBytes))
        }
        response.headers.replaceOrAdd(name: .connection, value: "close")
        return response
    }

    private func oversizedBody() -> Response {
        ControlServer.encode(
            .failure(.invalid("Request body exceeds the allowed size limit.")),
            status: .payloadTooLarge
        )
    }
}

private struct RejectedControlUpload: Error { }

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
