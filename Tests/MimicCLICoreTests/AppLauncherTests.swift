// `pid_t` and `SIGTERM` are C, and this file names both. Imported explicitly, the way
// Tests/MockServerEngineTests/PlatformSockets.swift does, rather than leaned on through whatever
// Foundation happens to re-export on each platform — CI compiles this on Linux too.
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import Testing
@testable import Domain
@testable import MimicCLICore

// MARK: - Fixtures

/// A discovery file's contents, in the shape the stop path receives them.
///
/// Port 8911 rather than the default 8787 on purpose: `StubInstance` below reports 8787 as *its*
/// base URL, so a refusal naming 8911 is a refusal that read the port out of the file rather than
/// out of the transport it happened to be handed.
private func discoveredEndpoint(pid: Int, port: Int = 8911) -> ControlEndpointFileReader.Endpoint {
    ControlEndpointFileReader.Endpoint(
        apiVersion: ControlAPI.version,
        port: port,
        pid: pid,
        mode: "headless",
        baseURL: "http://127.0.0.1:\(port)",
        token: "not-a-real-token"
    )
}

/// What an instance answers `.state` with. Only `pid` is under test here; the rest is present
/// because the guard reads that pid out of the same envelope every other command comes back in, and
/// a fixture that skipped the envelope would not be exercising that.
private func reportedState(pid: Int) -> ControlState {
    ControlState(
        mode: "headless",
        pid: pid,
        server: ServerStatusReport(state: "stopped", port: 8080, baseURL: nil, globalDelayMs: 0),
        project: nil,
        endpointCount: 0,
        journeyCount: 0,
        activeJourney: nil,
        requestLogCount: 0
    )
}

/// The instance a discovery file claims to describe.
///
/// Bound through `ControlTransportOverride`, which is the seam `confirmRunningInstance`'s own
/// documentation prescribes — one way to replace an instance in this module rather than a second
/// injection point that only that function would understand.
private final class StubInstance: ControlTransport, @unchecked Sendable {
    /// Deliberately not the port `discoveredEndpoint` advertises. See the note there.
    let baseURL = URL(string: "http://127.0.0.1:8787")!

    private let lock = NSLock()
    private var received: [ControlCommand] = []
    private let answer: @Sendable (ControlCommand) throws -> ControlResponse

    init(_ answer: @escaping @Sendable (ControlCommand) throws -> ControlResponse) {
        self.answer = answer
    }

    /// An instance that answers with a state of its own, naming `pid`. That number is the whole of
    /// the confirmation: it is compared against the one about to be signalled.
    static func reporting(pid: Int) -> StubInstance {
        StubInstance { _ in .success(ControlResult(state: reportedState(pid: pid))) }
    }

    var commands: [ControlCommand] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func send(_ command: ControlCommand) async throws -> ControlResponse {
        record(command)
        return try answer(command)
    }

    /// The append lives in a synchronous method because `NSLock.lock()` is `noasync` — a lock taken
    /// in an async function is a hold that can span a suspension, so the compiler refuses it. Same
    /// shape, for the same reason, as `RecordingTransport` in ControlTransportTests.
    private func record(_ command: ControlCommand) {
        lock.lock()
        defer { lock.unlock() }
        received.append(command)
    }

    func isReachable() async -> Bool { true }
}

/// Every signal `AppLauncher.terminate` delivered while this was bound — and, far more often what is
/// being asserted, that it delivered none.
private final class RecordedSignals: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(pid: pid_t, signal: Int32)] = []

    var delivered: [(pid: pid_t, signal: Int32)] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    /// Stands exactly where `kill(2)` stands, and answers `0` — `kill`'s success — so everything
    /// after the delivery follows the path a real signal takes.
    ///
    /// The parameters are not named `pid` and `signal`: `signal` is a C function this file imports,
    /// and a parameter that shadows one is a name nobody should have to think about twice.
    var deliver: @Sendable (pid_t, Int32) -> Int32 {
        { [self] targetPID, signalNumber in
            lock.lock()
            recorded.append((pid: targetPID, signal: signalNumber))
            lock.unlock()
            return 0
        }
    }
}

// MARK: - The guard

/// The guard between a pid on disk and a `SIGTERM`.
///
/// `mimic app stop` reads a pid out of `control.json` and signals it, and that file outlives the
/// process that wrote it. The liveness check cannot settle whether it is stale:
/// `ControlEndpointFileReader.isProcessAlive` returns `true` on `EPERM`, which means "a process with
/// that id exists and is *not* yours", so a file left by a crashed instance naming a pid the kernel
/// has since recycled reads as live. `AppLauncher.confirmRunningInstance` is what stands between
/// that file and `kill(2)` — and nothing in `Tests/` exercised it. What the `App launching` suite in
/// CLIParsingTests asserts about stopping is that `terminate` refuses pid `0` and pid `-5`, which is
/// a statement about one `guard` inside `terminate` and says nothing about the confirmation.
///
/// Every case below records signals instead of delivering them, and asserts what was delivered — but
/// what that assertion is worth differs by level, and it is worth saying where. At the confirmation
/// level it is a statement about *shape*: `confirmRunningInstance` has no path to `terminate` today,
/// so it fails for the refactor that gives it one — folding the confirmation and the signal into a
/// single call is exactly the tidy-up somebody reaches for — and not for a guard that stopped
/// guarding. The case that fails for *that* is the last one, which runs `mimic app stop` from argv.
/// `SignalDeliveryOverride` is what makes that one safe to run at all.
@Suite("Confirming an instance before it is signalled")
struct InstanceConfirmationTests {

    /// Runs `confirmRunningInstance` against a stub instance and returns what it refused with, or
    /// `nil` when it confirmed. It binds the signal recorder as well, so every caller can assert that
    /// confirming did not become signalling — see the note on the suite for what that is and is not
    /// evidence of at this level.
    private static func refusal(
        pid: Int,
        instance: StubInstance,
        signals: RecordedSignals,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async -> String? {
        do {
            try await SignalDeliveryOverride.$current.withValue(signals.deliver) {
                try await ControlTransportOverride.$current.withValue(instance) {
                    try await AppLauncher.confirmRunningInstance(discoveredEndpoint(pid: pid))
                }
            }
            return nil
        } catch let failure as CLIFailure {
            guard case let .appUnavailable(message) = failure else {
                Issue.record(
                    "expected an appUnavailable, got \(failure)",
                    sourceLocation: sourceLocation
                )
                return nil
            }
            // `3` is "there is no Mimic to talk to", which is exactly what a pid that cannot be
            // confirmed means. docs/CLI.md publishes four codes and a script branches on them.
            #expect(failure.exitCode == 3, sourceLocation: sourceLocation)
            // The refusal is only safe to fail in because it leaves the caller able to finish the
            // job by hand.
            #expect(message.contains("Refusing to signal pid \(pid)"), sourceLocation: sourceLocation)
            #expect(message.contains("kill \(pid)"), sourceLocation: sourceLocation)
            return message
        } catch {
            Issue.record("expected a CLIFailure, got \(error)", sourceLocation: sourceLocation)
            return nil
        }
    }

    // MARK: Refusals

    /// The case the guard exists for: the file's pid was recycled, so the instance still answering on
    /// that port is a Mimic — just not the one the pid now belongs to.
    @Test("An instance answering with a different pid is refused, and both numbers are named")
    func aDifferentPidIsRefused() async {
        let instance = StubInstance.reporting(pid: 9999)
        let signals = RecordedSignals()

        let message = await Self.refusal(pid: 4242, instance: instance, signals: signals)

        #expect(
            message?.contains("is pid 9999, not 4242") == true,
            "refused with: \(message ?? "nothing")"
        )
        // The port comes out of the file, never from `--url` or `MIMIC_CONTROL_URL`:
        // `confirmRunningInstance` passes `environment: [:]` for exactly that reason, and 8911 is the
        // file's port while the transport it was handed reports 8787.
        #expect(message?.contains("http://127.0.0.1:8911") == true)
        #expect(instance.commands.map(\.kind) == [.state], "the instance is asked for its own state")
        #expect(signals.delivered.isEmpty, "confirming a pid must never be signalling it")
    }

    /// Nothing answered at all — the port is closed, or the process behind it is wedged. A file that
    /// names a dead instance is the ordinary way this happens, and it is the shape a recycled pid
    /// takes when whatever inherited the number is not listening on that port.
    @Test("An instance that cannot be reached is refused, and the reason travels with it")
    func anUnreachableInstanceIsRefused() async {
        let instance = StubInstance { _ in
            throw CLIFailure.unreachable(
                baseURL: URL(string: "http://127.0.0.1:8911")!,
                underlying: "Connection refused"
            )
        }
        let signals = RecordedSignals()

        let message = await Self.refusal(pid: 4242, instance: instance, signals: signals)

        // "did not confirm" rather than "did not answer": a refusal is an answer, and a `401` from an
        // instance whose token this CLI does not have arrives down this same path.
        #expect(message?.contains("did not confirm") == true, "refused with: \(message ?? "nothing")")
        #expect(message?.contains("Connection refused") == true, "the underlying reason was dropped")
        #expect(signals.delivered.isEmpty, "confirming a pid must never be signalling it")
    }

    /// Something answered, and it was not a Mimic reporting itself: a `401` from an instance whose
    /// token this CLI does not have, or a 2xx carrying no state at all — a proxy on the port, some
    /// other program, a build too old to report one. None of those is evidence about a pid.
    @Test(
        "An answer that is not a Mimic's own state is refused",
        arguments: [ControlResponse.failure(.unauthorized), ControlResponse.success(.message("ok"))]
    )
    func anAnswerWithoutAStateIsRefused(answer: ControlResponse) async {
        let instance = StubInstance { _ in answer }
        let signals = RecordedSignals()

        let message = await Self.refusal(pid: 4242, instance: instance, signals: signals)

        #expect(
            message?.contains("answered, but not with the state a Mimic reports") == true,
            "refused with: \(message ?? "nothing")"
        )
        #expect(signals.delivered.isEmpty, "confirming a pid must never be signalling it")
    }

    // MARK: The accepting path

    /// For a genuine instance the two numbers are equal by construction — `ControlServer` writes
    /// `ProcessInfo.processInfo.processIdentifier` into the discovery file and `AppControlHost`
    /// reports that same value as `state.pid` — so this is the case every real `mimic app stop`
    /// takes, and the one a guard tightened too far would break.
    @Test("An instance reporting its own pid confirms, and is asked exactly once")
    func theNamedInstanceConfirms() async {
        let instance = StubInstance.reporting(pid: 4242)
        let signals = RecordedSignals()

        let message = await Self.refusal(pid: 4242, instance: instance, signals: signals)

        #expect(message == nil, "a live instance naming its own pid was refused: \(message ?? "")")
        #expect(instance.commands.map(\.kind) == [.state])
        // Confirming is not signalling: `AppCommand.Stop` calls `terminate` afterwards, and that is
        // the only thing in the CLI that signals anything.
        #expect(signals.delivered.isEmpty)
    }

    // MARK: What the confirmation is guarding

    /// `SIGTERM` and not `SIGKILL` is a published guarantee, not an implementation detail: docs/CLI.md
    /// says pending saves flush, and they only do because the app gets a signal it can handle.
    ///
    /// The pid is the implausible one `ControlClientTests` already writes for a process that is not
    /// there, and that is deliberate: this is the only case in the file that asks for a delivery, so
    /// if the override ever stopped being consulted the fallback must not be able to find anything.
    /// A pid nothing owns makes `terminate` throw — this test red, nothing on the machine touched.
    @Test("A confirmed pid is sent SIGTERM, and nothing else is")
    func terminateSendsSigterm() throws {
        let signals = RecordedSignals()

        try SignalDeliveryOverride.$current.withValue(signals.deliver) {
            try AppLauncher.terminate(pid: 999_999)
        }

        #expect(signals.delivered.count == 1)
        #expect(signals.delivered.first?.pid == 999_999)
        #expect(signals.delivered.first?.signal == SIGTERM)
    }

    /// The `App launching` suite in CLIParsingTests already asserts that pid `0` and pid `-5` throw.
    /// The half it could not assert is this one — that the delivery never happened — because the
    /// delivery *was* `kill(2)`, so a guard that had stopped firing would have been reported by the
    /// signal rather than by the assertion. A non-positive pid is not a process id, which is why
    /// `ControlEndpointFileReader.isProcessAlive` refuses one too.
    @Test("A pid that is not a pid is refused before anything is signalled", arguments: [0, -1, -5])
    func anInvalidPidIsNeverSignalled(pid: Int) {
        let signals = RecordedSignals()

        #expect(throws: CLIFailure.self) {
            try SignalDeliveryOverride.$current.withValue(signals.deliver) {
                try AppLauncher.terminate(pid: pid)
            }
        }

        #expect(signals.delivered.isEmpty, "terminate(pid: \(pid)) signalled something")
    }

    // MARK: Before there is a pid at all

    /// The stop path's first two refusals are not `confirmRunningInstance`'s. They happen a line
    /// earlier, in `AppCommand.Stop`'s `guard let endpoint = ControlEndpointFileReader.discover()`: a
    /// file that is not there and a file whose process is gone both leave that `guard` with nothing,
    /// so there is no pid to confirm and none to signal, and the run stops at `noInstance` — exit 3.
    ///
    /// Asserted on the reader rather than from argv because `Stop` calls `discover()` with no
    /// arguments and there is no injection point on that call. `MIMIC_CONTROL_FILE` relocates the
    /// *control plane's* discovery file and `MimicCLICore`'s copy of this reader does not honour it
    /// (AGENTS.md records that as an open item), so driving these two from argv would mean writing a
    /// fixture into the path a real instance uses, or moving `HOME` out from under a suite that runs
    /// in parallel. `ControlClientTests.staleFileIsSkipped` covers the same reader call as *discovery*
    /// behaviour; what is named here is its consequence for `mimic app stop`.
    @Test("A missing file and a stale file both leave the stop path with no pid at all")
    func nothingToSignalIsNotSomethingToSignal() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mimic-stop-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(ControlEndpointFileReader.fileName)

        #expect(ControlEndpointFileReader.discover(searchURLs: [url]) == nil, "no file, no pid")

        // Written as JSON and decoded by the reader, so the pid arrives the way a real one does.
        let json = """
        {
          "apiVersion": "\(ControlAPI.version)",
          "port": 8911,
          "pid": 4242,
          "mode": "headless",
          "baseURL": "http://127.0.0.1:8911",
          "token": "not-a-real-token"
        }
        """
        try Data(json.utf8).write(to: url)

        // The liveness check is injected because a test cannot name a pid it can guarantee is dead:
        // the kernel is free to hand 4242 to something between the file being written and read.
        let dead = ControlEndpointFileReader.discover(searchURLs: [url], isProcessAlive: { _ in false })
        #expect(dead == nil, "a file whose process is gone still handed the stop path a pid")

        let alive = ControlEndpointFileReader.discover(searchURLs: [url], isProcessAlive: { _ in true })
        #expect(alive?.pid == 4242, "the file has to be readable, or the case above proves nothing")

        #expect(CLIFailure.noInstance.exitCode == 3)
    }

    // MARK: The whole path, from argv

    /// Driven the way the process driver drives it: argv in, exit code out. `mimic daemon stop` is
    /// included because it is not a second implementation — `DaemonCommand.Stop` runs an
    /// `AppCommand.Stop` — and that is a claim worth failing on if it stops being true.
    ///
    /// What this pins on every machine: with nothing confirming the pid, `mimic app stop` exits `3`
    /// and delivers no signal. It cannot exit `0`, and it cannot exit `2` — which it would if the
    /// refusal ever stopped being a `CLIFailure`, because `MimicCommand.run`'s other arm reports
    /// anything it catches as `2` unless ArgumentParser called it a success.
    ///
    /// **Which refusal it takes depends on the machine, and that is a real limit of this test.**
    /// `AppCommand.Stop` reads the machine's own `control.json` with no injection point, so a runner
    /// with no discovery file stops at `noInstance` and never reaches the confirmation, while a
    /// developer's machine with Mimic open goes on and is refused there. Both are exit `3`
    /// deliberately — docs/CLI.md publishes `3` as "there is no Mimic to talk to" and these are that
    /// same sentence — so the code alone cannot say which arm ran; the recorded commands can, and are
    /// asserted for both shapes.
    ///
    /// Binding `SignalDeliveryOverride` is what makes this safe to run at all. Without it, a machine
    /// with a live instance would — the day the guard was removed — have that instance SIGTERMed by
    /// the test written to prove the guard works. Bound, the pid still travels the whole production
    /// path and the signal stops at the recorder, so that regression fails here instead of being
    /// demonstrated on the developer.
    @Test(
        "`stop` exits 3 and signals nothing when nothing confirms the pid",
        arguments: [["app", "stop"], ["daemon", "stop"]]
    )
    func stopSignalsNothingWhenNothingConfirms(invocation: [String]) async {
        let signals = RecordedSignals()
        let instance = StubInstance { _ in
            throw CLIFailure.unreachable(
                baseURL: URL(string: "http://127.0.0.1:8911")!,
                underlying: "Connection refused"
            )
        }

        let status = await SignalDeliveryOverride.$current.withValue(signals.deliver) {
            await ControlTransportOverride.$current.withValue(instance) {
                await MimicCommand.run(arguments: invocation)
            }
        }

        #expect(status == 3, "mimic \(invocation.joined(separator: " ")) exited \(status)")
        #expect(signals.delivered.isEmpty, "a pid nothing confirmed was signalled anyway")
        // Either the run found no discovery file and stopped before the confirmation, or it found one
        // and asked that instance for its state. There is no third path through `AppCommand.Stop`.
        #expect(instance.commands.count <= 1)
        #expect(instance.commands.allSatisfy({ $0.kind == .state }))
    }
}
