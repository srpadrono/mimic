import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif
import Testing
@testable import ControlPlane
@testable import Domain
@testable import MockServerEngine
@testable import Persistence

/// Exercises the control surface the way the CLI does — one command at a time against a live
/// service — without HTTP or a daemon in the way.
///
/// Time-limited because every case here binds a real socket: a bind that never completes, or a
/// wait on traffic that never arrives, otherwise hangs the whole run with no indication of which
/// test is stuck. A minute is the finest granularity `.timeLimit` offers and is far above what
/// any of these needs — the point is a bound, not a deadline.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ControlServiceTests {

    static func makeService() throws -> MimicControlService {
        let queue = try DatabaseFactory.makeInMemoryDatabaseQueue()
        return MimicControlService(
            repository: GRDBProjectRepository(dbQueue: queue),
            settings: SettingsStore(dbQueue: queue),
            engine: MockServerEngine(),
            mode: "headless"
        )
    }

    /// Runs a command and requires it to succeed, reporting the control error verbatim if not.
    @discardableResult
    static func ok(
        _ service: MimicControlService,
        _ command: ControlCommand,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> ControlResult {
        let response = await service.execute(command)
        guard response.ok, let result = response.result else {
            Issue.record(
                "\(command) failed: \(response.error?.code ?? "?") \(response.error?.message ?? "")",
                sourceLocation: sourceLocation
            )
            throw ControlError.internalFailure("command failed")
        }
        return result
    }

    static func failure(
        _ service: MimicControlService,
        _ command: ControlCommand
    ) async -> ControlError? {
        await service.execute(command).error
    }

    // MARK: - Preconditions

    @Test("Project-scoped commands report that nothing is open, not that they are unsupported")
    func noProjectOpenIsExplicit() async throws {
        let service = try Self.makeService()
        for command: ControlCommand in [
            .endpointList, .journeyList, .journeyStatus, .journeyRestart, .journeyAdvance,
            .serverStart(port: nil), .projectRename(name: "x"), .projectExport(project: nil),
            .endpointCreate(name: nil, method: .get, path: "/a", spec: nil),
        ] {
            let error = await Self.failure(service, command)
            #expect(error?.code == "project.noneOpen", "\(command) reported \(error?.code ?? "success")")
        }
    }

    @Test("Discovery and log commands work with no project open")
    func discoveryWorksWithoutAProject() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .ping)
        let catalog = try await Self.ok(service, .describeCommands)
        #expect(catalog.commands?.count == CommandCatalog.descriptors.count)

        let state = try await Self.ok(service, .state)
        #expect(state.state?.project == nil)
        #expect(state.state?.server.state == "stopped")
        #expect(state.state?.mode == "headless")
        #expect(state.state?.apiVersion == ControlAPI.version)

        let logs = try await Self.ok(service, .logList(limit: nil, unmatchedOnly: nil))
        #expect(logs.logs?.isEmpty == true)
    }

    // MARK: - Projects

    @Test("Creating a project opens it, and the whole surface becomes available")
    func createOpensTheProject() async throws {
        let service = try Self.makeService()
        let created = try await Self.ok(service, .projectCreate(name: "Checkout", port: 9099))
        #expect(created.project?.name == "Checkout")

        let state = try await Self.ok(service, .state)
        #expect(state.state?.project?.name == "Checkout")
        #expect(state.state?.server.port == 9099)
    }

    @Test("Projects are addressable by name, and listing reports accurate counts")
    func listingReportsCounts() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "First", port: nil))
        try await Self.ok(service, .endpointCreate(name: nil, method: .get, path: "/a", spec: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "payment-retry", name: nil))
        try await Self.ok(service, .projectCreate(name: "Second", port: nil))

        let listing = try await Self.ok(service, .projectList)
        let projects = try #require(listing.projects)
        #expect(projects.count == 2)
        let first = try #require(projects.first { $0.name == "First" })
        #expect(first.endpointCount == 1)
        #expect(first.journeyCount == 1)

        try await Self.ok(service, .projectOpen(project: .name("first")))
        let state = try await Self.ok(service, .state)
        #expect(state.state?.project?.name == "First")
    }

    @Test("Opening an unknown project fails with a stable code")
    func openUnknownProject() async throws {
        let service = try Self.makeService()
        let error = await Self.failure(service, .projectOpen(project: .name("nope")))
        #expect(error?.code == "project.notFound")
    }

    @Test("Closing then reopening restores endpoints and journeys from the store")
    func stateSurvivesCloseAndReopen() async throws {
        let service = try Self.makeService()
        let created = try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        let id = try #require(created.project?.id)
        try await Self.ok(service, .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "retry-after-failure", name: nil))
        try await Self.ok(service, .journeyActivate(journey: .name("Retry after failure")))

        try await Self.ok(service, .projectClose)
        #expect(await Self.failure(service, .endpointList)?.code == "project.noneOpen")

        try await Self.ok(service, .projectOpen(project: .id(id)))
        let endpoints = try await Self.ok(service, .endpointList)
        #expect(endpoints.endpoints?.count == 1)
        let status = try await Self.ok(service, .journeyStatus)
        #expect(status.journeyStatus?.totalSteps == 4)
    }

    @Test("Deleting the open project closes it rather than leaving a phantom")
    func deletingOpenProjectClosesIt() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Doomed", port: nil))
        try await Self.ok(service, .projectDelete(project: .name("Doomed")))

        let state = try await Self.ok(service, .state)
        #expect(state.state?.project == nil)
        #expect(await Self.failure(service, .endpointList)?.code == "project.noneOpen")
    }

    @Test("Export and import round-trip a whole configuration, journeys included")
    func exportImportRoundTrip() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: 9100))
        try await Self.ok(service, .endpointCreate(name: nil, method: .get, path: "/inbox", spec: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "session-expiry", name: nil))

        let exported = try #require(try await Self.ok(service, .projectExport(project: nil)).project)

        // A fresh instance, as if the document had been committed and imported elsewhere.
        let other = try Self.makeService()
        try await Self.ok(other, .projectImport(project: exported, activate: true))

        let endpoints = try await Self.ok(other, .endpointList)
        let journeys = try await Self.ok(other, .journeyList)
        #expect(endpoints.endpoints?.count == 1)
        #expect(journeys.journeys?.count == 1)
        #expect(journeys.journeys?.first?.steps.count == 5)
    }

    @Test("Re-importing the same document updates in place, so CI fixtures stay idempotent")
    func importIsIdempotent() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Fixture", port: nil))
        let document = try #require(try await Self.ok(service, .projectExport(project: nil)).project)

        try await Self.ok(service, .projectImport(project: document, activate: false))
        try await Self.ok(service, .projectImport(project: document, activate: false))

        let listing = try await Self.ok(service, .projectList)
        #expect(listing.projects?.count == 1)
    }

    // MARK: - Journeys

    @Test("Activating a journey reports its status and switching starts a fresh run")
    func activateAndSwitchJourneys() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "retry-after-failure", name: "A"))
        try await Self.ok(service, .journeyAddTemplate(templateID: "payment-retry", name: "B"))

        let activated = try await Self.ok(service, .journeyActivate(journey: .name("A")))
        #expect(activated.journey?.name == "A")
        #expect(activated.journeyStatus?.currentStepIndex == 0)

        let switched = try await Self.ok(service, .journeyActivate(journey: .name("B")))
        #expect(switched.journeyStatus?.journeyName == "B")
        #expect(switched.journeyStatus?.currentStepIndex == 0)

        try await Self.ok(service, .journeyActivate(journey: nil))
        #expect(await Self.failure(service, .journeyStatus)?.code == "journey.noneActive")
    }

    @Test("Journey runtime commands require an active journey")
    func runtimeCommandsRequireAnActiveJourney() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))

        for command: ControlCommand in [.journeyStatus, .journeyRestart, .journeyAdvance] {
            #expect(await Self.failure(service, command)?.code == "journey.noneActive")
        }
    }

    @Test("Deleting the active journey clears the selection")
    func deletingActiveJourneyClearsIt() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "mfa-challenge", name: "MFA"))
        try await Self.ok(service, .journeyActivate(journey: .name("MFA")))
        try await Self.ok(service, .journeyDelete(journey: .name("MFA")))

        #expect(await Self.failure(service, .journeyStatus)?.code == "journey.noneActive")
        let state = try await Self.ok(service, .state)
        #expect(state.state?.activeJourney == nil)
    }

    @Test("Editing a journey's steps is reflected in the next status report")
    func editsShowUpInStatus() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        try await Self.ok(service, .journeyCreate(name: "Flow", spec: nil))
        try await Self.ok(service, .journeyActivate(journey: .name("Flow")))

        try await Self.ok(service, .journeyStepAdd(
            journey: .name("Flow"),
            step: JourneyStepSpec(name: "login", method: .post, path: "/login", statusCode: 200),
            atIndex: nil
        ))
        let status = try await Self.ok(service, .journeyStatus)
        #expect(status.journeyStatus?.totalSteps == 1)
        #expect(status.journeyStatus?.steps.first?.name == "login")
    }

    // MARK: - Server lifecycle

    @Test("Starting and stopping the server reports an addressable base URL")
    func serverLifecycle() async throws {
        let service = try Self.makeService()
        let port = try FreePort.next()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: port))

        let started = try await Self.ok(service, .serverStart(port: nil))
        #expect(started.server?.state == "running")
        #expect(started.server?.baseURL == "http://127.0.0.1:\(port)")

        // Starting twice is not an error — a script that ensures the server is up should not have to
        // check first.
        let again = try await Self.ok(service, .serverStart(port: nil))
        #expect(again.server?.state == "running")

        let stopped = try await Self.ok(service, .serverStop)
        #expect(stopped.server?.state == "stopped")
        #expect(stopped.server?.baseURL == nil)

        // Stopping twice is likewise benign.
        try await Self.ok(service, .serverStop)
        await service.shutdown()
    }

    /// Being an actor makes a *statement* atomic, not a sequence of them.
    ///
    /// `if await engine.isRunning` is a question asked across a suspension, and the actor admits the
    /// next command while the answer is in flight — so two `serverStart`s arriving together both
    /// heard "no", both fell through, and the second reached `engine.start`. The engine's own guard
    /// caught it, but as `MockServerError.alreadyRunning`, which the service reports as
    /// `server.startFailed`: a script that ensured the server was up twice in parallel was told its
    /// start had *failed*.
    ///
    /// What is asserted is the outcome set, because the interleaving cannot be forced from here: the
    /// pair must be answered either "running" or `server.busy`, and never as a failed start. Both of
    /// those are answers a caller can act on; `server.startFailed` is not.
    @Test("Two starts at once are answered, never reported as a failed start")
    func concurrentServerStartsAreSerialised() async throws {
        let service = try Self.makeService()
        let port = try FreePort.next()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: port))

        async let first = service.execute(.serverStart(port: nil))
        async let second = service.execute(.serverStart(port: nil))
        let responses = [await first, await second]

        for response in responses {
            #expect(
                response.error?.code != "server.startFailed",
                "a concurrent start was reported as a failure: \(response.error?.message ?? "")"
            )
            #expect(response.error?.code != "server.portInUse")
            if let code = response.error?.code {
                #expect(code == "server.busy", "unexpected refusal: \(code)")
            }
        }
        #expect(responses.contains { $0.ok }, "neither start ran")

        try await Self.ok(service, .serverStop)
        await service.shutdown()
    }

    /// The other half of the same flag, and the reason it has to be *one* flag rather than two: a stop
    /// overlapping a start is the pair that leaves a listener nobody owns, because `engine.stop`
    /// clears the engine's own `app` before it awaits the shutdown.
    @Test("A stop overlapping a start leaves the service and the engine agreeing")
    func concurrentStartAndStopAreSerialised() async throws {
        let service = try Self.makeService()
        let port = try FreePort.next()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: port))

        async let starting = service.execute(.serverStart(port: nil))
        async let stopping = service.execute(.serverStop)
        let responses = [await starting, await stopping]

        for response in responses where response.ok == false {
            #expect(
                response.error?.code == "server.busy",
                "unexpected refusal: \(response.error?.code ?? "none") \(response.error?.message ?? "")"
            )
        }

        // Whatever the ordering, the instance ends up in a state it agrees with: a stop succeeds and
        // the status that follows reports stopped.
        try await Self.ok(service, .serverStop)
        let status = try await Self.ok(service, .serverStatus)
        #expect(status.server?.state == "stopped")
        #expect(status.server?.baseURL == nil)
        await service.shutdown()
    }

    @Test("Configuration changes persist to the project")
    func configurePersists() async throws {
        let service = try Self.makeService()
        let created = try await Self.ok(service, .projectCreate(name: "Checkout", port: 9111))
        let id = try #require(created.project?.id)

        try await Self.ok(service, .serverConfigure(port: 9222, globalDelayMs: 125))
        try await Self.ok(service, .projectClose)
        try await Self.ok(service, .projectOpen(project: .id(id)))

        let status = try await Self.ok(service, .serverStatus)
        #expect(status.server?.port == 9222)
        #expect(status.server?.globalDelayMs == 125)
    }

    @Test("An invalid port is rejected before the server is touched")
    func invalidPortRejected() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        #expect(await Self.failure(service, .serverConfigure(port: 70_000, globalDelayMs: nil))?.code == "request.invalid")
        #expect(await Self.failure(service, .serverStart(port: 0))?.code == "request.invalid")
    }

    // MARK: - Logs and reset

    @Test("Serving requests fills the log, and reset returns the instance to a known state")
    func logsAndReset() async throws {
        let service = try Self.makeService()
        let port = try FreePort.next()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: port))
        try await Self.ok(service, .journeyAddTemplate(templateID: "retry-after-failure", name: "Flow"))
        try await Self.ok(service, .journeyActivate(journey: .name("Flow")))
        try await Self.ok(service, .serverStart(port: nil))
        await service.start()

        let session = URLSession(configuration: .ephemeral)
        for (method, path) in [("POST", "login"), ("GET", "account-summary")] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/\(path)")!)
            request.httpMethod = method
            _ = try? await session.data(for: request)
        }

        // The log arrives over an AsyncStream, so poll rather than assume it has landed.
        var logs: [RequestLog] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            logs = try await Self.ok(service, .logList(limit: nil, unmatchedOnly: nil)).logs ?? []
            if logs.count >= 2 { break }
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(logs.count >= 2)
        #expect(logs.first?.matchedJourneyID != nil)

        let reset = try await Self.ok(service, .reset(scope: .all))
        #expect(reset.state?.requestLogCount == 0)
        #expect(reset.state?.activeJourney?.currentStepIndex == 0)

        try await Self.ok(service, .serverStop)
        await service.shutdown()
    }

    @Test("Reset scopes are independent")
    func resetScopes() async throws {
        let service = try Self.makeService()
        try await Self.ok(service, .projectCreate(name: "Checkout", port: nil))
        try await Self.ok(service, .journeyAddTemplate(templateID: "payment-retry", name: "Pay"))
        try await Self.ok(service, .journeyActivate(journey: .name("Pay")))

        let logsOnly = try await Self.ok(service, .reset(scope: .logs))
        #expect(logsOnly.message?.contains("log") == true)

        let journeyOnly = try await Self.ok(service, .reset(scope: .journey))
        #expect(journeyOnly.state?.activeJourney?.currentStepIndex == 0)
    }
}

/// A free loopback port, so two test runs on one machine cannot collide.
///
/// The `#if` is not ceremony: on Glibc the socket calls live in a different module and `SOCK_STREAM`
/// is `__socket_type` rather than `Int32`. Without it this file is macOS-only, and CI runs on Linux.
enum FreePort {
    static func next() throws -> Int {
        #if canImport(Darwin)
        let streamType = SOCK_STREAM
        let socketFD = Darwin.socket(AF_INET, streamType, 0)
        #else
        let streamType = Int32(SOCK_STREAM.rawValue)
        let socketFD = Glibc.socket(AF_INET, streamType, 0)
        #endif
        guard socketFD >= 0 else { throw PortError.unavailable }
        defer { close(socketFD) }

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                #if canImport(Darwin)
                Darwin.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #else
                Glibc.bind(socketFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                #endif
            }
        }
        guard bound == 0 else { throw PortError.unavailable }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socketFD, $0, &length)
            }
        }
        guard named == 0 else { throw PortError.unavailable }
        return Int(UInt16(bigEndian: boundAddress.sin_port))
    }

    enum PortError: Error { case unavailable }
}
