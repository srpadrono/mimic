import Domain
import Foundation
#if canImport(FoundationNetworking)
// URLSession lives in FoundationNetworking on Linux, not Foundation. Without this the CLI and the
// tests that speak HTTP do not compile there — and CI runs on Linux.
import FoundationNetworking
#endif

/// Talks to a running Mimic over the loopback control API.
///
/// The CLI is a *client only* — it holds no state, no database, and no server. That is what makes it
/// safe for an agent to call from anywhere: every invocation reads and writes the one live instance,
/// so two commands issued a second apart cannot disagree about the world.
public struct ControlClient: Sendable {

    public let baseURL: URL
    private let session: URLSession
    /// The instance's token, read from its discovery file or the environment.
    private let token: String?

    public init(baseURL: URL, timeout: TimeInterval = 30, token: String? = nil) {
        self.baseURL = baseURL
        self.token = token
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        session = URLSession(configuration: configuration)
    }

    /// Resolves how to reach an instance: an explicit URL, then the environment, then the discovery
    /// file. Fails with actionable advice rather than a connection error, because "nothing is running"
    /// is by far the most common reason a command cannot proceed.
    public static func discover(
        explicitURL: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 30
    ) throws -> ControlClient {
        let endpoint = ControlEndpointFileReader.discover()
        guard let url = ControlEndpointFileReader.resolveBaseURL(
            explicit: explicitURL,
            environment: environment,
            discovered: endpoint
        ) else {
            throw CLIFailure.noInstance
        }
        return ControlClient(
            baseURL: url,
            timeout: timeout,
            token: ControlEndpointFileReader.resolveToken(
                environment: environment,
                discovered: endpoint
            )
        )
    }

    public func send(_ command: ControlCommand) async throws -> ControlResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/command"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&request)
        request.httpBody = try ControlCoding.encoder().encode(command)

        let data: Data
        do {
            (data, _) = try await session.data(for: request)
        } catch {
            throw CLIFailure.unreachable(baseURL: baseURL, underlying: error.localizedDescription)
        }

        do {
            return try ControlCoding.decode(ControlResponse.self, from: data)
        } catch {
            throw CLIFailure.undecodable(String(decoding: data, as: UTF8.self))
        }
    }

    /// True when an instance answers. Used by `mimic app start` to wait for readiness rather than
    /// sleeping a guessed number of seconds.
    ///
    /// A `401` counts as reachable: the instance is up and serving, and reporting "not running" for
    /// what is really a token mismatch would send the user off restarting an app that is already fine.
    /// `send` will then fail with the message that names the actual problem.
    public func isReachable() async -> Bool {
        var request = URLRequest(url: baseURL.appendingPathComponent("\(ControlAPI.version)/health"))
        request.httpMethod = "GET"
        request.timeoutInterval = 2
        authorize(&request)
        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return status == 200 || status == 401
        } catch {
            return false
        }
    }

    private func authorize(_ request: inout URLRequest) {
        guard let token else { return }
        request.setValue(token, forHTTPHeaderField: ControlAPI.tokenHeaderName)
    }
}

/// Indirection so `MimicCLICore` does not need to link the control-plane module (and therefore
/// Vapor) just to locate an instance. The discovery format is part of the Domain contract.
public enum ControlEndpointFileReader {
    public static let fileName = "control.json"

    public struct Endpoint: Codable, Sendable, Equatable {
        public var apiVersion: String
        public var port: Int
        public var pid: Int
        public var mode: String
        public var baseURL: String
        /// Optional so a file written by a pre-token instance still decodes, and the CLI can say
        /// "that Mimic is too old" instead of "unexpected response".
        public var token: String?
    }

    public static func searchURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        [
            homeDirectory
                .appendingPathComponent("Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic", isDirectory: true)
                .appendingPathComponent(fileName),
            homeDirectory
                .appendingPathComponent("Library/Application Support/devxa.Mimic", isDirectory: true)
                .appendingPathComponent(fileName),
        ]
    }

    public static func discover(searchURLs: [URL]? = nil) -> Endpoint? {
        for url in searchURLs ?? Self.searchURLs() {
            guard let data = try? Data(contentsOf: url),
                  let endpoint = try? ControlCoding.decode(Endpoint.self, from: data)
            else { continue }
            guard isProcessAlive(endpoint.pid) else { continue }
            return endpoint
        }
        return nil
    }

    /// A discovery file left behind by a crashed instance must not make the CLI hang on a dead port.
    public static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    public static func resolveBaseURL(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discovered: Endpoint? = nil
    ) -> URL? {
        if let explicit, let url = URL(string: explicit) { return url }
        if let override = environment[ControlAPI.urlEnvironmentKey], !override.isEmpty {
            return URL(string: override)
        }
        if let port = environment[ControlAPI.portEnvironmentKey], let value = Int(port) {
            return URL(string: "http://127.0.0.1:\(value)")
        }
        if let discovered { return URL(string: discovered.baseURL) }
        return nil
    }

    /// The token to present, environment first.
    ///
    /// The environment wins so that a caller who reached the instance via `MIMIC_CONTROL_URL` — a
    /// forwarded port, a container — can supply the matching token the same way. Otherwise it comes
    /// from the discovery file, which is the normal path and needs no configuration at all.
    public static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discovered: Endpoint? = nil
    ) -> String? {
        if let override = environment[ControlAPI.tokenEnvironmentKey], !override.isEmpty {
            return override
        }
        return discovered?.token
    }
}

/// Failures that belong to the CLI itself rather than to a command.
public enum CLIFailure: Error, LocalizedError, Equatable {
    case noInstance
    case unreachable(baseURL: URL, underlying: String)
    case undecodable(String)
    case commandFailed(ControlError)
    case badArgument(String)
    case fileUnreadable(path: String, underlying: String)

    public var errorDescription: String? {
        switch self {
        case .noInstance:
            """
            No running Mimic found.
            Start one with `mimic app start` (the GUI) or `mimic daemon start` (headless),
            or point at an instance with MIMIC_CONTROL_URL or --url.
            """
        case let .unreachable(baseURL, underlying):
            "Could not reach Mimic at \(baseURL.absoluteString): \(underlying)"
        case let .undecodable(payload):
            "Unexpected response from Mimic: \(payload)"
        case let .commandFailed(error):
            "\(error.code): \(error.message)"
        case let .badArgument(message):
            message
        case let .fileUnreadable(path, underlying):
            "Could not read \(path): \(underlying)"
        }
    }

    /// Exit codes are part of the contract: a script branches on them without parsing output.
    /// `2` means "the command was wrong", `3` means "no instance", `4` means "the command failed".
    public var exitCode: Int32 {
        switch self {
        case .badArgument, .undecodable: 2
        case .noInstance, .unreachable: 3
        case .commandFailed, .fileUnreadable: 4
        }
    }
}
