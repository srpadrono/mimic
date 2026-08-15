import Foundation
import Testing
import ControlPlane
import Domain
import Persistence
@testable import AppFeatures

/// The production pairing, over a real socket: `ControlServer` standing on `AppControlHost`.
///
/// Every `mimic` invocation and every HTTP control call goes through exactly this composition, and
/// until this file existed no gate did. `ControlServerTests` stands the server on `LoopbackTestHost`
/// — a fixture, which is right for what that suite covers (authentication, Host pinning, body
/// limits, the error→status map) because those are properties of the server and want a host they can
/// hold still. `HostCommandSweepTests` drives `AppControlHost` directly, in-process, with no wire at
/// all. Between them sat the seam: command encoding, the route, admission, and the host's own reply
/// travelling back through `ControlServer.encode` — each half tested against the other half's stand-in.
///
/// Deliberately small. This is a smoke test for the composition, not a second copy of either suite:
/// one happy-path sequence that has to reach the live session and the real store, and one refusal
/// that has to arrive with the status a script branches on.
///
/// Hermetic on both axes that matter. The port is `0`, so the OS picks one and no fixed number can
/// collide with a developer's running instance; `advertise: false` keeps the run from writing — and
/// then removing — the shared `control.json` a real instance advertises through. The store is
/// in-memory, the defaults suite is per-run, and the engine is a stub, so nothing here binds the
/// mock server's port either.
///
/// Time-limited because each case binds a socket: a bind that never completes otherwise hangs the
/// whole run with no indication of which test is stuck.
@Suite("Composed control server", .serialized, .timeLimit(.minutes(1)))
@MainActor
struct ComposedControlServerTests {

    // MARK: - Fixtures

    /// An engine that serves nothing.
    ///
    /// Nothing here starts the mock server, and the host reaches the engine only through
    /// `MockServerRuntime`, so a stub keeps the suite from binding a second port on top of the
    /// control plane's.
    private actor StubEngine: MockServerEngineProtocol {
        nonisolated let logStream: AsyncStream<RequestLog>
        private nonisolated let logContinuation: AsyncStream<RequestLog>.Continuation

        init() {
            (logStream, logContinuation) = AsyncStream<RequestLog>.makeStream()
        }

        deinit {
            logContinuation.finish()
        }

        func start(configuration: ServerConfiguration) async throws {}
        func stop() async throws {}
        func updateConfiguration(endpoints: [Endpoint], globalDelayMs: Int) async {}
    }

    private struct Session {
        let host: AppControlHost
        /// Held because `AppControlHost` holds the session *weakly*, so nothing else here keeps it
        /// alive. Drop this and every command answers "The Mimic session is no longer available."
        let appState: AppState
    }

    private func makeSession() throws -> Session {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        // Its own defaults suite, so a run cannot inherit — or overwrite — a real recents list or a
        // real window arrangement. `PanelLayoutStore()` would bind to `.standard` and do exactly that.
        let defaults = try #require(UserDefaults(suiteName: "ComposedControlServerTests.\(UUID().uuidString)"))
        let appState = AppState(
            server: MockServerRuntime(engine: StubEngine()),
            projectRepository: GRDBProjectRepository(dbQueue: queue),
            recentProjectsStore: RecentProjectsStore(defaults: defaults),
            panelLayoutStore: PanelLayoutStore(defaults: defaults)
        )
        return Session(
            host: AppControlHost(appState: appState, repository: appState.repository),
            appState: appState
        )
    }

    /// Stands the shipped pairing up on an ephemeral loopback port and tears it down on both exits.
    private func withComposedServer(
        _ body: (URL, String, Session) async throws -> Void
    ) async throws {
        let session = try makeSession()
        // An explicit token keeps the suite independent of `MIMIC_CONTROL_TOKEN` in the environment.
        let server = ControlServer(host: session.host, mode: "headless", token: ControlToken.generate())
        let port = try await server.start(port: 0, advertise: false)
        let baseURL = try #require(URL(string: "http://127.0.0.1:\(port)"))

        do {
            try await body(baseURL, server.token, session)
        } catch {
            try? await server.stop()
            throw error
        }
        try await server.stop()
    }

    // MARK: - Speaking to it the way the CLI does

    private struct Reply {
        let status: Int
        let response: ControlResponse
    }

    private func get(_ path: String, baseURL: URL, token: String) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "GET"
        return try await send(request, token: token)
    }

    private func post(_ command: ControlCommand, baseURL: URL, token: String) async throws -> Reply {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try ControlCoding.encoder().encode(command)
        return try await send(request, token: token)
    }

    private func send(_ request: URLRequest, token: String) async throws -> Reply {
        var request = request
        request.setValue(token, forHTTPHeaderField: ControlAPI.tokenHeaderName)
        let urlSession = URLSession(configuration: .ephemeral)
        let (data, response) = try await urlSession.data(for: request)
        let http = try #require(response as? HTTPURLResponse)
        let decoded = try ControlCoding.decode(ControlResponse.self, from: data)
        return Reply(status: http.statusCode, response: decoded)
    }

    // MARK: - Tests

    /// One sequence covering both sides of `CommandKind.scope` and the read the CLI renders: a
    /// host-scoped create, a project-scoped endpoint through the shared executor, `state` read back
    /// over the wire, and `projectList`, which is the one that has to have reached the real store —
    /// it awaits the workspace's write chain before it reads.
    @Test("The shipped pairing answers a command sequence end to end over the loopback socket")
    func theShippedPairingAnswersOverTheSocket() async throws {
        try await withComposedServer { baseURL, token, session in
            let health = try await get("\(ControlAPI.version)/health", baseURL: baseURL, token: token)
            #expect(health.status == 200)
            #expect(health.response.ok)

            let created = try await post(
                .projectCreate(name: "Checkout", port: 9099),
                baseURL: baseURL,
                token: token
            )
            #expect(created.status == 200)
            #expect(created.response.ok)
            // The live session, not a copy: a create answered over the socket is what the window
            // shows, which is the whole reason the app hosts the control plane itself.
            #expect(session.appState.currentProject?.name == "Checkout")

            let endpoint = try await post(
                .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
                baseURL: baseURL,
                token: token
            )
            #expect(endpoint.status == 200)
            #expect(endpoint.response.ok)
            #expect(session.appState.currentProject?.endpoints.map(\.path) == ["/login"])

            let state = try await get("\(ControlAPI.version)/state", baseURL: baseURL, token: token)
            #expect(state.status == 200)
            // Not `mode`: the host reads that from `MIMIC_HEADLESS`, which a test run does not set,
            // so it says "app" here and would say "headless" under `mimic daemon start`. The API
            // version is the fact this read is for.
            #expect(state.response.result?.state?.apiVersion == ControlAPI.version)
            #expect(state.response.result?.state?.project?.name == "Checkout")
            #expect(state.response.result?.state?.project?.port == 9099)
            #expect(state.response.result?.state?.endpointCount == 1)

            let listed = try await post(.projectList, baseURL: baseURL, token: token)
            #expect(listed.status == 200)
            #expect(listed.response.result?.projects?.map(\.name) == ["Checkout"])
            #expect(listed.response.result?.projects?.first?.endpointCount == 1)
        }
    }

    /// The refusals a script branches on, produced by the shipped host rather than by a fixture that
    /// answers them as glue. Both sides of the partition are represented: a project-scoped command
    /// with nothing open is declined to the host, which answers `project.noneOpen`; a host-scoped
    /// one resolves its reference against the store and answers `project.notFound`.
    @Test("A refusal from the shipped host arrives with its own code and status")
    func aRefusalCarriesItsCodeAndStatus() async throws {
        try await withComposedServer { baseURL, token, _ in
            let noProject = try await post(
                .endpointCreate(name: "Login", method: .post, path: "/login", spec: nil),
                baseURL: baseURL,
                token: token
            )
            #expect(noProject.status == 409)
            #expect(noProject.response.ok == false)
            #expect(noProject.response.error?.code == "project.noneOpen")

            let missing = try await post(
                .projectDelete(project: .name("Nonexistent")),
                baseURL: baseURL,
                token: token
            )
            #expect(missing.status == 404)
            #expect(missing.response.ok == false)
            #expect(missing.response.error?.code == "project.notFound")
        }
    }
}
