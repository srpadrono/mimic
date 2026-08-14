import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

/// Where the CLI sends the instance's token, and how it finds the instance at all.
///
/// The reader itself — search order, the `MIMIC_CONTROL_FILE` override, pid liveness, the tampered
/// `baseURL`, and the `namesDiscoveredInstance` predicate — is `ControlEndpointDiscovery` in
/// `Domain`, and its suite lives in `DomainTests`. It used to be a second copy in this module, and
/// this file's opening warning was about exactly that: assertions pointed at the twin the `mimic`
/// binary does not call report a defect as covered. What belongs *here* is what only the CLI's own
/// code can regress — `ControlClient.discover`, the one place the destination and the credential
/// meet, and the failure rendering the exit-code contract hangs off.
@Suite("Control client discovery")
struct ControlClientTests {

    // MARK: - Fixtures

    /// A discovered instance, in the shape `ControlEndpointDiscovery.discover` hands back: the
    /// public initialiser derives `baseURL` from the port, exactly as a genuine advertisement
    /// carries it.
    private func discovered(port: Int = 8787, token: String? = "not-a-real-token") -> ControlEndpoint {
        ControlEndpoint(port: port, pid: 1, mode: "app", token: token)
    }

    // MARK: - An isolated run

    /// The CLI resolves the discovery file through `ControlEndpointDiscovery`, so `MIMIC_CONTROL_FILE`
    /// reaches it by construction — and this is the case that regresses if the CLI ever grows a
    /// reader of its own again. The old copy searched only the two Application Support paths, so an
    /// isolated run's `mimic` found no file (or, worse, a developer's real one), sent no token, and
    /// was refused by every route while `mimic app start` still looked fine.
    @Test("Discovery reads the file MIMIC_CONTROL_FILE names — destination and credential together")
    func discoveryHonoursTheRelocatedFile() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-relocated-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appendingPathComponent(ControlEndpointDiscovery.fileName)
        // Written as JSON and decoded by the reader, so the endpoint arrives the way a real one
        // does. The pid is this process, so the liveness check is the real one.
        let json = """
        {
          "apiVersion": "\(ControlAPI.version)",
          "port": 18787,
          "pid": \(ProcessInfo.processInfo.processIdentifier),
          "mode": "headless",
          "baseURL": "http://127.0.0.1:18787",
          "token": "isolated-run-token"
        }
        """
        try Data(json.utf8).write(to: url)

        let client = try ControlClient.discover(
            environment: [ControlEndpointDiscovery.pathEnvironmentKey: url.path],
            timeout: 1
        )
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:18787")
        #expect(client.token == "isolated-run-token")
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
    /// with a real local discovery file supplied alongside it. The predicate itself —
    /// `namesDiscoveredInstance`, both halves required — has its own cases in
    /// `ControlEndpointDiscoveryTests`; what is pinned here is that this client consults it.
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
        let client = try ControlClient.discover(
            explicitURL: explicitURL,
            environment: [:],
            timeout: 1,
            discovered: discovered()
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
        let client = try ControlClient.discover(
            explicitURL: explicitURL,
            environment: [:],
            timeout: 1,
            discovered: discovered()
        )
        #expect(client.token == "not-a-real-token")
    }

    /// …and with no `--url` at all, which is the ordinary path: the client is pointed at the
    /// discovered instance, so it carries the discovered token.
    @Test("Discovery with no explicit URL carries the discovered token")
    func discoveryCarriesItsOwnToken() throws {
        let client = try ControlClient.discover(environment: [:], timeout: 1, discovered: discovered())
        #expect(client.baseURL.absoluteString == "http://127.0.0.1:8787")
        #expect(client.token == "not-a-real-token")
    }

    /// `MIMIC_CONTROL_TOKEN` is untouched by any of this, and has to be: a caller reaching Mimic
    /// through a forwarded port or a container supplies the token the documented way, which is the
    /// caller naming a credential rather than this CLI guessing one.
    @Test("An explicitly supplied token goes wherever the caller points")
    func anExplicitTokenIsNotSecondGuessed() throws {
        let client = try ControlClient.discover(
            explicitURL: "http://forwarded.example:8787",
            environment: [ControlAPI.tokenEnvironmentKey: "from-the-environment"],
            timeout: 1,
            discovered: discovered(token: "from-the-file")
        )
        #expect(client.token == "from-the-environment")
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
