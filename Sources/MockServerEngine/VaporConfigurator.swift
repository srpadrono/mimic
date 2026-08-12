import Vapor
import Domain

private typealias DomainHTTPMethod = Domain.HTTPMethod

enum VaporConfigurator {
    /// Every request Mimic answers arrives here, whatever its path.
    ///
    /// Registering routes is the *only* thing Vapor decides; what to serve is Domain's answer via
    /// `MockResolver.plan`, and everything that reaches this closure is logged — including the
    /// requests nothing is configured for. A path Vapor answers itself is a path Mimic cannot see.
    static func registerRoutes(
        on app: Application,
        routeStore: MockRouteStore,
        logContinuation: AsyncStream<RequestLog>.Continuation
    ) {
        let handler: @Sendable (Request) async throws -> Response = { req in
            let incoming = IncomingRequest(
                method: DomainHTTPMethod(rawValue: req.method.rawValue) ?? .get,
                path: req.url.path,
                headers: Dictionary(
                    req.headers.map { ($0.name, $0.value) },
                    uniquingKeysWith: { _, last in last }
                ),
                body: req.body.string
            )

            // One actor hop resolves the request *and* advances the journey cursor, so
            // concurrent requests can never consume the same step.
            let resolved = await routeStore.resolve(request: incoming)

            logContinuation.yield(makeLog(incoming: incoming, resolved: resolved))

            if let failure = resolved.failure {
                // Hold *before* anything is written, so a timeout step sends the client nothing
                // at all — not headers-then-silence. A client's inactivity timer is meant to be
                // what ends the request.
                let holdMs = holdMilliseconds(for: failure, delayMs: resolved.delayMs)
                if holdMs > 0 {
                    try? await Task.sleep(for: .milliseconds(holdMs))
                }
                return abortedResponse(for: failure)
            }

            // Apply the effective delay (global + per-endpoint or per-step) before answering.
            if resolved.delayMs > 0 {
                try? await Task.sleep(for: .milliseconds(resolved.delayMs))
            }

            return response(for: resolved)
        }

        let methods: [Vapor.HTTPMethod] = [.GET, .POST, .PUT, .PATCH, .DELETE, .OPTIONS, .HEAD]
        for method in methods {
            for path in interceptAllPaths {
                app.on(method, path, body: .collect(maxSize: "10mb"), use: handler)
            }
        }
    }

    /// The two registrations it takes to see *every* request, root included.
    ///
    /// `**` alone does not cover `/`. RoutingKit records a catchall only while walking the request's
    /// path components (`TrieRouter.route`), and Vapor derives those with
    /// `request.url.path.split(separator: "/")` — which for `/` is empty. The walk therefore never
    /// runs, the search ends on the method node with no output and no remembered catchall, and Vapor's
    /// own error middleware answers `{"error":true,"reason":"Not Found"}` as JSON.
    ///
    /// That was the bug, and its second half was the expensive one: because Mimic's handler was never
    /// invoked, a request to `/` produced no `RequestLog` — it was missing from the traffic list *and*
    /// from the unmatched count, so the window quietly under-reported what had arrived. The empty path
    /// registers the route on the method node itself, which is exactly where the root walk terminates.
    ///
    /// This is a routing fix, not a matching one: `PathPattern` already normalises `/` and `""` to the
    /// same zero segments, so Domain matches a root endpoint correctly the moment it is asked.
    static let interceptAllPaths: [[PathComponent]] = [[], [.catchall]]

    // MARK: - Responses

    static func response(for resolved: ResolvedResponse) -> Response {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: resolved.contentType.rawValue)
        for (key, value) in resolved.headers {
            // Dropped rather than rejected: by the time a request is being answered, the caller is
            // the app under test, and failing its request tells the developer nothing about the
            // scenario that is actually malformed. The validators on the editing and import paths are
            // where a bad header gets a real error message; this is the backstop for a value that
            // reached the store some other way (an older project file, a hand-edited document).
            guard EndpointValidator.isValidHeader(name: key, value: value) else { continue }
            // `replaceOrAdd`, not `add`: a scenario or journey step that sets its own Content-Type
            // must win outright. Appending would emit the header twice and leave the client to guess.
            headers.replaceOrAdd(name: key, value: value)
        }
        return Response(
            status: HTTPResponseStatus(statusCode: clampedStatusCode(resolved.statusCode)),
            headers: headers,
            body: resolved.body.map { .init(string: $0) } ?? .empty
        )
    }

    /// Forces a status into the range a response can actually be completed with.
    ///
    /// Two separate crashes live under this one line. `HTTPResponseStatus(statusCode:)` funnels
    /// anything it does not recognise into `.custom(code: UInt(statusCode))`, and `UInt(_: Int)`
    /// *traps* on a negative value. And a 1xx is informational: NIO's server pipeline does not move
    /// past `.head` for one, so the body that follows fails an assertion. Because the engine is
    /// embedded, neither is a failed request — both are the whole app disappearing, unsaved edits
    /// included.
    ///
    /// The validators reject both on the way in; this is the backstop for a value that reached the
    /// store some other way, and it is what makes the crash unreachable rather than merely unlikely.
    static func clampedStatusCode(_ code: Int) -> Int {
        min(max(code, EndpointValidator.serveableStatusCodes.lowerBound), EndpointValidator.serveableStatusCodes.upperBound)
    }

    /// How long to stay silent before tearing the connection down.
    ///
    /// A dropped connection is immediate (bar any configured artificial delay); a timeout is
    /// deliberately long, because the behaviour under test is the *client* giving up.
    static func holdMilliseconds(for failure: NetworkFailure, delayMs: Int) -> Int {
        switch failure {
        case .connectionDrop:
            max(0, delayMs)
        case let .timeout(timeoutHoldMs):
            max(0, delayMs) + max(0, timeoutHoldMs)
        }
    }

    /// A response that is torn down instead of completed.
    ///
    /// The body is declared as a stream of unknown length, so the head goes out with
    /// `Transfer-Encoding: chunked` and the connection then closes without the terminating chunk. A
    /// client sees a truncated, unusable response and its read fails — which is the point: an HTTP
    /// 500 is a *reply*, and a torn connection exercises the retry and offline paths a status code
    /// can never reach.
    ///
    /// This is as close to a dropped socket as a route handler can get without reaching past Vapor
    /// into the NIO channel. Note that clients are free to retry a failed idempotent request, and
    /// each attempt is a new request as far as the journey is concerned: give a failure step a
    /// `repeatCount` above 1 when a drop needs to survive a client's own retry.
    static func abortedResponse(for failure: NetworkFailure) -> Response {
        let body = Response.Body(stream: { writer in
            _ = writer.write(.error(SimulatedNetworkFailure(failure: failure)))
        }, count: -1)

        return Response(status: .ok, headers: HTTPHeaders(), body: body)
    }

    /// Marker error used to abort a body stream. Never surfaces to a client as text — writing it
    /// tears the response down, which is the whole point.
    struct SimulatedNetworkFailure: Error, CustomStringConvertible {
        let failure: NetworkFailure

        var description: String {
            switch failure {
            case .connectionDrop: "Mimic simulated a dropped connection."
            case let .timeout(holdMs): "Mimic simulated a \(holdMs)ms timeout."
            }
        }
    }

    // MARK: - Logging

    static func makeLog(incoming: IncomingRequest, resolved: ResolvedResponse) -> RequestLog {
        // A failed request wrote no body, so recording the scenario's would be a fiction.
        let (body, truncated) = resolved.failure == nil
            ? RequestLog.cappedBody(resolved.body)
            : (nil, false)

        // The request body is capped on the same terms as the response. It arrives up to the route's
        // 10 MB collect limit and the log holds a thousand entries, so an uncapped one is the larger
        // of the two exposures — a client posting big payloads grows the log without bound.
        let (requestBody, _) = RequestLog.cappedBody(incoming.body)

        return RequestLog(
            method: incoming.method,
            path: incoming.path,
            requestHeaders: incoming.headers,
            requestBody: requestBody,
            matchedEndpointID: resolved.matchedEndpointID,
            matchedScenarioID: resolved.matchedScenarioID,
            // A failed request never produced a status; recording one would be a lie the request log
            // then repeats to every reader.
            //
            // The same reasoning is why the status is the *clamped* one. `response(for:)` clamps on
            // the way to the wire and this line used to log the configured value, so a scenario
            // carrying 0 or 999 served 200 or 599 while the traffic list reported 0 or 999 — the two
            // halves of one request disagreeing, with the log being the half that is still readable
            // after the request is over.
            responseStatusCode: resolved.failure == nil ? clampedStatusCode(resolved.statusCode) : nil,
            // Mirrors what `response(for:)` writes: the content type first, then any header the
            // scenario or step set — so the log shows the headers the client actually received.
            responseHeaders: resolved.failure == nil ? loggedResponseHeaders(resolved) : [:],
            responseBody: body,
            responseBodyTruncated: truncated,
            matchedJourneyID: resolved.matchedJourneyID,
            matchedJourneyStepID: resolved.matchedJourneyStepID,
            failureLabel: failureLabel(for: resolved.failure),
            outcome: resolved.outcome
        )
    }

    /// The headers a client received, in the same precedence the response builder applies — and
    /// subject to the same validity check, which this used to skip.
    ///
    /// `response(for:)` drops a header that fails `EndpointValidator.isValidHeader` rather than
    /// writing it, so a scenario carrying `"X-Test": "a\r\nSet-Cookie: evil=1"` put nothing on the
    /// wire while the log listed it among the headers the client received. That is the worst kind of
    /// wrong for this panel: a developer reads the log precisely because they cannot see the wire,
    /// and here it invented a header and hid the fact that Mimic had refused to send one.
    static func loggedResponseHeaders(_ resolved: ResolvedResponse) -> [String: String] {
        var headers = ["Content-Type": resolved.contentType.rawValue]
        for (key, value) in resolved.headers {
            guard EndpointValidator.isValidHeader(name: key, value: value) else { continue }
            headers[key] = value
        }
        return headers
    }

    static func failureLabel(for failure: NetworkFailure?) -> String? {
        switch failure {
        case .none: nil
        case .connectionDrop: "connection-drop"
        case let .timeout(holdMs): "timeout(\(holdMs)ms)"
        }
    }

    /// Rethrow a raw NIO/POSIX bind error as MockServerError.portInUse when appropriate.
    static func mapStartError(_ error: Error, port: Int) -> Error {
        let desc = String(describing: error).lowercased()
        if desc.contains("address already in use") || desc.contains("eaddrinuse") {
            return MockServerError.portInUse(port: port)
        }
        return error
    }
}
