import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import ControlPlane
@testable import Domain
@testable import Persistence

/// The HTTP surface, exercised the way a `curl`-driven script or a non-Swift agent would.
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
        _ body: (URL, MimicControlService) async throws -> Void
    ) async throws {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let service = MimicControlService(
            repository: GRDBProjectRepository(dbQueue: queue),
            settings: SettingsStore(dbQueue: queue),
            mode: "headless"
        )
        // An explicit token keeps the suite independent of `MIMIC_CONTROL_TOKEN` in the environment.
        let server = ControlServer(host: service, mode: "headless", token: ControlToken.generate())
        // Port 0 lets the OS pick, and `advertise: false` keeps the test from overwriting a real
        // instance's discovery file.
        let port = try await server.start(port: 0, advertise: false)
        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))

        do {
            try await Self.$currentToken.withValue(server.token) {
                try await body(baseURL, service)
            }
        } catch {
            try? await server.stop()
            await service.shutdown()
            throw error
        }
        try await server.stop()
        await service.shutdown()
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
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        let service = MimicControlService(
            repository: GRDBProjectRepository(dbQueue: queue),
            settings: SettingsStore(dbQueue: queue),
            mode: "headless"
        )

        for attempt in 1...3 {
            let server = ControlServer(host: service, mode: "headless", token: ControlToken.generate())
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

        await service.shutdown()
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

    // MARK: - Log redaction

    @Test("logList redacts credentials the app under test sent")
    func logListRedactsCredentials() async throws {
        try await Self.withServer { baseURL, service in
            await service.appendLog(RequestLog(
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

@Suite("Endpoint discovery")
struct ControlEndpointFileTests {

    @Test("An explicit URL beats the environment, which beats a discovery file")
    func resolutionOrder() throws {
        let discovered = ControlEndpoint(port: 1111, pid: 1, mode: "app")

        #expect(ControlEndpointFile.resolveBaseURL(
            explicit: "http://127.0.0.1:3333",
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:3333")

        #expect(ControlEndpointFile.resolveBaseURL(
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:2222")

        #expect(ControlEndpointFile.resolveBaseURL(
            environment: [ControlAPI.portEnvironmentKey: "4444"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:4444")

        #expect(ControlEndpointFile.resolveBaseURL(
            environment: [:],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")

        #expect(ControlEndpointFile.resolveBaseURL(environment: [:], discovered: nil) == nil)
    }

    /// `environment:` is passed explicitly, and every case below does the same. It defaults to the
    /// real process environment, so a developer who happens to have `MIMIC_CONTROL_FILE` exported —
    /// which `Scripts/run_cli_e2e.sh` sets, and a shell keeps — would otherwise get one path back here
    /// and a red suite that has nothing to do with the code.
    @Test("The sandboxed container is searched before the plain Application Support path")
    func searchOrderPrefersTheAppContainer() {
        let urls = ControlEndpointFile.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [:]
        )
        #expect(urls.count == 2)
        #expect(urls[0].path.contains("Library/Containers/devxa.Mimic"))
        #expect(urls[1].path.contains("Library/Application Support/devxa.Mimic"))
        #expect(urls.allSatisfy { $0.lastPathComponent == "control.json" })
    }

    // MARK: - MIMIC_CONTROL_FILE

    /// The override exists because the default path is *computed*, so two launches of the app bundle
    /// resolve to the same file: an end-to-end script's instance overwrites the developer's
    /// advertisement and removes it on the way out, leaving a running Mimic no `mimic` command can
    /// find. `Scripts/run_cli_e2e.sh` sets it for exactly that reason and asserts the file appears.
    ///
    /// It **replaces** the search list rather than joining the front of it, and that is the assertion
    /// that matters most: prepending would let a run whose own instance has not advertised yet fall
    /// through to the developer's real file and drive that instance instead — a failure that looks
    /// exactly like a passing test.
    @Test("The override replaces the search list rather than being tried first")
    func overrideReplacesTheSearchList() {
        let override = "/tmp/mimic-e2e/control.json"
        let urls = ControlEndpointFile.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [ControlEndpointFile.pathEnvironmentKey: override]
        )

        #expect(urls.map(\.path) == [override])
        #expect(urls.contains { $0.path.contains("Library/Application Support/devxa.Mimic") } == false)
    }

    /// An exported-but-unassigned variable — `MIMIC_CONTROL_FILE="$WORK/control.json"` in a script
    /// where `WORK` was never set — must read as "not overridden" rather than as a path nobody chose.
    /// `DatabaseFactory.resolveDatabaseURL` treats an empty `MIMIC_DATABASE_PATH` the same way.
    @Test("An empty override falls back to the real search list")
    func emptyOverrideIsIgnored() {
        let urls = ControlEndpointFile.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [ControlEndpointFile.pathEnvironmentKey: ""]
        )
        #expect(urls.count == 2)
    }

    /// The reader and the writer have to mean the same file, which is the whole point of threading one
    /// environment through both: a process that advertises at the override and then computes the
    /// *default* path on the way out would delete the developer's advertisement and leave its own.
    @Test("Writing, discovering and removing all follow the override together")
    func overrideIsHonouredByWriteDiscoverAndRemove() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-override-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // Deliberately *not* created first: the write has to make its own parent, because the script
        // that names the override names a path inside a directory it has just `mktemp -d`-ed and then
        // a subdirectory that does not exist yet.
        let target = directory.appendingPathComponent("nested").appendingPathComponent("control.json")
        let environment = [ControlEndpointFile.pathEnvironmentKey: target.path]

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

        let discovered = try #require(ControlEndpointFile.discover(environment: environment))
        #expect(discovered == endpoint)

        ControlEndpointFile.remove(environment: environment)
        #expect(FileManager.default.fileExists(atPath: target.path) == false)
        #expect(ControlEndpointFile.discover(environment: environment) == nil)
    }

    /// A tilde is what a person types when they name a path in a shell profile, and `URL(fileURLWithPath:)`
    /// does not expand it — a literal `~` directory would be created in the working directory instead.
    @Test("A tilde in the override is expanded")
    func overrideExpandsTilde() {
        let urls = ControlEndpointFile.searchURLs(
            environment: [ControlEndpointFile.pathEnvironmentKey: "~/mimic/control.json"]
        )
        #expect(urls.count == 1)
        #expect(urls[0].path.hasPrefix("/"))
        #expect(urls[0].path.contains("~") == false)
        #expect(urls[0].lastPathComponent == "control.json")
    }

    @Test("A discovery file round-trips and carries a usable base URL")
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

        let discovered = try #require(ControlEndpointFile.discover(searchURLs: [url]))
        #expect(discovered == endpoint)
        #expect(discovered.baseURL == "http://127.0.0.1:8787")

        ControlEndpointFile.remove(at: url)
        #expect(ControlEndpointFile.discover(searchURLs: [url]) == nil)
    }

    /// The file carries the instance's token, so its mode *is* the access control — and until this
    /// test existed nothing anywhere asserted it. The write used to be `.atomic` followed by a
    /// `chmod`, which publishes the token at the final path for as long as the second call takes,
    /// and leaves it published forever if that call throws.
    @Test("The discovery file is 0600, and is never briefly wider")
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

    /// A discovery file is a file on disk, and `baseURL` is a field in it. Trusting that field sends
    /// the caller's `X-Mimic-Token` wherever the file says — so the host is derived, not read.
    @Test("A tampered baseURL cannot redirect the CLI off the loopback")
    func baseURLIsDerivedFromThePort() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-tamper-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        var endpoint = ControlEndpoint(
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            mode: "headless"
        )
        endpoint.baseURL = "http://evil.example:80"
        try ControlEndpointFile.write(endpoint, to: url)

        let discovered = try #require(ControlEndpointFile.discover(searchURLs: [url]))
        let resolved = try #require(
            ControlEndpointFile.resolveBaseURL(explicit: nil, environment: [:], discovered: discovered)
        )
        #expect(resolved.absoluteString == "http://127.0.0.1:8787")
    }

    @Test("A file left by a crashed instance is skipped instead of hanging the CLI")
    func staleFileIsIgnored() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-stale-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = directory.appendingPathComponent("control.json")
        // A pid that is not running.
        try ControlEndpointFile.write(ControlEndpoint(port: 8787, pid: 999_999, mode: "headless"), to: url)

        #expect(ControlEndpointFile.discover(searchURLs: [url], isProcessAlive: { _ in false }) == nil)
        #expect(ControlEndpointFile.discover(searchURLs: [url], isProcessAlive: { _ in true }) != nil)
    }

    @Test("The current process reads as alive, and pid 0 never does")
    func livenessCheck() {
        #expect(ControlEndpointFile.isProcessAlive(Int(ProcessInfo.processInfo.processIdentifier)))
        #expect(ControlEndpointFile.isProcessAlive(0) == false)
        #expect(ControlEndpointFile.isProcessAlive(-1) == false)
    }
}
