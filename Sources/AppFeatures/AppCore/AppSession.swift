import AppKit
import Foundation

/// Owns the app's state and its one-time startup for the process's lifetime.
///
/// This exists because a `Scene`'s initialiser is not a startup hook. SwiftUI re-runs
/// `MimicApp.body` — and therefore `MimicScene.init` — whenever the app graph is invalidated, so
/// anything built inline there is built again on every evaluation. `AppState` is the expensive
/// case: constructing one opens the SQLite store, runs `AppMigrations.registerAll` and reloads the
/// last-opened project. Doing that per evaluation cost about 150 database opens a second and pinned
/// a core; the window stopped tracking the pointer, which is what a user sees as "I can't resize
/// it", and the app died if they kept trying.
///
/// Same reasoning as `ControlPlaneCoordinator.shared`, and for the same reason: a process-level
/// thing has to be owned by the process, not by a view or scene that may be rebuilt at any moment.
@MainActor
final class AppSession {

    /// Created on first access — which is the first `MimicScene.init`, before any window exists.
    static let shared = AppSession()

    let appState: AppState

    private init() {
        // Before `AppState`, which opens the store: a reset that runs afterwards would delete the
        // database out from under the connection the run is about to use.
        #if DEBUG
        if MimicScene.shouldResetForTesting(arguments: ProcessInfo.processInfo.arguments) {
            UITestSupport.resetAppIfNeeded()
        }
        #endif

        appState = AppState()

        // Started here, not from a view's `onAppear`: windowless runs never present a view, and the
        // whole point of the control plane is that `mimic` can reach the session either way.
        HeadlessMode.applyActivationPolicyIfNeeded()
        // The session's own store, not a second connection to the same file.
        ControlPlaneCoordinator.shared.start(
            appState: appState,
            repository: appState.repository
        )
    }
}
