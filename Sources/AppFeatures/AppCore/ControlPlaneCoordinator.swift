import AppKit
import ControlPlane
import Domain
import Foundation
import Observation
import Persistence

/// Whether this process is running without a window.
///
/// `mimic daemon start` launches the app with `MIMIC_HEADLESS=1` so CI and agent workflows get the
/// full engine and store on a machine with no one watching. One binary serves both cases, which is
/// what keeps headless behaviour identical to what a developer sees on screen.
enum HeadlessMode {
    static let environmentKey = "MIMIC_HEADLESS"

    static var isEnabled: Bool {
        isEnabled(environment: ProcessInfo.processInfo.environment)
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        guard let value = environment[environmentKey]?.lowercased() else { return false }
        return value == "1" || value == "true" || value == "yes"
    }

    /// Removes the app from the Dock and the app switcher without preventing it from working.
    /// `.accessory` rather than `.prohibited` so `NSApplication` still runs its event loop, which the
    /// embedded servers need.
    @MainActor
    static func applyActivationPolicyIfNeeded() {
        guard isEnabled else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// "Has the shutdown write finished?", asked across an isolation boundary.
///
/// One `Bool`, written once by the task that performs the flush and read by a waiter polling a
/// deadline. It is a hand-rolled flag rather than a `DispatchSemaphore` because both waiters need
/// to *poll* it — the draining paths from an `async` loop that must not block, the `willTerminate`
/// backstop from an observer that has no `await` left to it — and one primitive answering both
/// keeps the two paths honest about waiting for the same thing.
///
/// `@unchecked Sendable` is the lock's promise: every access to `isFinished` goes through it, and
/// there is nothing else in here to get wrong. `nonisolated` — the same opt-out `NavigationHistory`
/// takes — because this module's default isolation is `MainActor`, and a main-actor flag is precisely
/// what a detached task cannot set and a blocked main thread cannot observe.
private nonisolated final class PendingSaveSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var isFinished = false

    var hasFinished: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isFinished
    }

    func markFinished() {
        lock.lock()
        isFinished = true
        lock.unlock()
    }
}

/// Owns the control API for the app's lifetime.
///
/// Starting it automatically is deliberate: a CLI that works only after the user remembers to enable
/// something is a CLI an agent cannot rely on. The port comes from `MIMIC_CONTROL_PORT` when set so a
/// second instance (or a CI job) can avoid a collision, and the server binds loopback only.
@MainActor
public final class ControlPlaneCoordinator {

    /// One control plane per process.
    ///
    /// Deliberately not view state. Startup used to hang off `ContentView.onAppear`, which never fires
    /// when the app runs windowless — so `mimic daemon start` produced a live app that no CLI could
    /// reach. A process-level service has to be owned by the process, not by a view that may never
    /// appear.
    ///
    /// Public — along with ``handleTerminationRequest(reply:)`` and nothing else — because
    /// `MimicAppDelegate` lives in the app target and forwards AppKit's quit question here.
    public static let shared = ControlPlaneCoordinator()

    private var server: ControlServer?
    private var host: AppControlHost?
    private var terminationSignalSources: [DispatchSourceSignal] = []

    /// The session a shutdown has to flush, and the store it flushes into.
    ///
    /// Weak on the session because ownership runs the other way: `AppSession.shared` holds the
    /// `AppState` for as long as the process exists, so a strong reference here would buy nothing and
    /// would let this singleton outlive the session it describes.
    private weak var appState: AppState?
    private var repository: (any ProjectRepository)?

    /// Set by the first termination signal, read by the second.
    private var isTerminating = false

    /// Set once a draining flush has started, read by the `willTerminate` backstop.
    ///
    /// The backstop's bare write exists for a termination nothing drained. Once a drain has begun,
    /// the final save belongs to the write chain, and a second, unordered copy of it from the
    /// observer would be exactly the out-of-chain write the drain was built to retire.
    private var hasBegunDrainingFlush = false

    /// How long a shutdown will wait for the store before it gives up and exits anyway.
    ///
    /// A save is one `dbQueue.write` — a local SQLite transaction over a project the store is built
    /// to hold under a hundred endpoints of — so two seconds is orders of magnitude more than it
    /// needs. The ceiling is what picked the number. `DatabaseFactory.busyTimeoutSeconds` is 5, so a
    /// database another process is holding will sit in GRDB for five seconds before it fails: waiting
    /// that out would make ⌘Q feel broken, and it would put the process past the three seconds
    /// `Scripts/run_cli_e2e.sh` gives it after `kill` (ten polls, 0.3s apart) before it stops waiting
    /// and deletes the work directory underneath it. Two seconds clears the write and clears both
    /// deadlines.
    static let shutdownFlushTimeoutSeconds: TimeInterval = 2

    /// `nil` until the server has bound; useful for diagnostics and tests.
    private(set) var boundPort: Int?
    private(set) var startupError: String?

    /// The two irreversible things a termination path does, injectable because the path is not
    /// testable otherwise: exercising it for real means exiting the test runner and deleting the
    /// developer's live discovery file, which is how this machinery shipped data loss twice with
    /// zero automated coverage. Production never assigns these — the defaults *are* the production
    /// behaviour, and `exitProcess`'s default never returns, which is what lets
    /// `handleTerminationSignal` keep its "always ends" promise. A test's replacement returns, and
    /// every call site is written to tolerate that.
    var exitProcess: @MainActor @Sendable (Int32) -> Void = { exit($0) }
    var removeDiscoveryFile: @MainActor @Sendable () -> Void = { ControlEndpointFile.remove() }

    func start(appState: AppState, repository: any ProjectRepository) {
        guard server == nil else { return }

        let host = AppControlHost(appState: appState, repository: repository)
        let server = ControlServer(host: host, mode: HeadlessMode.isEnabled ? "headless" : "app")
        self.host = host
        self.server = server
        // Held for the shutdown flush below, which needs to know what to write and where — and has to
        // know it before the signal arrives, because there is no time to go looking afterwards.
        prepareShutdownFlush(appState: appState, repository: repository)

        // Before the port is bound, and deliberately outside the `Task` below.
        //
        // These handlers are what write the open project on the way out. That has nothing to do with
        // the control plane: it is the user's data, and it is owed whether or not a socket is
        // available. Installing them inside the `do` block — which is where they were — meant that on
        // any machine where the port could not be bound (a second instance, an occupied
        // `MIMIC_CONTROL_PORT`, the `alreadyRunning` and `shuttingDown` paths beside this one) Cmd-Q
        // silently dropped the debounced edit exactly as it did before the flush existed, and the
        // failure showed up as the one symptom nobody attributes to the control plane: an edit that
        // was not there next launch.
        //
        // They need `appState` and `repository`, both assigned above, and nothing else.
        installTerminationHandlers()

        let port = Self.resolvePort()
        Task { @MainActor [weak self] in
            do {
                let bound = try await server.start(port: port, advertise: true)
                self?.boundPort = bound
            } catch {
                // A control plane that cannot bind must not stop the app from working — the window is
                // still fully usable, so the failure is recorded rather than raised.
                self?.startupError = error.localizedDescription
                self?.server = nil
                self?.host = nil
            }
        }
    }

    /// Wires the session and store the shutdown flush reads, and nothing else.
    ///
    /// Split from `start(appState:repository:)` so a test can drive the flush paths without binding
    /// a control server or installing signal handlers — the seam the twice-shipped quit data loss
    /// never had. `start` routes through it, so the two cannot wire different things.
    func prepareShutdownFlush(appState: AppState, repository: any ProjectRepository) {
        self.appState = appState
        self.repository = repository
    }

    /// Removes the discovery file when the process goes away.
    ///
    /// The file advertises a port *and* this instance's token, and it used to outlive the process that
    /// wrote it: nothing called `ControlServer.stop()` on exit, so every run left one behind. Stale
    /// entries were survivable — `discover()` skips a dead pid — but leaving credential material on
    /// disk after the process holding it has gone is not, and with `MIMIC_CONTROL_TOKEN` set the token
    /// is stable across runs, so a leftover file really does describe a live credential.
    ///
    /// Both paths are needed, and neither is where a quit does its real work any more. Quit is
    /// answered in `applicationShouldTerminate` — `MimicAppDelegate` routes it through
    /// ``handleTerminationRequest(reply:)`` *before* AppKit commits to terminating — so by the time
    /// `willTerminate` fires on an ordinary quit the store is already drained, and the observer
    /// here is the last chance to drop the file plus a backstop for a termination nothing drained.
    /// It does *not* run for `SIGTERM`, which is exactly how `mimic app stop` asks a headless
    /// instance to exit; the dispatch sources below cover that.
    private func installTerminationHandlers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // The queue is `.main`, so this block runs on the main actor; the compiler cannot see
            // that through Foundation's `@Sendable` observer block.
            MainActor.assumeIsolated {
                guard let self else {
                    // A deallocated coordinator has no hooks to read; in production this type is a
                    // process-lifetime singleton, so this arm is about never leaving a token on
                    // disk, not about testability.
                    ControlEndpointFile.remove()
                    return
                }
                self.removeDiscoveryFile()
                self.flushPendingSaveBlocking()
            }
        }

        for signalNumber in [SIGTERM, SIGINT] {
            // The default disposition terminates the process outright, and a dispatch source never
            // fires if that happens first.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                // Same reasoning as above: the source's queue is `.main`.
                MainActor.assumeIsolated {
                    guard let self else {
                        ControlEndpointFile.remove()
                        exit(0)
                    }
                    // `self.` spelled out, not decoration: the `guard let self` above sits inside
                    // `assumeIsolated`'s closure while the weak capture belongs to the event
                    // handler outside it, so the compiler does not carry the unwrap across the two
                    // and rejects implicit `self` here.
                    self.handleTerminationSignal()
                }
            }
            source.resume()
            terminationSignalSources.append(source)
        }
    }

    /// The whole of what `mimic app stop` gets: drop the credential, write the pending edit, exit.
    ///
    /// The handler used to be two statements — remove the file, `exit(0)` — while
    /// `AppLauncher.terminate` documented `SIGTERM` as the signal that lets the app "flush pending
    /// saves". It did not. `ProjectWorkspace.scheduleAutosave` waits 500 ms before it writes, so every
    /// edit made in the last half-second before a stop went to an exit that had no idea it was there.
    /// A `mimic` command is the worst of it: `AppControlHost.perform` mutates `currentProject`,
    /// schedules the autosave and answers the CLI immediately, so `mimic endpoint create` followed by
    /// `mimic app stop` — two commands back to back, well inside the debounce, and a script rather
    /// than a mistake — lost the endpoint the first one had just reported creating. Silently: the
    /// window that shows "Save failed" is gone by then, and the next launch simply reads an older
    /// project.
    ///
    /// The file goes first, before the wait. It is credential material, this handler is the only
    /// thing that can end the process now that the default disposition is ignored, and a flush that
    /// times out must not be able to leave a live token on disk.
    ///
    /// Internal rather than private, and ending in the `exitProcess` hook rather than a bare `exit`:
    /// this is the path `mimic app stop` takes, it had shipped data loss with zero automated
    /// coverage, and a test can only drive it if calling it does not end the test runner.
    func handleTerminationSignal() {
        removeDiscoveryFile()

        guard !isTerminating else {
            // Asked twice. Someone who signals again is telling us they are done waiting, and the
            // one promise this path has to keep is that it always ends — the production hook is
            // `exit(0)` and never returns.
            exitProcess(0)
            return
        }
        isTerminating = true

        // Suspends rather than blocks, so the main queue keeps draining while the store works — this
        // path, unlike the `willTerminate` observer, still has somewhere to suspend to. `exit` (the
        // hook's production value), not `NSApp.terminate`: ignoring the signal above means this is
        // now the *only* thing that can end the process, so it has to be something that cannot be
        // deferred or cancelled, and AppKit termination is both. Routing through it left the app
        // alive through a SIGTERM whenever something was mid-flight (an edit waiting on autosave, an
        // open sheet), which is worse than the crude exit it replaced.
        //
        // The hook is captured before the task so the process still ends if the coordinator is gone
        // by the time the flush returns.
        let exitProcess = self.exitProcess
        let flush = terminationFlush()
        Task { @MainActor in
            await flush.value
            exitProcess(0)
        }
    }

    /// The ⌘Q path: everything ``handleTerminationSignal()`` does except ending the process —
    /// AppKit does that itself once `reply` lands.
    ///
    /// `MimicAppDelegate` calls this from `applicationShouldTerminate` and answers
    /// `.terminateLater`, and that reply is what makes a *draining* quit possible at all. The old
    /// ⌘Q path ran from the `willTerminate` observer, after termination was already committed,
    /// where the only way to wait is to park the main thread — and the write chain is main-actor
    /// work, so the parked thread was the very thing the drain needed, which is the quit deadlock
    /// this file shipped once and documents at ``flushPendingSaveBlocking()``. `.terminateLater`
    /// keeps the runloop alive while the drain runs, so the main actor stays serviced and ⌘Q
    /// drains exactly as `SIGTERM` always has; the old path's constraint dissolves because nothing
    /// is parked any more.
    ///
    /// The discovery file goes first, exactly as on the signal path: it is credential material, and
    /// a drain that times out must not be able to leave a live token on disk. The flush itself is
    /// shared with the signal path — one drain per process, whichever door termination came
    /// through — so a quit landing during a `mimic app stop` waits for the drain already running
    /// instead of starting a second one over the same chain.
    public func handleTerminationRequest(reply: @escaping @MainActor @Sendable () -> Void) {
        removeDiscoveryFile()
        let flush = terminationFlush()
        Task { @MainActor in
            await flush.value
            reply()
        }
    }

    /// The one draining flush per process, shared by both termination doors.
    private var terminationFlushTask: Task<Void, Never>?

    private func terminationFlush() -> Task<Void, Never> {
        if let terminationFlushTask { return terminationFlushTask }
        // `guard let`, not an optional chain: `self?.flushPendingSave()` would make the closure's
        // implicit return `()?` and the task infer `Task<()?, Never>`, which does not assign to
        // the memoized handle's declared type.
        let flush = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.flushPendingSave()
        }
        terminationFlushTask = flush
        return flush
    }

    /// Starts the shutdown drain and hands back the handle that says when it finished, or `nil`
    /// when no session is wired.
    ///
    /// The order is the whole of it. First the retained import dispatch, so the one write that
    /// reaches the chain from a task of its own — `AppState.importProject` — has actually joined
    /// it; between that method returning and its task's first slice there is a gap in which the
    /// chain has never heard of the import, and a drain started inside the gap would finish with
    /// the document unwritten. Then the chain itself, so every lifecycle write already asked for
    /// has reached the store. Then the final save, and it goes through
    /// `ProjectWorkspace.saveCurrentProject()` — the chain's own door — with one more drain behind
    /// it so the caller cannot outrun it.
    ///
    /// Saving *after* the drain, through the chain, is what closes the two ways a quit used to
    /// resurrect deleted data. Capturing before the drain saved the doomed row back after `mimic
    /// project delete` had removed it — the delete nils `currentProject` on its way through the
    /// chain, and `saveCurrentProject` reads it after that, finds nothing open, and writes nothing.
    /// And the bare `repository.save` this replaces was ordered after the drain but *outside* the
    /// chain, so it could still race any write accepted mid-drain; enqueued, the last write of the
    /// process is ordered by the same mechanism as every other. It saves whether or not an edit is
    /// pending, because a pending debounce is not visible from here — `autosaveStatus` is still
    /// `.idle` or `.saved` during those 500 ms — and the write is idempotent, so doing it when it
    /// was not needed costs a few milliseconds and nothing else.
    ///
    /// This runs on the main actor throughout, and may: both termination doors keep the main
    /// thread live while they wait — the signal path always suspended, and ⌘Q now waits *before*
    /// termination behind `.terminateLater` instead of parking the thread inside `willTerminate` —
    /// so the main-actor hops that deadlocked the old blocking quit are ordinary scheduling here.
    /// The one gap left open, knowingly: a command accepted *while* this drains lands behind the
    /// awaits below, and the final save captures whatever it leaves open. That is best-effort by
    /// design and narrow in practice — the discovery file is gone before the drain starts, so only
    /// an already-connected client can still be issuing commands.
    private func startPendingSave() -> PendingSaveSignal? {
        guard let appState else { return nil }
        hasBegunDrainingFlush = true
        let workspace = appState.projects
        let importDispatch = appState.importTask

        let didFinish = PendingSaveSignal()
        Task { @MainActor in
            if let importDispatch { await importDispatch.value }
            await workspace.awaitPendingStoreWrites()
            // A store that refuses the save has nowhere to report it — there is no window left to
            // show `autosaveStatus` in, and the caller ends the process as soon as this returns.
            workspace.saveCurrentProject()
            await workspace.awaitPendingStoreWrites()
            didFinish.markFinished()
        }
        return didFinish
    }

    /// Returns when the drain is done or `shutdownFlushTimeoutSeconds` has passed, whichever is first.
    ///
    /// Polled rather than raced in a task group, for the reason the bound exists at all: a group does
    /// not return until every one of its children has finished, so cancelling the timeout's sibling
    /// would still leave a wedged write holding the quit open. `AppLauncher.waitForReadiness` polls a
    /// deadline for the same kind of reason. The `Task.sleep` suspends rather than blocks, which is
    /// what leaves the main actor free to run the very writes being drained.
    ///
    /// Internal rather than private so the drain-ordering property is testable — see
    /// `ControlPlaneCoordinatorTests`.
    func flushPendingSave() async {
        guard let didFinish = startPendingSave() else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.shutdownFlushTimeoutSeconds))
        while !didFinish.hasFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The last-resort flush, for a termination nothing drained.
    ///
    /// `willTerminate` is posted from inside `NSApplication.terminate`, and the process ends as soon
    /// as its observers return — there is nowhere left to suspend to, so this blocks the main thread
    /// for the same bound the draining paths suspend for. On an ordinary quit it does nothing:
    /// `MimicAppDelegate` has already drained the chain before AppKit committed to terminating, and
    /// the guard below keeps this from following that drain with a second, unordered copy of the
    /// same save. What remains is the termination that reaches `willTerminate` without passing
    /// either draining door — nothing in AppKit promises there is none, and losing the debounced
    /// edit there is the original defect this flush was written for.
    ///
    /// What this path still cannot do is drain. The write chain is main-actor work and the loop
    /// below parks the main thread, so awaiting the chain from here is the documented quit
    /// deadlock: the hop cannot be serviced, the save never runs, and the deadline is spent saving
    /// nothing — which shipped, green in CI, until `.terminateLater` moved the real quit ahead of
    /// this observer. So it saves the open project bare, off the chain — tolerable only because it
    /// runs when no drain ever started, so there is nothing in flight to invert against. A drain
    /// that *timed out* also stands this backstop down, deliberately: the save may be unwritten,
    /// but a bare copy written after a partial drain is exactly the out-of-chain inversion this
    /// rewrite retired, and a wedged store is not going to honour a second write inside the same
    /// deadline anyway.
    ///
    /// Internal rather than private so a test can hold the main thread exactly as `willTerminate`
    /// does and assert both halves: the save lands inside the deadline, and the backstop stands
    /// down once a drain has run.
    func flushPendingSaveBlocking() {
        guard !hasBegunDrainingFlush else { return }
        guard let repository, let project = appState?.currentProject else { return }

        let didFinish = PendingSaveSignal()
        // `Task.detached` is load-bearing: nothing in the save then needs the main actor — the
        // repository is nonisolated and GRDB runs the transaction on its own queue — which is what
        // lets the loop below hold the main thread without deadlocking against the work it waits for.
        Task.detached(priority: .userInitiated) {
            try? await repository.save(project)
            didFinish.markFinished()
        }
        let deadline = Date().addingTimeInterval(Self.shutdownFlushTimeoutSeconds)
        while !didFinish.hasFinished, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
    }

    func stop() {
        guard let server else { return }
        self.server = nil
        host = nil
        boundPort = nil
        Task { try? await server.stop() }
    }

    static func resolvePort(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        guard let raw = environment[ControlAPI.portEnvironmentKey], let port = Int(raw) else {
            return ControlAPI.defaultPort
        }
        // `0` is a legitimate request for "any free port", which is how a test avoids collisions.
        guard port == 0 || (1...65535).contains(port) else { return ControlAPI.defaultPort }
        return port
    }
}
