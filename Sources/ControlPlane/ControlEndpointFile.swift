import Domain
import Foundation

/// How the CLI finds a running Mimic.
///
/// Whoever hosts the control plane writes a small discovery file; the CLI reads it. This exists
/// because the sandboxed app and an unsandboxed CLI do not share a working directory, a port
/// convention, or a process tree — a file in a known location is the one thing both can reach.
/// Search order is deliberate: an explicit `MIMIC_CONTROL_URL` always wins, then the app's sandbox
/// container, then the plain Application Support path a daemon uses.
public struct ControlEndpoint: Codable, Sendable, Equatable {
    public var apiVersion: String
    public var port: Int
    public var pid: Int
    /// `app` or `headless`.
    public var mode: String
    public var baseURL: String
    /// The per-instance token a caller must present as `X-Mimic-Token`.
    ///
    /// Carried in the discovery file on purpose: the file is the thing a local CLI can read and a web
    /// page cannot, which is what makes it usable as a credential. It is written `0600` so it is also
    /// the thing *another user on this machine* cannot read.
    ///
    /// Optional on decode so a CLI can give a clear "upgrade the app" message when it meets a file
    /// written by an older instance, instead of failing to parse it.
    public var token: String?

    public init(
        apiVersion: String = ControlAPI.version,
        port: Int,
        pid: Int,
        mode: String,
        token: String? = nil
    ) {
        self.apiVersion = apiVersion
        self.port = port
        self.pid = pid
        self.mode = mode
        self.baseURL = "http://127.0.0.1:\(port)"
        self.token = token
    }
}

/// Mints the per-instance token.
///
/// A fresh token per process, never persisted beyond the discovery file: an instance that has exited
/// cannot have its credential replayed against the next one, and there is no long-lived secret on
/// disk to leak.
public enum ControlToken {
    /// 32 bytes of system randomness, hex-encoded. `SystemRandomNumberGenerator` is the platform CSPRNG
    /// (`arc4random_buf` on Darwin, `getrandom` on Linux).
    public static func generate() -> String {
        var generator = SystemRandomNumberGenerator()
        return (0..<4)
            .map { _ in String(format: "%016lx", generator.next() as UInt64) }
            .joined()
    }

    /// Compares in time independent of where the first difference falls.
    ///
    /// The control plane is loopback-only, so a remote timing attack is not the concern; a local
    /// process that can already time this precisely has easier routes. It is written this way because
    /// a token comparison that short-circuits is the kind of detail that gets copied into somewhere it
    /// does matter.
    public static func matches(_ presented: String?, expected: String) -> Bool {
        guard let presented else { return false }
        let lhs = Array(presented.utf8)
        let rhs = Array(expected.utf8)
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for index in lhs.indices {
            difference |= lhs[index] ^ rhs[index]
        }
        return difference == 0
    }
}

public enum ControlEndpointFile {
    public static let fileName = "control.json"

    /// Every location a discovery file may live, most specific first.
    ///
    /// The app is sandboxed, so its "Application Support" is inside its container; a daemon launched
    /// from a shell writes to the real one. A CLI must look in both, because it cannot know which
    /// kind of instance is running.
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

    /// Where *this* process should write its discovery file: alongside its own Application Support,
    /// whichever container that resolves to.
    public static func writeURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("devxa.Mimic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(fileName)
    }

    /// Writes the discovery file `0600`.
    ///
    /// The file carries the instance's token, so its permissions are the access control. A plain
    /// `write(to:options:.atomic)` lands at `0644` under the default umask, which publishes the token
    /// to every account on the machine — on a shared box or a CI host, that is the whole authentication
    /// story undone. `.atomic` writes via a temporary file and renames, so the mode has to be applied
    /// after the rename, not before.
    public static func write(_ endpoint: ControlEndpoint, to url: URL? = nil) throws {
        let target = try url ?? writeURL()
        let data = try ControlCoding.encoder(pretty: true).encode(endpoint)
        try data.write(to: target, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o600))],
            ofItemAtPath: target.path
        )
    }

    /// Removes the file so a stale endpoint never outlives the process that advertised it.
    public static func remove(at url: URL? = nil) {
        guard let target = try? (url ?? writeURL()) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Reads the first readable discovery file, skipping any whose process is gone — a crashed
    /// instance must not make the CLI hang on a dead port.
    public static func discover(
        searchURLs: [URL]? = nil,
        isProcessAlive: (Int) -> Bool = ControlEndpointFile.isProcessAlive
    ) -> ControlEndpoint? {
        for url in searchURLs ?? Self.searchURLs() {
            guard let data = try? Data(contentsOf: url),
                  let endpoint = try? ControlCoding.decode(ControlEndpoint.self, from: data)
            else { continue }
            guard isProcessAlive(endpoint.pid) else { continue }
            return endpoint
        }
        return nil
    }

    /// `kill(pid, 0)` succeeds for a live process and fails with `ESRCH` for a dead one.
    /// An `EPERM` means the process exists but is owned by someone else — still alive.
    public static func isProcessAlive(_ pid: Int) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid_t(pid), 0) == 0 { return true }
        return errno == EPERM
    }

    /// Resolves the base URL a client should use, honouring the environment override first.
    public static func resolveBaseURL(
        explicit: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discovered: ControlEndpoint? = nil
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
}
