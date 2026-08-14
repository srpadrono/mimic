import Foundation
import Observation

/// What the window is presenting, and what it has selected — the state that exists only because a
/// window exists.
///
/// None of it is a fact about the project: closing every sheet and clearing every selection changes
/// nothing a `mimic` invocation could observe. It lived on `AppState` beside the composition root,
/// the command plumbing and the project lifecycle, where the reader had no way to tell "a menu item
/// asked the sidebar to switch tabs" apart from "the store could not be opened".
///
/// ``AppState`` forwards every one of these, with the same names and the same types, so a view still
/// writes `appState.showNewProjectSheet = true` and still binds `$appState.selectedJourneyID` — the
/// same shape it already uses for `appState.requestLogs`, which has forwarded to
/// ``MockServerRuntime`` all along. That is deliberate: this is a decomposition, not a rename, and
/// the callers are spread across `MimicScene`, `ContentView` and `WorkspaceView`.
@Observable
@MainActor
final class WindowPresentation {
    /// The new-endpoint sheet, presented by `WorkspaceView`.
    var showNewEndpointSheet = false

    /// The new-project sheet, presented by `ContentView` so one flag serves both the welcome window
    /// and an open workspace — File ▸ New Project has to work from either.
    var showNewProjectSheet = false

    /// A menu or CLI request to switch the sidebar to a given navigator. Consumed by `WorkspaceView`
    /// and reset, because the menu sits above the window that owns the sidebar's state.
    ///
    /// This is how Journeys ▸ Show Journeys arrives too. There used to be a separate `showJourneys`
    /// flag that opened a window; journeys have one home now, so there is one request.
    var navigatorRequest: NavigatorTab?

    /// The journey being edited in the navigator.
    var selectedJourneyID: UUID?
}
