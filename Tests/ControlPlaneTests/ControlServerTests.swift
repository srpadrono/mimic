import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import ControlPlane
@testable import Domain

/// The HTTP surface, exercised the way a `curl`-driven script or a non-Swift agent would.
///
/// The host behind the server is ``LoopbackTestHost``, a fixture at the bottom of this file — not a
/// production host. These tests used to stand `ControlServer` on `MimicControlService`, the
/// self-contained headless service, until the owner resolved the two-host fork by deleting it (see
/// "One host" in AGENTS.md). What this suite covers is `ControlServer` itself — authentication,
/// Host pinning, error→status mapping, body limits, loopback binding, the wire encoding — and for
/// that it needs *a* host, not *the* host: the shipped host's behaviour has its own suite in
/// `MimicTests`, driven directly rather than over a socket.
///
/// Time-limited because every case here binds a real socket: a bind that never completes, or a
/// wait on traffic that never arrives, otherwise hangs the whole run with no indication of which
/// test is stuck. A minute is the finest granularity `.timeLimit` offers and is far above what
/// any of these needs — the point is a bound, not a deadline.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ControlServerTests {

    /// The token the test server was started with.
    ///
    /// Carried in a task local rather than threaded through every helper: the helpers are called from
    /// dozens of places, and the token is ambient to "the server this test is talking to" in exactly
    /// the way a task local models. A helper that is called with no server running sends no token,
    /// which is what the unauthenticated tests want.
    @TaskLocal static var currentToken: String?

    static func withServer(
        _ body: (URL, LoopbackTestHost) async throws -> Void
    ) async throws {
        let host = LoopbackTestHost()
        // An explicit token keeps the suite independent of `MIMIC_CONTROL_TOKEN` in the environment.
        let server = ControlServer(host: host, mode: "headless", token: ControlToken.generate())
        // Port 0 lets the OS pick, and `advertise: false` keeps the test from overwriting a real
        // instance's discovery file.
        let port = try await server.start(port: 0, advertise: false)
        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))

        do {
            try await Self.$currentToken.withValue(server.token) {
                try await body(baseURL, host)
            }
        } catch {
            try? await server.stop()
            throw error
        }
        try await server.stop()
    }

    struct Reply {
        let status: Int
        let response: ControlResponse
    }

    static func get(_ path: String, baseURL: URL, token: String? = currentToken) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await send(request, token: token)
    }

    static func post(
        _ command: ControlCommand,
        baseURL: URL,
        token: String? = currentToken
    ) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlCoding.encoder().encode(command)
        return try await send(request, token: token)
    }

    static func postRaw(
        _ json: String,
        baseURL: URL,
        token: String? = currentToken
    ) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(json.utf8)
        return try await send(request, token: token)
    }

    private static func send(_ request: URLRequest, token: String?) async throws -> Reply {
        var request = request
        if let token {
            request.setValue(token, forHTTPHeaderField: ControlAPI.tokenHeaderName)
        }
        let session = URLSession(configuration: .ephemeral)
        let (data, response) = try await session.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let decoded = try ControlCoding.decode(ControlResponse.self, from: data)
        return Reply(status: http.statusCode, response: decoded)
    }

    // MARK: - Reads

    @Test("Health, state, and the command catalog are plain GETs")
    func readEndpoints() async throws {
        try await Self.withServer { baseURL, _ in
            let health = try await Self.get("\(ControlAPI.version)/health", baseURL: baseURL)
            #expect(health.status == 200)
            #expect(health.response.ok)

            let state = try await Self.get("\(ControlAPI.version)/state", baseURL: baseURL)
            #expect(state.status == 200)
            #expect(state.response.result?.state?.apiVersion == ControlAPI.version)

            let commands = try await Self.get("\(ControlAPI.version)/commands", baseURL: baseURL)
            #expect(commands.status == 200)
            #expect(commands.response.result?.commands?.count == CommandCatalog.descriptors.count)
        }
    }

    // MARK: - Commands

    @Test("A whole flow can be driven over HTTP alone")
    func driveAFlowOverHTTP() async throws {
        try await Self.withServer { baseURL, _ in
            #expect(try await Self.post(.projectCreate(name: "Checkout", port: 9500), baseURL: baseURL).status == 200)
            #expect(try await Self.post(
                .journeyAddTemplate(templateID: "retry-after-failure", name: "Flow"),
                baseURL: baseURL
            ).status == 200)

            let activated = try await Self.post(.journeyActivate(journey: .name("Flow")), baseURL: baseURL)
            #expect(activated.status == 200)
            #expect(activated.response.result?.journeyStatus?.totalSteps == 4)

            let status = try await Self.post(.journeyStatus, baseURL: baseURL)
            #expect(status.response.result?.journeyStatus?.currentStepIndex == 0)
        }
    }

    // MARK: - Status mapping

    @Test("Error codes map onto HTTP statuses so curl --fail behaves sensibly")
    func errorsMapToStatuses() async throws {
        try await Self.withServer { baseURL, _ in
            // Precondition not met.
            let noProject = try await Self.post(.endpointList, baseURL: baseURL)
            #expect(noProject.status == 409)
            #expect(noProject.response.error?.code == "project.noneOpen")

            try await Self.post(.projectCreate(name: "Checkout", port: nil), baseURL: baseURL)

            // Not found.
            let missing = try await Self.post(.endpointGet(endpoint: .route(.get, "/nope")), baseURL: baseURL)
            #expect(missing.status == 404)
            #expect(missing.response.error?.code == "endpoint.notFound")

            // Bad request.
            let invalid = try await Self.post(
                .endpointCreate(name: nil, method: .get, path: "no-slash", spec: nil),
                baseURL: baseURL
            )
            #expect(invalid.status == 400)
            #expect(invalid.response.error?.code == "request.invalid")
        }
    }

    // MARK: - Lifecycle reentrancy

    /// `stop()` clears `app` and *then* awaits the shutdown, and an actor admits another call at that
    /// suspension. So the eight lines of reasoning above `start`'s first guard — written for two
    /// overlapping *starts* — left the same window open from the other end: a start arriving mid-stop
    /// saw `app == nil`, passed, and bound a port the outgoing application had not released.
    ///
    /// The window is a real race, so what is asserted is the outcome *set* rather than one ordering.
    /// Whichever way the two land, the racing start must not come back as `portInUse`: the three
    /// answers it may now give are `alreadyRunning` (it reached the actor first), `shuttingDown` (it
    /// landed inside the window), and success (the stop had already finished). Nothing here can force
    /// the interesting ordering — `Task.yield()` and the repeat count only make it likely — and a test
    /// that only passed when it happened would be a flake in the other direction.
    @Test("A start racing a stop on the control port is never told the port is in use")
    func startDuringStopIsRefusedRatherThanColliding() async throws {
        let host = LoopbackTestHost()

        for attempt in 1...3 {
            let server = ControlServer(host: host, mode: "headless", token: ControlToken.generate())
            // `advertise: false` throughout: a discovery file here would overwrite a real instance's.
            let port = try await server.start(port: 0, advertise: false)

            let stopping = Task { try await server.stop() }
            await Task.yield()

            var raced: (any Error)?
            do {
                _ = try await server.start(port: port, advertise: false)
            } catch {
                raced = error
            }
            _ = try? await stopping.value

            #expect(
                raced as? ControlServerError != .portInUse(port: port),
                "attempt \(attempt): a start racing a stop reported the control port in use"
            )
            try? await server.stop()
        }
    }

    /// The two refusals name different problems, and the difference is what the caller does next:
    /// `alreadyRunning` means "you already have one", `shuttingDown` means "ask again in a moment".
    /// Reporting the second as the first is what sent `ControlPlaneCoordinator` down the
    /// give-up-entirely path for a condition that clears itself.
    @Test("The two control-server refusals do not say the same thing")
    func controlServerRefusalsAreDistinguishable() {
        #expect(ControlServerError.alreadyRunning != ControlServerError.shuttingDown)
        #expect(
            ControlServerError.alreadyRunning.errorDescription
                != ControlServerError.shuttingDown.errorDescription
        )
        #expect(ControlServerError.shuttingDown.errorDescription?.contains("shutting down") == true)
    }

    @Test("An undecodable body is a 400 that says what to read next")
    func undecodableBody() async throws {
        try await Self.withServer { baseURL, _ in
            let reply = try await Self.postRaw(#"{"notACommand":{}}"#, baseURL: baseURL)
            #expect(reply.status == 400)
            #expect(reply.response.error?.code == "request.undecodable")
            #expect(reply.response.error?.message.contains("/commands") == true)
        }
    }

    @Test("A hand-written command body works, which is what an agent using curl will send")
    func handWrittenJSON() async throws {
        try await Self.withServer { baseURL, _ in
            try await Self.postRaw(#"{"projectCreate":{"name":"Hand written","port":9600}}"#, baseURL: baseURL)
            let reply = try await Self.postRaw(
                #"{"endpointCreate":{"method":"POST","path":"/login","name":"Login"}}"#,
                baseURL: baseURL
            )
            #expect(reply.status == 200)
            #expect(reply.response.result?.endpoint?.name == "Login")

            let journey = try await Self.postRaw(
                """
                {"journeyCreate":{"name":"Hand flow","spec":{"steps":[
                  {"method":"POST","path":"/login","statusCode":200},
                  {"method":"GET","path":"/inbox","failure":{"connectionDrop":{}}}
                ]}}}
                """,
                baseURL: baseURL
            )
            #expect(journey.status == 200)
            #expect(journey.response.result?.journey?.steps.count == 2)
            #expect(journey.response.result?.journey?.steps[1].outcome == .networkFailure(.connectionDrop))
        }
    }

    @Test("The server binds loopback only, never a routable interface")
    func bindsLoopbackOnly() async throws {
        try await Self.withServer { baseURL, _ in
            let port = try #require(baseURL.port)

            // Loopback is the contract, so it has to work.
            #expect(try await Self.get("\(ControlAPI.version)/health", baseURL: baseURL).status == 200)

            // And the same port must not answer on an address another machine could route to.
            // Probing `0.0.0.0` does not test that: Linux treats it as a destination meaning "this
            // host", so the request succeeds there even when the bind really is loopback-only. The
            // honest probe is the machine's own external address.
            guard let routable = Self.routableIPv4Address() else {
                // An isolated container has no external interface, so there is nothing to prove.
                return
            }
            var request = URLRequest(url: try #require(URL(string: "http://\(routable):\(port)/\(ControlAPI.version)/health")))
            request.timeoutInterval = 2
            let session = URLSession(configuration: .ephemeral)
            await #expect(throws: (any Error).self) {
                _ = try await session.data(for: request)
            }
        }
    }

    // MARK: - Admission control

    @Test("Every route refuses a caller with no token")
    func tokenIsRequiredOnEveryRoute() async throws {
        try await Self.withServer { baseURL, _ in
            for path in ["health", "state", "commands"] {
                let reply = try await Self.get("\(ControlAPI.version)/\(path)", baseURL: baseURL, token: nil)
                #expect(reply.status == 401, "GET /\(path) answered without a token")
                #expect(reply.response.error?.code == "request.unauthorized")
            }

            // The one that mutates matters most: this is the shape a hostile local process sends.
            let command = try await Self.post(
                .projectCreate(name: "unauthorised", port: nil),
                baseURL: baseURL,
                token: nil
            )
            #expect(command.status == 401)
            #expect(command.response.error?.code == "request.unauthorized")
        }
    }

    @Test("A wrong token is refused, and the refusal does not echo the real one")
    func wrongTokenIsRefused() async throws {
        try await Self.withServer { baseURL, _ in
            let real = try #require(Self.currentToken)
            let reply = try await Self.post(.state, baseURL: baseURL, token: "not-the-token")
            #expect(reply.status == 401)
            #expect(reply.response.error?.message.contains(real) == false)

            // A prefix of the real token must not pass: the comparison is length-checked before the
            // byte loop, so a truncated token can never compare equal.
            let truncated = String(real.dropLast())
            #expect(try await Self.post(.state, baseURL: baseURL, token: truncated).status == 401)
        }
    }

    @Test("A request carrying a browser Origin is refused even with the right token")
    func browserOriginIsRefused() async throws {
        try await Self.withServer { baseURL, _ in
            var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/state"))
            request.httpMethod = "GET"
            request.setValue(Self.currentToken, forHTTPHeaderField: ControlAPI.tokenHeaderName)
            request.setValue("https://evil.example", forHTTPHeaderField: "Origin")

            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let decoded = try ControlCoding.decode(ControlResponse.self, from: data)

            #expect(http.statusCode == 403)
            #expect(decoded.error?.code == "request.forbiddenOrigin")
        }
    }

    @Test("Loopback Host values are accepted and rebinding names are not")
    func hostHeaderPinning() {
        for accepted in ["127.0.0.1", "127.0.0.1:8787", "localhost", "localhost:8787", "[::1]", "[::1]:8787", "::1"] {
            #expect(ControlServer.isLoopbackAuthority(accepted), "\(accepted) should be accepted")
        }
        // The rebinding shape: an attacker-controlled name resolving to 127.0.0.1.
        for refused in ["mimic.evil.example", "evil.example:8787", "0.0.0.0", "192.168.1.10:8787", "[2001:db8::1]"] {
            #expect(ControlServer.isLoopbackAuthority(refused) == false, "\(refused) should be refused")
        }
    }

    @Test("The response carries no CORS grant, so a browser cannot read it either")
    func noCORSHeaders() async throws {
        try await Self.withServer { baseURL, _ in
            var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/health"))
            request.setValue(Self.currentToken, forHTTPHeaderField: ControlAPI.tokenHeaderName)
            let (_, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            let names = http.allHeaderFields.keys.compactMap { ($0 as? String)?.lowercased() }
            #expect(names.contains { $0.hasPrefix("access-control-") } == false)
        }
    }

    // MARK: - Import validation

    @Test("An imported project is held to the same rules as an edited one")
    func importIsValidated() async throws {
        try await Self.withServer { baseURL, _ in
            func importing(_ scenario: Scenario) async throws -> Reply {
                let project = MockProject(
                    name: "imported-\(scenario.statusCode)",
                    endpoints: [
                        Endpoint(
                            name: "route",
                            method: .get,
                            path: "/route",
                            scenarios: [scenario],
                            activeScenarioID: scenario.id
                        )
                    ]
                )
                return try await Self.post(.projectImport(project: project, activate: false), baseURL: baseURL)
            }

            // A negative status used to be accepted here and then trapped the process when served.
            let negative = try await importing(Scenario(name: "boom", statusCode: -1))
            #expect(negative.status == 400)
            #expect(negative.response.error?.code == "request.invalid")

            let tooLarge = try await importing(Scenario(name: "boom", statusCode: 100_000))
            #expect(tooLarge.status == 400)

            let split = try await importing(
                Scenario(name: "boom", statusCode: 200, headers: ["X-Test": "a\r\nSet-Cookie: evil=1"])
            )
            #expect(split.status == 400)

            // And a well-formed document still imports.
            #expect(try await importing(Scenario(name: "fine", statusCode: 201)).status == 200)
        }
    }

    // MARK: - Request body size

    /// The command route used to take Vapor's default body strategy — `.collect(maxSize: nil)`, which
    /// resolves to `Routes.defaultMaxBodySize`, **16 KB**. `projectImport` posts a whole `MockProject`,
    /// captured response bodies included. An endpoint of the fixture below encodes to about 2 KB, so
    /// the default was worth roughly eight of them; past that, `mimic project import` was answered
    /// `413 Payload Too Large` by Vapor before `ControlServer` saw the request at all.
    /// `MockServerEngine`'s `VaporConfigurator` had passed `.collect(maxSize: "10mb")` for served
    /// traffic all along; the control plane was the surface nobody sized.
    ///
    /// Two things about the fixture are what make this test able to fail, and both are deliberate.
    ///
    /// It is built from endpoints and scenarios rather than one padded string, so it stays a test about
    /// a document a person could really import: change how a `MockProject` encodes and this still
    /// measures what actually reaches the wire.
    ///
    /// And it is *hundreds* of KB rather than the ~17 KB that would nominally clear the old limit,
    /// because `maxSize` is only ever consulted for a **streamed** body. `HTTPServerRequestDecoder`
    /// stores the body as `.collected` when the first `.body` part it sees already equals
    /// `Content-Length`, and the route's `collect` is then skipped outright — the responder runs it
    /// only `if … request.body.data == nil`. A body small enough to arrive in one socket read would
    /// therefore be accepted with the cap removed, and this test would pass while asserting nothing.
    /// Vapor's `ServerBootstrap` sets `maxMessagesPerRead` to 1 and overrides no receive allocator, so
    /// NIO's `AdaptiveRecvByteBufferAllocator` applies at its defaults, whose ceiling is 64 KiB: a
    /// document several times that cannot arrive whole however the kernel schedules the reads.
    @Test("A project document far past Vapor's 16 KB default still imports over HTTP")
    func largeProjectImportIsAccepted() async throws {
        try await Self.withServer { baseURL, _ in
            let endpointCount = 120
            let project = Self.bulkyProject(endpointCount: endpointCount, recordsPerBody: 24)
            let encoded = try ControlCoding.encoder().encode(
                ControlCommand.projectImport(project: project, activate: false)
            )

            // The test's own precondition. A generator that quietly shrank — a shorter record, fewer
            // endpoints — would leave every assertion below passing against a body the 16 KB default
            // would have allowed, which is the shape of assertion this repo has been bitten by before.
            #expect(
                encoded.count > 64 * 1024,
                "the fixture must be too large to arrive in a single socket read; it was \(encoded.count) bytes"
            )

            var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(Self.currentToken, forHTTPHeaderField: ControlAPI.tokenHeaderName)
            request.httpBody = encoded

            // Sent by hand rather than through `Self.post`, which decodes the envelope eagerly: a
            // refused collect never reaches Mimic's code, so the reply is Vapor's own
            // `{"error":true,…}` and decoding it as a `ControlResponse` throws a `DecodingError` that
            // says nothing about the size. Read the status first and put the body in the message.
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            let http = try #require(response as? HTTPURLResponse)
            #expect(
                http.statusCode == 200,
                "a \(encoded.count)-byte projectImport was refused: \(String(decoding: data, as: UTF8.self))"
            )

            // `try?` for the same reason: on a regression this is nil, and two clean expectation
            // failures read better than a decoding error thrown out of the test.
            let decoded = try? ControlCoding.decode(ControlResponse.self, from: data)
            #expect(decoded?.ok == true)
            // The echoed document is the proof the *whole* body arrived and decoded, not just the head.
            #expect(decoded?.result?.project?.endpoints.count == endpointCount)
        }
    }

    /// A project the size real ones reach, made of the thing that actually makes them big: one
    /// captured response body per endpoint. No filler — every byte here is a value the app itself
    /// could have stored.
    static func bulkyProject(endpointCount: Int, recordsPerBody: Int) -> MockProject {
        let endpoints = (0..<endpointCount).map { page -> Endpoint in
            let scenario = Scenario(
                name: "Default",
                statusCode: 200,
                headers: ["X-Page": "\(page)"],
                body: Self.capturedBody(records: recordsPerBody, page: page)
            )
            return Endpoint(
                name: "Catalogue page \(page)",
                method: .get,
                path: "/catalogue/page/\(page)",
                scenarios: [scenario],
                activeScenarioID: scenario.id
            )
        }
        return MockProject(name: "Bulky catalogue", endpoints: endpoints)
    }

    /// A JSON array of records — the shape a captured list response has, and the reason a scenario
    /// body is kilobytes rather than bytes.
    static func capturedBody(records: Int, page: Int) -> String {
        let rows = (0..<records).map { row -> String in
            let id = page * records + row
            let sku = "SKU-\(page)-\(row)"
            return #"{"id":\#(id),"sku":"\#(sku)","name":"Widget \#(row)","price":\#(1999 + row)}"#
        }
        return "[" + rows.joined(separator: ",") + "]"
    }

    // MARK: - Log redaction

    @Test("logList redacts credentials the app under test sent")
    func logListRedactsCredentials() async throws {
        try await Self.withServer { baseURL, host in
            await host.appendLog(RequestLog(
                method: .post,
                path: "/v1/token",
                requestHeaders: [
                    "Authorization": "Bearer real-token",
                    "Cookie": "session=abc",
                    "Accept": "application/json",
                ],
                requestBody: #"{"grant_type":"refresh"}"#,
                responseStatusCode: 200,
                responseHeaders: ["Set-Cookie": "session=rotated"]
            ))

            let reply = try await Self.post(.logList(limit: nil, unmatchedOnly: nil), baseURL: baseURL)
            let logged = try #require(reply.response.result?.logs?.first)

            #expect(logged.requestHeaders["Authorization"] == RequestLog.redactionPlaceholder)
            #expect(logged.requestHeaders["Cookie"] == RequestLog.redactionPlaceholder)
            #expect(logged.responseHeaders["Set-Cookie"] == RequestLog.redactionPlaceholder)
            // Non-sensitive headers survive, and so does the name of the redacted one — "there was an
            // Authorization header" is usually the fact being debugged.
            #expect(logged.requestHeaders["Accept"] == "application/json")
            #expect(logged.requestHeaders.keys.contains("Authorization"))
        }
    }

    /// The host's first non-loopback IPv4 address, or `nil` when it has none.
    static func routableIPv4Address() -> String? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }
        defer { freeifaddrs(head) }

        var cursor = head
        while let current = cursor {
            defer { cursor = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == sa_family_t(AF_INET) else { continue }

            var name = [CChar](repeating: 0, count: 256)
            let resolved = getnameinfo(
                address,
                socklen_t(MemoryLayout<sockaddr_in>.size),
                &name,
                socklen_t(name.count),
                nil,
                0,
                Int32(NI_NUMERICHOST)
            )
            guard resolved == 0 else { continue }

            let host = String(cString: name)
            if !host.hasPrefix("127.") { return host }
        }
        return nil
    }
}

/// The host these tests stand `ControlServer` on. A fixture, deliberately not a host.
///
/// Project-scoped commands go through ``ProjectCommandExecutor`` — the production implementation of
/// every rule, the same calls the shipped host makes — over one in-memory project. The handful of
/// host-scoped arms the HTTP tests actually reach are trivial session glue, built from the same
/// Domain pieces the shipped host builds its replies from (`ControlMessages`, `HostReport`,
/// `EndpointValidator`, `JourneyStatus.make`), so what travels over the wire in these tests is the
/// shape production sends. Every other host-scoped command answers `internalFailure` naming this
/// type: a future test reaching for an arm this fixture does not carry fails loudly instead of
/// passing against an accidental default.
///
/// No store and no engine, on purpose. What `ControlServerTests` covers is the HTTP layer; the
/// shipped host's behaviour — persistence ordering, the engine, the write chain — is covered in
/// `MimicTests`, against `AppControlHost` itself.
actor LoopbackTestHost: ControlHost {
    private var project: MockProject?
    private var logs: [RequestLog] = []

    func appendLog(_ log: RequestLog) {
        logs.append(log)
    }

    func execute(_ command: ControlCommand) async -> ControlResponse {
        // The executor first, exactly as the shipped host orders it: it answers every project-scoped
        // command and returns nil for a host-scoped one.
        if var open = project {
            do {
                if let outcome = try ProjectCommandExecutor.apply(command, to: &open) {
                    if outcome.didMutate { project = open }
                    return .success(outcome.result)
                }
            } catch let error as ControlError {
                return .failure(error)
            } catch {
                return .failure(.internalFailure(error.localizedDescription))
            }
        } else if command.kind.scope == .project {
            return .failure(.noProjectOpen)
        }

        switch command {
        case .ping:
            return .success(.message(ControlMessages.ping(mode: "headless", pid: Int(ProcessInfo.processInfo.processIdentifier))))

        case .describeCommands:
            return .success(.init(commands: CommandCatalog.descriptors))

        case .state:
            return .success(.init(state: HostReport.state(
                appVersion: nil,
                mode: "headless",
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                server: HostReport.serverStatus(state: .stopped, configuredPort: 8080, globalDelayMs: 0),
                project: project,
                activeJourney: activeJourneyStatus(),
                requestLogCount: logs.count
            )))

        case let .projectCreate(name, port):
            let configuration = ServerConfiguration(port: port ?? 8080, globalDelayMs: 0)
            let created = MockProject(name: name, serverConfiguration: configuration)
            if let port {
                do { try EndpointValidator.validatePort(port) } catch { return .failure(.validation(error)) }
            }
            project = created
            return .success(.init(message: "Created project \"\(name)\".", project: created))

        case let .projectImport(document, _):
            // Held to the same rules as the shipped host holds it to, through the same validator —
            // `ProjectValidator`, the whole-document one, not `EndpointValidator`'s per-field
            // helpers beside it.
            do { try ProjectValidator.validate(document) } catch { return .failure(.validation(error)) }
            project = document
            return .success(.init(
                message: ControlMessages.projectImported(
                    name: document.name,
                    endpointCount: document.endpoints.count,
                    journeyCount: document.journeys.count
                ),
                project: document
            ))

        case let .journeyActivate(ref):
            guard var open = project else { return .failure(.noProjectOpen) }
            guard let ref, let journey = open.journey(matching: ref) else {
                return .failure(.internalFailure("LoopbackTestHost only activates by reference."))
            }
            open.activeJourneyID = journey.id
            project = open
            return .success(.init(
                message: ControlMessages.journeyActivated(name: journey.name, stepCount: journey.steps.count),
                journey: journey,
                journeyStatus: JourneyStatus.make(journey: journey, state: nil)
            ))

        case .journeyStatus:
            guard let status = activeJourneyStatus() else { return .failure(.noActiveJourney) }
            return .success(.init(journeyStatus: status))

        case let .logList(limit, unmatchedOnly):
            return .success(.init(logs: HostReport.requestLog(from: logs, limit: limit, unmatchedOnly: unmatchedOnly)))

        default:
            return .failure(.internalFailure(
                "\(command.kind.rawValue) is not part of the LoopbackTestHost fixture — add the arm if an HTTP test needs it."
            ))
        }
    }

    private func activeJourneyStatus() -> JourneyStatus? {
        guard let project, let id = project.activeJourneyID,
              let journey = project.journeys.first(where: { $0.id == id }) else { return nil }
        return JourneyStatus.make(journey: journey, state: nil)
    }
}


/// The **write half** of the discovery-file contract: publication, mode discipline, and the
/// writer's half of the `MIMIC_CONTROL_FILE` override.
///
/// The read half — search order, override-replaces-the-list, tilde expansion, the tampered
/// `baseURL`, pid liveness, and the token-pairing rules — lives in `Domain` as
/// `ControlEndpointDiscovery`, and its suite is `ControlEndpointDiscoveryTests` in `DomainTests`.
/// This module used to carry a reader of its own and a suite asserting it, and every one of those
/// assertions ran against code no production binary called; what stays here is what only the writer
/// can regress. Where a case below needs to *read* a file back, it reads it through the Domain
/// reader, because that is the one reader that exists — the cross-check that writer and reader mean
/// the same bytes and the same path.
@Suite("Endpoint discovery file — the write side")
struct ControlEndpointFileTests {

    /// The reader and the writer have to mean the same file, which is the whole point of resolving
    /// the override in one place (`ControlEndpointDiscovery.overrideURL`): a process that advertises
    /// at the override and then computes the *default* path on the way out would delete the
    /// developer's advertisement and leave its own.
    @Test("Writing, discovering and removing all follow the override together")
    func overrideIsHonouredByWriteDiscoverAndRemove() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately *not* created first: the write has to make its own parent, because the script
        // that names the override names a path inside a directory it has just `mktemp -d`-ed and then
        // a subdirectory that does not exist yet.
        let target = directory.appendingPathComponent("nested").appendingPathComponent("control.json")
        let environment = [ControlEndpointDiscovery.pathEnvironmentKey: target.path]

        let resolved = try ControlEndpointFile.writeURL(environment: environment)
        #expect(resolved.path == target.path)

        let endpoint = ControlEndpoint(
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            mode: "headless",
            token: ControlToken.generate()
        )
        try ControlEndpointFile.write(endpoint, environment: environment)
        #expect(FileManager.default.fileExists(atPath: target.path))

        // The token is in there, so the override gets the same 0600 the computed path does — an
        // isolated run is not a less sensitive one.
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: target.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value & 0o777 == 0o600, "mode was \(String(mode.int16Value, radix: 8))")

        let discovered = try #require(ControlEndpointDiscovery.discover(environment: environment))
        #expect(discovered == endpoint)

        ControlEndpointFile.remove(environment: environment)
        #expect(FileManager.default.fileExists(atPath: target.path) == false)
        #expect(ControlEndpointDiscovery.discover(environment: environment) == nil)
    }

    @Test("A discovery file round-trips through the Domain reader and carries a usable base URL")
    func fileRoundTrip() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-discovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let endpoint = ControlEndpoint(
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            mode: "headless"
        )
        try ControlEndpointFile.write(endpoint, to: url)

        let discovered = try #require(ControlEndpointDiscovery.discover(searchURLs: [url]))
        #expect(discovered == endpoint)
        #expect(discovered.baseURL == "http://127.0.0.1:8787")

        ControlEndpointFile.remove(at: url)
        #expect(ControlEndpointDiscovery.discover(searchURLs: [url]) == nil)
    }

    /// The file carries the instance's token, so its mode *is* the access control — and until this
    /// test existed nothing anywhere asserted it. The write used to be `.atomic` followed by a
    /// `chmod`, which publishes the token at the final path for as long as the second call takes,
    /// and leaves it published forever if that call throws.
    ///
    /// **The mode assertions below cannot fail on their own, and the test's name used to promise
    /// what they could not deliver.** `rename(2)` carries the source file's mode across with it, so
    /// the published file reads `0600` whether the mode was put on the temporary *before* it was
    /// published — the safe order — or chmod'd onto the target *after*, which is the shape the
    /// finding is about. Both orders end at the same observable file, and the difference between
    /// them is a window a few microseconds wide that no reading of the result can see. They are kept
    /// because a write that lands at `0644` and stays there is still the failure worth catching
    /// first; what they are not is a guard on the ordering.
    ///
    /// Two checks that *can* fail cover the rest: `publicationReplacesTheFileRatherThanRewritingIt`
    /// below pins that the advertisement is published by replacing the directory entry rather than
    /// by opening the real name and writing into it, and `writePathAppliesTheModeBeforePublishing`
    /// reads the write path itself, because the ordering is a property of the code and not of its
    /// output.
    @Test("The discovery file is 0600 on a first write and on an overwrite")
    func discoveryFileIsPrivate() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-perms-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let endpoint = ControlEndpoint(
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            mode: "headless",
            token: ControlToken.generate()
        )

        try ControlEndpointFile.write(endpoint, to: url)
        let mode = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(mode.int16Value & 0o777 == 0o600, "mode was \(String(mode.int16Value, radix: 8))")

        // Overwriting an existing advertisement — a restart on a new port — must land at 0600 too,
        // and must not inherit a wider mode from whatever was already there.
        try ControlEndpointFile.write(endpoint, to: url)
        let rewritten = try #require(
            FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        )
        #expect(rewritten.int16Value & 0o777 == 0o600)

        // And no temporary file is left beside it.
        let siblings = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(siblings == ["control.json"], "leftover files: \(siblings)")
    }

    /// A hard link taken before an overwrite is the one thing that can see *how* the new
    /// advertisement arrived.
    ///
    /// `rename(2)` swings the directory entry to a different inode, so a second link to the original
    /// inode still holds the original bytes afterwards. A write that instead opened `control.json`
    /// itself and truncated it — no temporary, no rename — would reach the same final content
    /// through the same link, and would have published an empty file at the real name on the way
    /// there, at whatever mode the umask allowed on a first write. That is the same class of failure
    /// as chmod-after-rename, and unlike the mode of the finished file it is observable.
    @Test("Publishing an advertisement replaces the file rather than rewriting it in place")
    func publicationReplacesTheFileRatherThanRewritingIt() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-publish-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        let pid = Int(ProcessInfo.processInfo.processIdentifier)
        try ControlEndpointFile.write(
            ControlEndpoint(port: 8787, pid: pid, mode: "headless", token: ControlToken.generate()),
            to: url
        )

        let witness = directory.appendingPathComponent("witness.json")
        try FileManager.default.linkItem(at: url, to: witness)
        let firstAdvertisement = try Data(contentsOf: url)

        // A restart on a different port, so the two advertisements cannot be confused for each other.
        try ControlEndpointFile.write(
            ControlEndpoint(port: 8788, pid: pid, mode: "headless", token: ControlToken.generate()),
            to: url
        )

        let published = try Data(contentsOf: url)
        let throughTheOldLink = try Data(contentsOf: witness)

        #expect(published != firstAdvertisement, "the overwrite did not take")
        #expect(
            throughTheOldLink == firstAdvertisement,
            """
            The second write reached the inode the first one published, so `control.json` was \
            rewritten in place rather than replaced. A reader holding that path sees a truncated \
            file mid-write, and a first write done this way lands at the umask default with the \
            token already in it.
            """
        )
    }

    /// The ordering the finding is actually about, read off the write path itself.
    ///
    /// Nothing observable about the finished file distinguishes "mode applied to the temporary, then
    /// renamed" from "renamed, then chmod'd" — see the note on `discoveryFileIsPrivate`. So this
    /// asserts the property where it lives: `ControlEndpointFile` never chmods a path at all, never
    /// asks `Data.write` to publish atomically on its behalf, and puts `0o600` on the file at the
    /// moment it is created, which is before the `rename` that gives it its real name.
    ///
    /// Whole-line comments are dropped before any of that is looked for, for the reason
    /// `Scripts/check_compiler_settings.py` drops them from the two manifests it compares:
    /// `ControlEndpointFile.write`'s own documentation spells out both `setAttributes` and `.atomic`
    /// while explaining why neither belongs in the write path, and a check that read them would be
    /// answering from the explanation instead of from the code.
    @Test("The write path applies the mode before it publishes, not after")
    func writePathAppliesTheModeBeforePublishing() throws {
        let source = try Self.controlPlaneSource("ControlEndpointFile.swift")

        #expect(
            !source.contains("setAttributes"),
            """
            ControlEndpointFile now chmods a path. If that is the discovery file, it is the finding \
            coming back: between the rename that publishes the token and the chmod that narrows it, \
            the file sits at the final path at whatever the umask allows — and a throw in between \
            leaves it there.
            """
        )
        #expect(
            !source.contains(".atomic"),
            """
            ControlEndpointFile asks Foundation to publish a file atomically. `.atomic` renames a \
            temporary of Foundation's own making, created under the umask, so the mode can only be \
            applied afterwards — which is the ordering this file exists to avoid.
            """
        )

        let creation = try #require(
            source.range(of: "createFile("),
            "the write path no longer creates the file it will publish"
        )
        let publication = try #require(
            source.range(of: "rename("),
            "the write path no longer publishes by rename"
        )
        // A guard rather than an expectation: the slice below would trap on an inverted range, and a
        // crash reports worse than a failure does.
        guard creation.upperBound < publication.lowerBound else {
            Issue.record("the file is created after it is published, which cannot be the intended order")
            return
        }
        #expect(
            source[creation.upperBound..<publication.lowerBound].contains("0o600"),
            """
            0o600 is no longer applied between creating the temporary and renaming it into place. \
            The mode has to be on the file before it takes the real name; `rename(2)` carries it \
            across, and anything applied afterwards is applied to a file that is already published.
            """
        )
    }

    /// The text of a file in `Sources/ControlPlane`, with whole-line `//` comments removed.
    ///
    /// Located from `#filePath` rather than from a bundle: this file is
    /// `Tests/ControlPlaneTests/ControlServerTests.swift`, so the repository root is three
    /// directories above it, and both CI jobs build from the checkout.
    static func controlPlaneSource(
        _ fileName: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/ControlPlane", isDirectory: true)
            .appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            Issue.record(
                "no source at \(url.path), derived from #filePath three directories up",
                sourceLocation: sourceLocation
            )
            return ""
        }
        let text = try String(contentsOf: url, encoding: .utf8)
        return text
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
