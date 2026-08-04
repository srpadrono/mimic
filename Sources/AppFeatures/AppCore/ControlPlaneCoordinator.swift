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

    /// `nil` until the server has bound; useful for diagnostics and tests.
    private(set) var boundPort: Int?
    private(set) var startupError: String?

    func start(appState: AppState, repository: any ProjectRepository) {
        guard server == nil else { return }

        let host = AppControlHost(appState: appState, repository: repository)
        let server = ControlServer(host: host, mode: HeadlessMode.isEnabled ? "headless" : "app")
        self.host = host
        self.server = server

        let port = Self.resolvePort()
        Task { @MainActor [weak self] in
            do {
                let bound = try await server.start(port: port, advertise: true)
                self?.boundPort = bound
                self?.installTerminationHandlers()
            } catch {
                // A control plane that cannot bind must not stop the app from working — the window is
                // still fully usable, so the failure is recorded rather than raised.
                self?.startupError = error.localizedDescription
                self?.server = nil
                self?.host = nil
            }
        }
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
    private func installTerminationHandlers() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            ControlEndpointFile.remove()
        }

        for signalNumber in [SIGTERM, SIGINT] {
            // The default disposition terminates the process outright, and a dispatch source never
            // fires if that happens first.
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler {
                ControlEndpointFile.remove()
                // `exit`, not `NSApp.terminate`. Ignoring the signal above means this handler is now
                // the *only* thing that can end the process, so it has to be something that cannot be
                // deferred or cancelled — and AppKit termination is both. Routing through it left the
                // app alive through a SIGTERM whenever something was mid-flight (an edit waiting on
                // autosave, an open sheet), which is worse than the crude exit it replaced.
                exit(0)
            }
            source.resume()
            terminationSignalSources.append(source)
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
