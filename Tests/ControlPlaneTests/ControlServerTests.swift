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
@Suite(.serialized)
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

    @Test("The sandboxed container is searched before the plain Application Support path")
    func searchOrderPrefersTheAppContainer() {
        let urls = ControlEndpointFile.searchURLs(homeDirectory: URL(fileURLWithPath: "/Users/test"))
        #expect(urls.count == 2)
        #expect(urls[0].path.contains("Library/Containers/devxa.Mimic"))
        #expect(urls[1].path.contains("Library/Application Support/devxa.Mimic"))
        #expect(urls.allSatisfy { $0.lastPathComponent == "control.json" })
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
