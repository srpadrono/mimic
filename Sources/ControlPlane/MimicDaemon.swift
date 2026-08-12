import Domain
import Foundation
import MockServerEngine
import Persistence

/// Composition root for a windowless Mimic.
///
/// **Nothing in a shipped path reaches this.** `mimic daemon start` sounds like the caller and is
/// not: `DaemonCommand.Start` sets `headless = true` on an `AppCommand.Start` and runs it, that
/// reaches `AppLauncher.launch(headless:)`, and `launch` puts `MIMIC_HEADLESS=1` in the child
/// environment and executes `Mimic.app/Contents/MacOS/Mimic`. So a headless instance is the app
/// bundle, and `ControlPlaneCoordinator` gives it the same `AppControlHost` a windowed one gets.
///
/// Nothing else names this type either. `grep -rn MimicDaemon --include=*.swift .` returns two
/// lines, both in this file: the one you are reading and the declaration below. No production code,
/// no test, and no executable — `Package.swift` declares exactly one, `mimic`, whose only dependency
/// is `MimicCLICore`.
///
/// It is still compiled by both manifests, and it is the only place the headless composition is
/// written down, which is why it stays. What it composes splits along the same line everything else
/// in this repository does: `MimicControlService` lives in this target, so `Package.swift` builds it
/// and the six references in `Tests/ControlPlaneTests` drive it, while `AppControlHost` lives in
/// `Sources/AppFeatures`, which no `Package.swift` target declares. `Tests/MimicTests` — where
/// `HostParityTests.swift` asks both hosts the same questions side by side — is undeclared there
/// too, so that suite runs under Xcode only and never on the Linux job. Neither suite touches this
/// type; keeping the two hosts in agreement is what would make wiring this up a small change, and
/// nothing here proves they are. See the "two hosts" section of AGENTS.md before changing either.
public struct MimicDaemon: Sendable {

    public struct Configuration: Sendable {
        public var controlPort: Int
        public var databasePath: String?
        /// Open this project on launch instead of whatever was open last.
        public var openProjectName: String?
        /// Start the mock server immediately, so one command yields a serving instance.
        public var startMockServer: Bool
        public var advertise: Bool

        public init(
            controlPort: Int = ControlAPI.defaultPort,
            databasePath: String? = nil,
            openProjectName: String? = nil,
            startMockServer: Bool = false,
            advertise: Bool = true
        ) {
            self.controlPort = controlPort
            self.databasePath = databasePath
            self.openProjectName = openProjectName
            self.startMockServer = startMockServer
            self.advertise = advertise
        }
    }

    public struct Running: Sendable {
        public let service: MimicControlService
        public let server: ControlServer
        public let controlPort: Int
    }

    /// Starts the service and the control API. The caller decides how to wait — a CLI parks on a
    /// signal, a test simply runs assertions and calls `shutdown`.
    public static func start(_ configuration: Configuration) async throws -> Running {
        var environment = ProcessInfo.processInfo.environment
        if let databasePath = configuration.databasePath {
            environment[DatabaseFactory.databasePathEnvironmentKey] = databasePath
        }

        let dbQueue = try DatabaseFactory.makeAppDatabaseQueue(environment: environment)
        let repository = GRDBProjectRepository(dbQueue: dbQueue)
        let settings = SettingsStore(dbQueue: dbQueue)

        let service = MimicControlService(
            repository: repository,
            settings: settings,
            engine: MockServerEngine(),
            mode: "headless"
        )
        await service.start()

        if let name = configuration.openProjectName {
            let response = await service.execute(.projectOpen(project: .name(name)))
            guard response.ok else {
                throw ControlError(
                    code: response.error?.code ?? "project.notFound",
                    message: response.error?.message ?? "Could not open project \"\(name)\"."
                )
            }
        }

        if configuration.startMockServer {
            let response = await service.execute(.serverStart(port: nil))
            guard response.ok else {
                throw ControlError(
                    code: response.error?.code ?? "server.startFailed",
                    message: response.error?.message ?? "Could not start the mock server."
                )
            }
        }

        let server = ControlServer(host: service, mode: "headless")
        let port = try await server.start(port: configuration.controlPort, advertise: configuration.advertise)

        return Running(service: service, server: server, controlPort: port)
    }

    public static func shutdown(_ running: Running) async {
        try? await running.server.stop()
        await running.service.shutdown()
    }
}
