import Domain
import Foundation
import MockServerEngine
import Persistence

/// Composition root for a windowless Mimic.
///
/// `mimic daemon start` is the whole reason this exists: a CI job or an agent needs the full engine,
/// the project store, and the control API without a window or a logged-in GUI session. It wires the
/// same pieces the app does, in the same order, so behaviour does not fork between the two.
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
