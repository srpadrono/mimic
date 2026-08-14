// `kill(2)`, `errno` and `EPERM` are C, reached through Foundation, which re-exports Darwin on
// Apple platforms and Glibc on Linux. Deliberately not an explicit `#if canImport(Darwin)` pair:
// Domain's contract (docs/ARCHITECTURE.md) is "imports Foundation only", and both prior homes of
// this code — `ControlPlane` and `MimicCLICore` — compiled exactly this call set through a bare
// `import Foundation` on both CI platforms. If a symbol here ever stops resolving on Linux,
// `Tests/MockServerEngineTests/PlatformSockets.swift` shows the repo's seam pattern to reach for.
import Foundation

/// What a running instance advertises about itself: the discovery-file record.
///
/// Whoever hosts the control plane writes a small discovery file; a client reads it. This exists
/// because the sandboxed app and an unsandboxed CLI do not share a working directory, a port
/// convention, or a process tree — a file in a known location is the one thing both can reach.
///
/// The type lives in `Domain` because both sides of the handshake need it and neither may depend on
/// the other: `ControlPlane` writes it (see `ControlEndpointFile` there), and `MimicCLICore` reads
/// it through ``ControlEndpointDiscovery`` — the CLI links no `ControlPlane`, and the module-edge
/// gate (`Scripts/check_module_edges.py`) keeps it that way. The format used to be declared twice,
/// once per module, and the two copies drifted in both directions; this is the one declaration.
public struct ControlEndpoint: Codable, Sendable, Equatable {
    public var apiVersion: String
    public var port: Int
    public var pid: Int
    /// `app` or `headless`.
    public var mode: String
    /// What the instance *said* its base URL was. Encoded so the record round-trips, and never
    /// routed on — ``ControlEndpointDiscovery/resolveBaseURL(explicit:environment:discovered:)``
    /// derives the host from `port` instead, because a file that gets to name the host is a file
    /// that can send the token off-box. Do not route on it.
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

/// How a client finds a running Mimic: the read half of the discovery-file contract, implemented
/// once.
///
/// This is a credential seam, and it used to be implemented twice — a reader in `ControlPlane` and a
/// second copy in `MimicCLICore`, because the CLI links no Vapor — and the two had already drifted in
/// both directions: `MIMIC_CONTROL_FILE` was honoured only by the control plane's copy, so an
/// isolated CLI run silently fell back to the developer's real instance paths, while the
/// token-pairing hardening (``resolveToken(environment:discovered:)`` +
/// ``namesDiscoveredInstance(_:_:)``) existed only in the CLI's. Everything here is Foundation-only,
/// which is what makes `Domain` the one legal home: the CLI may link it, the control plane already
/// does, and `Scripts/check_module_edges.py` forbids every other arrangement.
///
/// The *write* half — mode discipline, `rename(2)` publication, removal — stays in `ControlPlane`'s
/// `ControlEndpointFile`, which delegates its path resolution here so a writer and a reader sharing
/// an environment cannot disagree about which file they mean.
public enum ControlEndpointDiscovery {
    public static let fileName = "control.json"

    /// Environment override for the discovery file's whole path.
    ///
    /// The default path is computed, not chosen — Application Support, the bundle id, `control.json`
    /// — so two instances of the same kind resolve to the *same* file. Two launches of the app bundle
    /// are exactly that, which is what makes an end-to-end script destructive by default: the
    /// instance it launches overwrites the developer's advertisement with its own, and the writer's
    /// `remove` deletes it on the way out, leaving a still-running Mimic that no `mimic` command can
    /// discover. `Scripts/run_cli_e2e.sh` already isolates the store with `MIMIC_DATABASE_PATH`;
    /// this is the same isolation for the other file a run touches.
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
    ///
    /// Public because the write side needs the same answer: `ControlEndpointFile.writeURL` in
    /// `ControlPlane` resolves the override through this, so the file a run writes and the file a
    /// run reads cannot drift apart.
    public static func overrideURL(in environment: [String: String]) -> URL? {
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

    /// Reads the first readable discovery file, skipping any whose process is gone — a crashed
    /// instance must not make a client hang on a dead port.
    ///
    /// The `MIMIC_CONTROL_FILE` override reaches this through `searchURLs`, so a reader and a writer
    /// sharing an environment cannot disagree about which file they mean.
    ///
    /// The liveness check is a parameter because a test cannot name a pid it can guarantee is dead:
    /// pick a plausible-looking one and the kernel is free to hand it to somebody between the
    /// fixture being written and the file being read, so the assertion passes or fails depending on
    /// what else the machine is doing.
    ///
    /// The `try?` on the decode is safe for the reason the format probe in `ControlClient.send` is:
    /// every field of ``ControlEndpoint`` except `token` is non-optional on a synthesized decoder,
    /// so a file that decodes really does carry the `pid` this checks and the `port` resolution
    /// derives from. `token` is Optional deliberately — a pre-token instance's file still decodes,
    /// so the CLI can say "that Mimic is too old" instead of "unexpected response".
    public static func discover(
        searchURLs: [URL]? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        isProcessAlive: (Int) -> Bool = ControlEndpointDiscovery.isProcessAlive
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

    /// Resolves the base URL a client should use: an explicit URL, then the environment, then the
    /// discovery file.
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
        // Derived from `port`, never read from `baseURL`.
        //
        // This line used to be `URL(string: discovered.baseURL)`, and `baseURL` is a decoded field of
        // a file on disk. So a discovery file saying `http://evil.example` decided where the next
        // command went, and the caller then put this instance's `X-Mimic-Token` — the credential the
        // whole scheme exists to protect — in a header addressed to it, while `port` and `pid` sat
        // alongside still looking reassuringly local. The host is not something the file gets to
        // supply: the control plane binds `127.0.0.1` and nothing else, so the only thing worth
        // reading out of that file is which port it landed on.
        if let discovered { return URL(string: "http://127.0.0.1:\(discovered.port)") }
        return nil
    }

    /// The token to present, environment first.
    ///
    /// The environment wins so that a caller who reached the instance via `MIMIC_CONTROL_URL` — a
    /// forwarded port, a container — can supply the matching token the same way. Otherwise it comes
    /// from the discovery file, which is the normal path and needs no configuration at all.
    ///
    /// **Passing `discovered` asserts that the file describes where this request is going.** This
    /// function does not check that and cannot: it never sees the destination. `ControlClient.discover`
    /// in `MimicCLICore` is where the two meet, and it passes `nil` here whenever
    /// ``namesDiscoveredInstance(_:_:)`` says no. Do not call this with a `discovered` you have not
    /// matched against the URL you are about to dial: that pairing is the defect
    /// ``namesDiscoveredInstance(_:_:)`` describes.
    public static func resolveToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        discovered: ControlEndpoint? = nil
    ) -> String? {
        if let override = environment[ControlAPI.tokenEnvironmentKey], !override.isEmpty {
            return override
        }
        return discovered?.token
    }

    /// Whether `url` is the loopback endpoint `discovered` describes — the one place a token read out
    /// of that file may be sent.
    ///
    /// Resolution answered two questions independently and hardened only one of them. `resolveBaseURL`
    /// returns an explicit `--url` (or `MIMIC_CONTROL_URL`) verbatim, with no check on its host, while
    /// `resolveToken` fell back to whatever the *local* instance's `control.json` carried. So
    /// `mimic state --url http://attacker.example` put this machine's live control-plane credential
    /// into an `X-Mimic-Token` header addressed to that host — in a reader that already refuses, in
    /// `resolveBaseURL` above, to route on the `baseURL` a file names, for exactly this reason.
    ///
    /// A locally discovered token is a credential *for one instance*, so both halves have to match: a
    /// loopback host, and the port that instance advertised. Anything else gets no token — a remote
    /// host, a loopback-shaped name like `127.0.0.1.evil.example`, or another port on this machine,
    /// which is some other process. The request then either needs none or comes back `401`, which
    /// `ControlClient.send` reports with the message that names the header and the file.
    ///
    /// The legitimate local case still works: `--url http://127.0.0.1:<port>` naming the running
    /// instance is the same host and the same port the file advertises, so it carries the token. And a
    /// caller genuinely reaching Mimic through a forwarded port or a container supplies the token the
    /// documented way, with `MIMIC_CONTROL_TOKEN`, which `resolveToken` takes first and this does not
    /// touch — that is the caller naming a credential rather than the CLI guessing one.
    ///
    /// Compared against `url.host` rather than against the URL string, so a loopback spelling that
    /// appears anywhere *other* than the host — in userinfo, in a path, in a query — is not a
    /// loopback host.
    public static func namesDiscoveredInstance(_ url: URL, _ discovered: ControlEndpoint?) -> Bool {
        guard let discovered,
              let host = url.host?.lowercased(),
              loopbackHosts.contains(host)
        else { return false }
        return url.port == discovered.port
    }

    /// The spellings of "this machine" a control URL can carry: the two loopback literals and the
    /// name for them a person types. The IPv6 one is listed with and without its brackets so the
    /// check does not turn on whether `URL.host` strips them.
    ///
    /// Deliberately not the whole `127.0.0.0/8` range. Nothing derives an address anywhere else —
    /// `resolveBaseURL` writes `127.0.0.1` and the control plane binds `127.0.0.1` — so admitting
    /// the rest would widen where a token may go for no case that exists.
    private static let loopbackHosts: Set<String> = ["127.0.0.1", "::1", "[::1]", "localhost"]
}
