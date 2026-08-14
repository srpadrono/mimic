import Foundation
import Testing
@testable import Domain

/// The read half of the discovery-file contract, tested against the one implementation of it.
///
/// This suite is the merge of two that used to exist — one in `ControlPlaneTests` against the
/// control plane's reader, one in `MimicCLICoreTests` against the CLI's copy — because the reader
/// itself was implemented twice and the copies drifted in both directions: `MIMIC_CONTROL_FILE` was
/// honoured only by the copy no production binary read through, and the token-pairing hardening
/// existed only in the CLI's. `ControlEndpointDiscovery` in `Domain` is now the single reader, so a
/// case asserted here is asserted about what `mimic` runs *and* what any future in-repo client runs.
/// The write side — publication, `0600`, the writer's half of the override — stays with
/// `ControlEndpointFile` in `ControlPlaneTests`.
///
/// Every case passes `environment:` explicitly. The resolvers default it to the real process
/// environment, so a test that omits it passes or fails depending on whether the developer running
/// it happens to have `MIMIC_CONTROL_URL` or `MIMIC_CONTROL_FILE` exported — which
/// `Scripts/run_cli_e2e.sh` sets, and a shell keeps.
@Suite("Control endpoint discovery")
struct ControlEndpointDiscoveryTests {

    // MARK: - Fixtures

    /// A discovery file written the way a real instance writes one: JSON on disk, decoded through
    /// the same path every client uses. Constructing a `ControlEndpoint` in memory would skip the
    /// decode, and the decode is where a hostile value gets in.
    private func writeDiscoveryFile(
        in directory: URL,
        port: Int,
        pid: Int,
        baseURL: String,
        token: String = "not-a-real-token"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ControlEndpointDiscovery.fileName)
        let json = """
        {
          "apiVersion": "\(ControlAPI.version)",
          "port": \(port),
          "pid": \(pid),
          "mode": "headless",
          "baseURL": "\(baseURL)",
          "token": "\(token)"
        }
        """
        try Data(json.utf8).write(to: url)
        return url
    }

    private func temporaryDirectory(_ label: String) -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-\(label)-\(UUID().uuidString)", isDirectory: true)
    }

    /// An endpoint whose `baseURL` field says whatever the test needs it to say — the shape a
    /// tampered or hand-edited file decodes to. The public initialiser derives `baseURL` from the
    /// port on purpose, so the field is set afterwards, the way a decode sets it.
    private func endpoint(port: Int, pid: Int = 1, baseURL: String? = nil, token: String? = "not-a-real-token") -> ControlEndpoint {
        var endpoint = ControlEndpoint(port: port, pid: pid, mode: "app", token: token)
        if let baseURL { endpoint.baseURL = baseURL }
        return endpoint
    }

    // MARK: - Search paths

    @Test("The sandboxed container is searched before the plain Application Support path")
    func searchOrderPrefersTheAppContainer() {
        let urls = ControlEndpointDiscovery.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [:]
        )
        #expect(urls.count == 2)
        #expect(urls[0].path.contains("Library/Containers/devxa.Mimic"))
        #expect(urls[1].path.contains("Library/Application Support/devxa.Mimic"))
        #expect(urls.allSatisfy { $0.lastPathComponent == ControlEndpointDiscovery.fileName })
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
        let urls = ControlEndpointDiscovery.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [ControlEndpointDiscovery.pathEnvironmentKey: override]
        )

        #expect(urls.map(\.path) == [override])
        #expect(urls.contains { $0.path.contains("Library/Application Support/devxa.Mimic") } == false)
    }

    /// An exported-but-unassigned variable — `MIMIC_CONTROL_FILE="$WORK/control.json"` in a script
    /// where `WORK` was never set — must read as "not overridden" rather than as a path nobody chose.
    /// `DatabaseFactory.resolveDatabaseURL` treats an empty `MIMIC_DATABASE_PATH` the same way.
    @Test("An empty override falls back to the real search list")
    func emptyOverrideIsIgnored() {
        let urls = ControlEndpointDiscovery.searchURLs(
            homeDirectory: URL(fileURLWithPath: "/Users/test"),
            environment: [ControlEndpointDiscovery.pathEnvironmentKey: ""]
        )
        #expect(urls.count == 2)
    }

    /// A tilde is what a person types when they name a path in a shell profile, and `URL(fileURLWithPath:)`
    /// does not expand it — a literal `~` directory would be created in the working directory instead.
    @Test("A tilde in the override is expanded")
    func overrideExpandsTilde() {
        let urls = ControlEndpointDiscovery.searchURLs(
            environment: [ControlEndpointDiscovery.pathEnvironmentKey: "~/mimic/control.json"]
        )
        #expect(urls.count == 1)
        #expect(urls[0].path.hasPrefix("/"))
        #expect(urls[0].path.contains("~") == false)
        #expect(urls[0].lastPathComponent == "control.json")
    }

    /// The end-to-end shape of the override, through `discover` itself: a file at the path the
    /// environment names is found, without `searchURLs` being spelled out at the call site. This is
    /// the case that regresses if `discover` stops threading its environment into the search — which
    /// is exactly the defect the CLI's old copy of this reader shipped with: it read only the two
    /// default paths, so an isolated run's `mimic` silently went looking for the developer's real
    /// instance.
    @Test("discover honours MIMIC_CONTROL_FILE from the environment it is given")
    func discoverHonoursTheOverride() throws {
        let directory = temporaryDirectory("override-discover")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeDiscoveryFile(
            in: directory,
            port: 8911,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            baseURL: "http://127.0.0.1:8911"
        )

        let discovered = ControlEndpointDiscovery.discover(
            environment: [ControlEndpointDiscovery.pathEnvironmentKey: url.path]
        )
        #expect(discovered?.port == 8911)
        #expect(discovered?.token == "not-a-real-token")
    }

    // MARK: - Resolution order

    @Test("An explicit URL beats the environment, which beats the discovery file")
    func resolutionOrder() {
        let discovered = endpoint(port: 1111, baseURL: "http://evil.example")

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            explicit: "http://127.0.0.1:3333",
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:3333")

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:2222")

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            environment: [ControlAPI.portEnvironmentKey: "4444"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:4444")

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            environment: [:],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")

        #expect(ControlEndpointDiscovery.resolveBaseURL(environment: [:], discovered: nil) == nil)
    }

    /// `export MIMIC_CONTROL_URL=` in a shell profile sets the variable to the empty string rather
    /// than unsetting it, and a caller in that shell must still find the running instance instead of
    /// being told nothing is there.
    @Test("An exported-but-empty override falls through instead of resolving to nothing")
    func emptyOverridesAreSkipped() {
        let discovered = endpoint(port: 1111)

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            environment: [ControlAPI.urlEnvironmentKey: ""],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")

        #expect(ControlEndpointDiscovery.resolveBaseURL(
            environment: [ControlAPI.portEnvironmentKey: "not-a-number"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")
    }

    // MARK: - The tampered file

    /// A discovery file is a file on disk, and `baseURL` is a field in it. Anything that can write
    /// the file could name any host it liked there, and the resolver used to hand that string
    /// straight to `URL(string:)` — so the next command put `X-Mimic-Token` in a header addressed to
    /// whatever the file chose, with `port` and `pid` sitting beside it still looking local. The
    /// host is derived from `port`, never read from `baseURL`.
    @Test("A tampered baseURL in a discovery file cannot redirect the caller off loopback")
    func tamperedBaseURLCannotRedirect() throws {
        let directory = temporaryDirectory("tampered")
        defer { try? FileManager.default.removeItem(at: directory) }

        // The current process, so the liveness check is the real one and the file is not skipped for
        // an unrelated reason.
        let url = try writeDiscoveryFile(
            in: directory,
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            baseURL: "http://evil.example:80"
        )

        let discovered = try #require(ControlEndpointDiscovery.discover(searchURLs: [url]))
        // The field still decodes as written — the fix is not that the value is scrubbed, it is that
        // nothing routes on it.
        #expect(discovered.baseURL == "http://evil.example:80")

        let resolved = try #require(ControlEndpointDiscovery.resolveBaseURL(
            explicit: nil,
            environment: [:],
            discovered: discovered
        ))
        #expect(resolved.absoluteString == "http://127.0.0.1:8787")
    }

    /// A host that is loopback-shaped but not loopback is the same attack with better manners:
    /// `127.0.0.1.evil.example` reads as local at a glance and resolves to whatever its owner wants.
    @Test("A loopback-looking hostname in the file is ignored just as completely")
    func loopbackShapedHostIsIgnored() throws {
        let discovered = endpoint(port: 8787, baseURL: "http://127.0.0.1.evil.example:8787")

        let resolved = try #require(ControlEndpointDiscovery.resolveBaseURL(
            explicit: nil,
            environment: [:],
            discovered: discovered
        ))
        #expect(resolved.absoluteString == "http://127.0.0.1:8787")
    }

    // MARK: - Liveness

    @Test("A discovery file left by a crashed instance is skipped rather than dialled")
    func staleFileIsSkipped() throws {
        let directory = temporaryDirectory("stale")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeDiscoveryFile(in: directory, port: 8787, pid: 999_999, baseURL: "http://127.0.0.1:8787")

        // The liveness check is injected because a test cannot name a pid it can guarantee is dead:
        // the kernel is free to hand 999999 to something between the file being written and read.
        #expect(ControlEndpointDiscovery.discover(searchURLs: [url], isProcessAlive: { _ in false }) == nil)
        #expect(ControlEndpointDiscovery.discover(searchURLs: [url], isProcessAlive: { _ in true }) != nil)
    }

    @Test("The current process reads as alive; pid 0 and a negative pid never do")
    func livenessCheck() {
        #expect(ControlEndpointDiscovery.isProcessAlive(Int(ProcessInfo.processInfo.processIdentifier)))
        #expect(ControlEndpointDiscovery.isProcessAlive(0) == false)
        #expect(ControlEndpointDiscovery.isProcessAlive(-1) == false)
    }

    @Test("A file that is not a discovery file is stepped over, not fatal")
    func unreadableFileIsSkipped() throws {
        let directory = temporaryDirectory("garbage")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let garbage = directory.appendingPathComponent("control.json")
        try Data("not json".utf8).write(to: garbage)
        let good = try writeDiscoveryFile(
            in: directory.appendingPathComponent("second", isDirectory: true),
            port: 8787,
            pid: Int(ProcessInfo.processInfo.processIdentifier),
            baseURL: "http://127.0.0.1:8787"
        )

        #expect(ControlEndpointDiscovery.discover(searchURLs: [garbage]) == nil)
        #expect(ControlEndpointDiscovery.discover(searchURLs: [garbage, good])?.port == 8787)
    }

    // MARK: - Tokens

    /// The environment wins so a caller who reached the instance through `MIMIC_CONTROL_URL` — a
    /// forwarded port, a container — can supply the matching token the same way.
    @Test("The environment's token beats the file's, and an empty one is not a token")
    func tokenResolution() {
        let discovered = endpoint(port: 8787, token: "from-the-file")

        #expect(ControlEndpointDiscovery.resolveToken(
            environment: [ControlAPI.tokenEnvironmentKey: "from-the-environment"],
            discovered: discovered
        ) == "from-the-environment")

        #expect(ControlEndpointDiscovery.resolveToken(environment: [:], discovered: discovered) == "from-the-file")
        #expect(ControlEndpointDiscovery.resolveToken(
            environment: [ControlAPI.tokenEnvironmentKey: ""],
            discovered: discovered
        ) == "from-the-file")
        #expect(ControlEndpointDiscovery.resolveToken(environment: [:], discovered: nil) == nil)
    }

    /// The predicate the token pairing turns on. Both conditions have to hold — a loopback host
    /// *and* the port the file advertised — and a file that was never read names no instance at all.
    /// `ControlClient.discover` in `MimicCLICore` is the caller that pairs it with a destination;
    /// its suite drives the pairing end to end.
    @Test("Naming the discovered instance means loopback host and advertised port, together")
    func namesDiscoveredInstanceRequiresBoth() throws {
        let discovered = endpoint(port: 8787)
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

        #expect(ControlEndpointDiscovery.namesDiscoveredInstance(try url("http://127.0.0.1:8787"), discovered))
        #expect(ControlEndpointDiscovery.namesDiscoveredInstance(try url("http://LOCALHOST:8787"), discovered))
        // Written with brackets, because that is the only legal spelling of an IPv6 literal in a URL.
        // `URL.host` hands back `::1` on some platforms and `[::1]` on others, which is why the
        // reader's set holds both and why this case is worth having rather than assuming.
        let ipv6 = try #require(
            URL(string: "http://[::1]:8787"),
            "this platform's URL parser rejected an IPv6 literal"
        )
        #expect(ControlEndpointDiscovery.namesDiscoveredInstance(ipv6, discovered))

        // Right host, wrong port.
        #expect(
            ControlEndpointDiscovery.namesDiscoveredInstance(try url("http://127.0.0.1:8788"), discovered)
                == false
        )
        // Right port, wrong host.
        #expect(
            ControlEndpointDiscovery.namesDiscoveredInstance(try url("http://example.test:8787"), discovered)
                == false
        )
        // Nothing was discovered, so nothing is named.
        #expect(
            ControlEndpointDiscovery.namesDiscoveredInstance(try url("http://127.0.0.1:8787"), nil) == false
        )
    }
}
