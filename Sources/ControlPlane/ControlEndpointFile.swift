import Domain
import Foundation

/// How the CLI finds a running Mimic.
///
/// Whoever hosts the control plane writes a small discovery file; the CLI reads it. This exists
/// because the sandboxed app and an unsandboxed CLI do not share a working directory, a port
/// convention, or a process tree — a file in a known location is the one thing both can reach.
/// Search order is deliberate: an explicit `MIMIC_CONTROL_URL` always wins, then the app's sandbox
/// container, then the plain Application Support path a daemon uses. `MIMIC_CONTROL_FILE` displaces
/// the last two entirely rather than joining them — see ``ControlEndpointFile/pathEnvironmentKey``.
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

    /// Environment override for the discovery file's whole path.
    ///
    /// The default path is computed, not chosen — Application Support, the bundle id, `control.json`
    /// — so two instances of the same kind resolve to the *same* file. Two launches of the app bundle
    /// are exactly that, which is what makes an end-to-end script destructive by default: the
    /// instance it launches overwrites the developer's advertisement with its own, and `remove`
    /// deletes it on the way out, leaving a still-running Mimic that no `mimic` command can discover.
    /// `Scripts/run_cli_e2e.sh` already isolates the store with `MIMIC_DATABASE_PATH`; this is the
    /// same isolation for the other file a run touches.
    ///
    /// Read where it is needed rather than cached, and taken as a parameter with a default
    /// everywhere below — the shape `DatabaseFactory.resolveDatabaseURL` uses, so a test can name an
    /// override without mutating the environment of the process running it.
    public static let pathEnvironmentKey = "MIMIC_CONTROL_FILE"

    /// The override's path, tilde-expanded, or `nil` when it is unset or empty.
    ///
    /// Empty is treated as unset, exactly as `DatabaseFactory.resolveDatabaseURL` treats an empty
    /// `MIMIC_DATABASE_PATH`: a shell that exports an unset variable — `MIMIC_CONTROL_FILE="$WORK/…"`
    /// with `WORK` never assigned — must fall back to the real path rather than name a path nobody
    /// chose.
    private static func overrideURL(in environment: [String: String]) -> URL? {
        guard let path = environment[pathEnvironmentKey], !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }

    /// Every location a discovery file may live, most specific first.
    ///
    /// The app is sandboxed, so its "Application Support" is inside its container; a daemon launched
    /// from a shell writes to the real one. A CLI must look in both, because it cannot know which
    /// kind of instance is running.
    ///
    /// `MIMIC_CONTROL_FILE` *replaces* that list rather than joining the front of it. Prepending
    /// would leave a run whose own instance has not advertised yet free to fall through to the
    /// developer's real one and drive it instead — which is precisely what the override exists to
    /// prevent, and the failure would look like a passing test.
    public static func searchURLs(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [URL] {
        if let override = overrideURL(in: environment) { return [override] }
        return [
            homeDirectory
                .appendingPathComponent("Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic", isDirectory: true)
                .appendingPathComponent(fileName),
            homeDirectory
                .appendingPathComponent("Library/Application Support/devxa.Mimic", isDirectory: true)
                .appendingPathComponent(fileName),
        ]
    }

    /// Where *this* process should write its discovery file: wherever `MIMIC_CONTROL_FILE` names, or
    /// alongside its own Application Support, whichever container that resolves to.
    ///
    /// Both branches create the parent directory, and both ask for `0700`: the file inside carries
    /// this instance's token, so a directory somebody else can list is not a place to put it. The
    /// override gets the same treatment as the computed path because it holds the same secret — an
    /// isolated run is not a less sensitive one.
    public static func writeURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = overrideURL(in: environment) {
            try FileManager.default.createDirectory(
                at: override.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
            )
            return override
        }
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let directory = appSupport.appendingPathComponent("devxa.Mimic", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        return directory.appendingPathComponent(fileName)
    }

    /// Writes the discovery file `0600`, and never at any wider mode, even briefly.
    ///
    /// The file carries the instance's token, so its permissions are the access control. A plain
    /// `write(to:options:.atomic)` lands at `0644` under the default umask, which publishes the token
    /// to every account on the machine — on a shared box or a CI host, that is the whole
    /// authentication story undone.
    ///
    /// Chmod-after-write does not fix it, which is what this used to do: `.atomic` writes a temporary
    /// file and renames it into place, so between that rename and the `setAttributes` call the token
    /// is sitting at the final path, readable by anyone who is looking. A loop watching the path wins
    /// that race trivially. Worse, if `setAttributes` threw, the throw left the world-readable file
    /// behind — and `ControlServer` called this through `try?`, so nothing was reported either. That
    /// half is fixed at the call site now: `ControlServer.start` catches what this throws and logs
    /// it. Keep it that way. A hardened write whose caller discards the error is not hardened; it
    /// only moves the silence one frame up.
    ///
    /// So the mode is applied to the temporary file *before* it becomes visible under the real name,
    /// and `rename(2)` — which replaces atomically and carries the source's mode with it — publishes
    /// it. A reader therefore sees either the old file or a complete `0600` one, and never a partial
    /// or a wide one.
    public static func write(
        _ endpoint: ControlEndpoint,
        to url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws {
        let target = try url ?? writeURL(environment: environment)
        let data = try ControlCoding.encoder(pretty: true).encode(endpoint)

        // Same directory, so the rename stays within one filesystem and is therefore atomic.
        let temporary = target.deletingLastPathComponent()
            .appendingPathComponent(".\(target.lastPathComponent).\(ProcessInfo.processInfo.processIdentifier)")

        let manager = FileManager.default
        try? manager.removeItem(at: temporary)
        guard manager.createFile(
            atPath: temporary.path,
            contents: nil,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o600))]
        ) else {
            throw ControlEndpointFileError.couldNotWrite(path: temporary.path)
        }

        do {
            try data.write(to: temporary)
            guard rename(temporary.path, target.path) == 0 else {
                throw ControlEndpointFileError.couldNotWrite(path: target.path)
            }
        } catch {
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    /// Removes the file so a stale endpoint never outlives the process that advertised it.
    ///
    /// Takes the same environment as `writeURL`, so a process that advertised itself at
    /// `MIMIC_CONTROL_FILE` removes *that* file on the way out. Computing the default path here
    /// while the write went to an override is how a run would delete the developer's advertisement
    /// and leave its own behind — the exact pair of mistakes `UITestSupport.databaseURL` exists to
    /// prevent for the store, and the reason both paths come from one function here too.
    public static func remove(
        at url: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        guard let target = try? (url ?? writeURL(environment: environment)) else { return }
        try? FileManager.default.removeItem(at: target)
    }

    /// Reads the first readable discovery file, skipping any whose process is gone — a crashed
    /// instance must not make the CLI hang on a dead port.
    ///
    /// The `MIMIC_CONTROL_FILE` override reaches this through `searchURLs`, so a reader and a writer
    /// sharing an environment cannot disagree about which file they mean.
    public static func discover(
        searchURLs: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isProcessAlive: (Int) -> Bool = ControlEndpointFile.isProcessAlive
    ) -> ControlEndpoint? {
        for url in searchURLs ?? Self.searchURLs(environment: environment) {
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
        // Derived from `port`, not read from `baseURL`.
        //
        // `baseURL` is a decoded field, so a discovery file saying `http://evil.example` would send
        // the caller's `X-Mimic-Token` — the credential this whole file exists to protect — to
        // whatever host it named, while `port` and `pid` still looked reassuringly local. The host
        // is not information the file gets to supply: the control plane binds `127.0.0.1` and
        // nothing else, so the only thing worth reading out of the file is which port.
        if let discovered { return URL(string: "http://127.0.0.1:\(discovered.port)") }
        return nil
    }
}

/// Why a discovery file could not be written.
///
/// Typed rather than a bare `NSError` because the caller — `ControlServer` — has to decide whether an
/// instance that cannot advertise itself should still serve, and "the write failed" and "the rename
/// failed" are the same decision.
public enum ControlEndpointFileError: Error, LocalizedError, Equatable {
    case couldNotWrite(path: String)

    public var errorDescription: String? {
        switch self {
        case let .couldNotWrite(path):
            "Could not write the control discovery file at \(path)."
        }
    }
}
