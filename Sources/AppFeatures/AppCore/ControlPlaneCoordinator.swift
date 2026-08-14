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
/// One `Bool`, written once by the detached task that performs the save and read by a waiter on the
/// main actor. It is a hand-rolled flag rather than a `DispatchSemaphore` because both waiters need
/// to *poll* it — the signal path from an `async` loop that must not block, the Quit path from a
/// `willTerminate` observer that has no `await` left to it — and one primitive answering both keeps
/// the two paths honest about waiting for the same thing.
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
final class ControlPlaneCoordinator {

    /// One control plane per process.
    ///
    /// Deliberately not view state. Startup used to hang off `ContentView.onAppear`, which never fires
    /// when the app runs windowless — so `mimic daemon start` produced a live app that no CLI could
    /// reach. A process-level service has to be owned by the process, not by a view that may never
    /// appear.
    static let shared = ControlPlaneCoordinator()

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
    /// Both paths are needed. `willTerminate` covers Quit and a closed last window; it does *not* run
    /// for `SIGTERM`, which is exactly how `mimic app stop` asks a headless instance to exit.
    ///
    /// Both paths also have to write the open project before they go — see `flushPendingSave()`.
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
        Task { @MainActor [weak self] in
            await self?.flushPendingSave()
            exitProcess(0)
        }
    }

    /// Starts the write and hands back the handle that says when it finished, or `nil` when there is
    /// nothing to write.
    ///
    /// The project is read rather than tracked: the coordinator has no business watching edits,
    /// and the open project *is* what the pending autosave would have written — `scheduleAutosave`
    /// re-reads `currentProject` when its debounce fires rather than capturing it at schedule time. It
    /// writes unconditionally because a pending debounce is not visible from outside
    /// `ProjectWorkspace`: `autosaveStatus` is still `.idle` or `.saved` during those 500 ms, so
    /// "nothing to do" and "half a second of unwritten edits" look identical from here. The write is
    /// idempotent, so doing it when it was not needed costs a few milliseconds and nothing else.
    ///
    /// *When* the project is read depends on the path. The blocking caller reads it here, before the
    /// task — it gets no later chance, because the main thread it is about to park is where the
    /// session lives. The draining caller reads it *again after the drain*, inside the task, because
    /// the writes being drained are allowed to change the answer: quitting just after `mimic project
    /// delete` used to capture the doomed project here, wait for the delete to land, and then save
    /// the captured row straight back into the store it had just been deleted from.
    ///
    /// `Task.detached` is load-bearing. Nothing in the chain then needs the main actor — the
    /// repository is nonisolated and GRDB runs the transaction on its own queue — which is what lets
    /// the blocking waiter below block the main thread without deadlocking against the work it is
    /// waiting for.
    /// - Parameter drainingStoreWrites: whether the caller can afford to wait for the in-flight
    ///   project-lifecycle writes. **Only a caller that leaves the main actor free may pass `true`.**
    ///
    /// That parameter exists because passing `true` unconditionally deadlocked every quit, and the
    /// mechanism is worth writing down because nothing about it is visible at the call site.
    /// `ProjectWorkspace`'s `createProject`, `duplicateProject` and `deleteProject` answer before the
    /// store has the change — that is what makes the window feel immediate — as does an import,
    /// though one step further out: `ProjectWorkspace.importProject` awaits its own write and
    /// reports whether the store took the document, and it is `AppState.importProject` that
    /// dispatches it into an untracked `Task` and returns. All four are in the same write chain, and
    /// `ProjectWorkspace.awaitPendingStoreWrites()` is the drain built so a
    /// `mimic project delete Foo` still in flight is not lost to the `mimic app stop` behind it.
    /// But `ProjectWorkspace` is `@MainActor`, so awaiting that method from this detached task is a
    /// hop *onto* the main actor — and `flushPendingSaveBlocking` is holding the main **thread** in
    /// `Thread.sleep` at the same time. The hop cannot be serviced, the save below it never runs,
    /// and the signal never finishes: ⌘Q spent the full two-second deadline and then dropped the
    /// edit it was there to save. Worse than the defect it was written to fix, green in CI, and — at
    /// the time — invisible to every test. `ControlPlaneCoordinatorTests` now drives both quit
    /// paths, and the blocking one is held to the deadline, so a regression into that deadlock fails
    /// the suite instead of shipping.
    ///
    /// The signal path is `async` and suspends on `Task.sleep`, which leaves the main actor free, so
    /// it drains. ⌘Q cannot, and the honest fix is `applicationShouldTerminate` returning
    /// `.terminateLater` — that keeps the runloop alive so main-actor work can finish, instead of
    /// blocking the thread that has to run it. That is a change to the app's termination contract
    /// and wants a machine that can actually quit the app to verify it; until then this path saves
    /// the open project, which is what it did before the drain was added, and says what it cannot do.
    private func startPendingSave(drainingStoreWrites: Bool) -> PendingSaveSignal? {
        let repository = self.repository
        let appState = self.appState
        let project = appState?.currentProject
        // Read here, on the main actor, where this method already runs — not inside the task below.
        let workspace = drainingStoreWrites ? appState?.projects : nil

        // Nothing owed and nothing in flight: do not make the caller wait on an empty deadline.
        guard repository != nil, project != nil || workspace != nil else { return nil }

        let didFinish = PendingSaveSignal()
        Task.detached(priority: .userInitiated) {
            var projectToSave = project
            if let workspace {
                await workspace.awaitPendingStoreWrites()
                // Re-read once the chain is drained, because the drained writes change the answer:
                // a `mimic project delete` still in flight nils the open project on its way through
                // the chain, and the value captured before the drain is exactly the row that delete
                // just removed — saving it resurrected the project the caller had deleted. Only
                // this draining branch may hop to the main actor: the blocking caller never sets
                // `workspace`, so the quit path that parks the main thread never reaches this line.
                projectToSave = await MainActor.run { appState?.currentProject }
            }

            // Then the debounced edit to whatever is open. A store that refuses this has nowhere to
            // report it — there is no window left to show `autosaveStatus` in, and the caller ends
            // the process as soon as this returns.
            if let repository, let projectToSave {
                try? await repository.save(projectToSave)
            }
            didFinish.markFinished()
        }
        return didFinish
    }

    /// Returns when the store is done or `shutdownFlushTimeoutSeconds` has passed, whichever is first.
    ///
    /// Polled rather than raced in a task group, for the reason the bound exists at all: a group does
    /// not return until every one of its children has finished, so cancelling the timeout's sibling
    /// would still leave a wedged write holding the quit open. `AppLauncher.waitForReadiness` polls a
    /// deadline for the same kind of reason.
    ///
    /// Internal rather than private so the drain-ordering property is testable — see
    /// `ControlPlaneCoordinatorTests`.
    func flushPendingSave() async {
        // `true`: this path suspends on `Task.sleep` below rather than blocking, so the main actor
        // stays free to run the lifecycle writes being drained.
        guard let didFinish = startPendingSave(drainingStoreWrites: true) else { return }
        let deadline = ContinuousClock.now.advanced(by: .seconds(Self.shutdownFlushTimeoutSeconds))
        while !didFinish.hasFinished, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    /// The same flush for the path that has no `await` left in it.
    ///
    /// `willTerminate` is posted from inside `NSApplication.terminate`, and the process ends as soon
    /// as its observers return — there is nowhere to suspend to, so this one blocks the main thread
    /// for the same bound the signal path suspends for. A quit that takes a few extra milliseconds is
    /// not a defect; a quit that drops the edit you just made is, and ⌘Q dropped it exactly as
    /// `SIGTERM` did.
    ///
    /// Internal rather than private so a test can hold the main thread exactly as ⌘Q does and
    /// assert the save still lands inside the deadline — the deadlock this file documents is
    /// precisely a change that makes this path need the parked main actor.
    func flushPendingSaveBlocking() {
        // `false`, and not negotiable: the loop below holds the main thread, so a drain that needs
        // the main actor could never complete. See `startPendingSave(drainingStoreWrites:)`.
        guard let didFinish = startPendingSave(drainingStoreWrites: false) else { return }
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
