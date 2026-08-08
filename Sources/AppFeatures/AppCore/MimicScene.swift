import AppKit
import Domain
import Persistence
import SwiftUI

public struct MimicScene: Scene {
    @State private var appState: AppState

    /// Nothing here may be expensive, and nothing here may mutate observable state.
    ///
    /// `MimicApp.body` re-runs this initialiser on every evaluation, and `State(wrappedValue:)`
    /// *evaluates* its argument each time while keeping only the first result. This used to build a
    /// whole `AppState` inline — so every evaluation opened the SQLite store, ran the migrations and
    /// reloaded the open project, then threw the result away.
    ///
    /// That was not merely wasteful, it was self-sustaining: `AppState.init` reads
    /// `projects.currentProject` (binding the server's mocks) and then writes it
    /// (`loadLastOpenedProject`). A read followed by a write of the same observable property, inside
    /// a body evaluation, invalidates the body that is still running — so the app re-evaluated,
    /// re-opened the database and re-invalidated, about 150 times a second, forever. It only bit
    /// when a project was open, because `loadLastOpenedProject` returns early when there is nothing
    /// to restore; that is why it looked intermittent.
    ///
    /// The session is created once by `AppSession.shared`, so from the second evaluation on this
    /// initialiser reads a stored reference and does nothing else.
    public init() {
        _appState = State(wrappedValue: AppSession.shared.appState)
    }

    public var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                #if DEBUG
                .onAppear(perform: UITestSupport.activateAppIfNeeded)
                #endif
        }
        // `.contentMinSize`, not `.contentSize`. Both propagate the content's minimum to the window,
        // but `.contentSize` also pins the *maximum* to the content's — which would stop the window
        // being zoomed or filled, on an app whose whole job is watching a log scroll.
        //
        // The floors themselves live on the two branches of `ContentView`, because they share this
        // scene and want very different numbers: `WorkspaceView` needs 1140pt before its request log
        // starts losing columns, and `WelcomeWindow` is a 640pt list of recent projects. A scene-level
        // constant would make the welcome screen as wide as the workspace.
        .windowResizability(.contentMinSize)
        // `.unified`, which is what produces the tall single-band toolbar the redesign draws — and on
        // macOS 26 it is also what lets the sidebar's material run up under the titlebar, which is
        // the "bleed" the handoff attributes to `titlebarAppearsTransparent`. That API is the
        // pre-Big-Sur mechanism and is not what does this any more; the toolbar style plus a
        // full-height sidebar split item is.
        .windowToolbarStyle(.unified)
        // The redesign's reference size. Only a starting point — AppKit restores the real one per
        // window — but a first launch that opens at the size the design was drawn at is worth the
        // one line.
        .defaultSize(width: 1487, height: 944)
        .commands {
            CommandGroup(replacing: .newItem) {
                // "New Project…" opens the new-project sheet. It used to be wired straight to
                // `closeProject`, so the menu item named after creating a project did not create one
                // — it closed the one you were in and left you at the welcome window to press the
                // real button. ⌘N on a project you were working in therefore threw away your place,
                // under a label that promised the opposite. The ellipsis is now honest too: this
                // opens a dialog.
                Button("New Project\u{2026}") { appState.showNewProjectSheet = true }
                    .keyboardShortcut("n", modifiers: .command)

                // Closing is its own command now, and says so. ⇧⌘W rather than ⌘W, because ⌘W is
                // AppKit's close-the-window and taking it would leave no way to close the window.
                Button("Close Project") { appState.closeProject() }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
                    .disabled(appState.currentProject == nil)
            }

            // ⌘⇧P, the palette shortcut people arrive with from other editors. Not ⇧⌘O, which is
            // Xcode's Open Quickly and means "find a file" rather than "run a command".
            CommandGroup(after: .toolbar) {
                Button("Command Palette\u{2026}") { appState.showCommandPalette = true }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(appState.currentProject == nil)

                // ⌘F goes to the navigator's filter, which is the one the window pins above a list
                // that can grow past the pane. The request log's filter is a different control and
                // is not wired yet; `docs/CLI.md` says so rather than leaving it to be discovered.
                Button("Filter Endpoints") { appState.focusFilterRequest += 1 }
                    .keyboardShortcut("f", modifiers: .command)
                    .disabled(appState.currentProject == nil)
            }

            CommandMenu("Server") {
                Button(serverToggleTitle) {
                    Self.toggleServer(
                        serverState: appState.serverState,
                        start: appState.startServer,
                        stop: appState.stopServer
                    )
                }
                // ⌘R, not ⇧⌘R. The three R bindings only make sense stated together:
                //
                //   ⌘R    start/stop the mock server
                //   ⌥⌘R   restart the active journey
                //   ⇧⌘R   (free)
                //
                // Starting the server is this app's Run, and ⌘R is Run in the app this one is
                // measured against. It was on ⇧⌘R for no recorded reason while ⌘R sat unused, which
                // put the primary action one modifier further away than the secondary one beside it.
                .keyboardShortcut("r", modifiers: .command)
                .disabled(!canToggleServer)
            }

            // ⌘1 / ⌘2, the shape of shortcut Xcode gives its navigators. `appState.navigatorRequest`
            // rather than a direct binding because the menu lives at scene level, above the window
            // that owns the sidebar's state.
            CommandGroup(after: .sidebar) {
                ForEach(NavigatorTab.allCases) { tab in
                    Button(tab.title) { appState.navigatorRequest = tab }
                        .keyboardShortcut(
                            KeyEquivalent(tab.shortcut),
                            modifiers: .command
                        )
                        .disabled(appState.currentProject == nil)
                }
            }

            CommandMenu("Journeys") {
                // Selects the navigator's Journeys tab. It used to open a window of its own, which
                // meant journeys had two homes and neither was obviously the real one — you could be
                // looking at the list in the sidebar and open a second copy of it on top.
                //
                // Same destination as View ▸ Journeys (⌘2), reached by a second accelerator because
                // this is the menu people look in for journeys. Two menu items may share an action;
                // what they must not share is a key equivalent — AppKit honours only the first, which
                // is how the Window ▸ Journeys item once showed ⌘⇧J and did nothing.
                Button("Show Journeys") { appState.navigatorRequest = .journeys }
                    .keyboardShortcut("j", modifiers: [.command, .shift])
                    .disabled(appState.currentProject == nil)


                Divider()

                Button("Restart Active Journey", action: appState.restartActiveJourney)
                    .keyboardShortcut("r", modifiers: [.command, .option])
                    .disabled(appState.activeJourney == nil)

                Button("Advance Active Journey", action: appState.advanceActiveJourney)
                    .keyboardShortcut(.rightArrow, modifiers: [.command, .option])
                    .disabled(appState.activeJourney == nil)

                Button("Deactivate Journey") { appState.activateJourney(id: nil) }
                    .disabled(appState.activeJourney == nil)
            }
        }

        // No second window. Journeys live in the navigator, next to the endpoints they override.
        //
        // They used to have a dedicated `Window`, on the reasoning that a journey is authored once
        // and then watched while the workspace stays on the endpoint you are debugging. What that
        // produced was two homes for one feature and no way to tell which was authoritative: the
        // sidebar's Journeys tab and the window showed the same list, so opening the window put a
        // duplicate of the panel you were already looking at on top of it. Whichever one you edited,
        // the other was also correct, which is the definition of a confusing interface.
        //
        // The navigator is the surviving home — it is where a journey belongs, because a journey
        // rewrites what every endpoint returns and you want to see that beside the endpoints.
    }

    private var serverToggleTitle: String {
        Self.serverToggleTitle(for: appState.serverState)
    }

    private var canToggleServer: Bool {
        Self.canToggleServer(
            hasCurrentProject: appState.currentProject != nil,
            serverState: appState.serverState
        )
    }

    static func shouldResetForTesting(arguments: [String]) -> Bool {
        arguments.contains("-MimicResetForTesting")
    }

    static func serverToggleTitle(for serverState: ServerState) -> String {
        switch serverState {
        case .running: "Stop Server"
        default: "Start Server"
        }
    }

    static func canToggleServer(hasCurrentProject: Bool, serverState: ServerState) -> Bool {
        guard hasCurrentProject else { return false }
        switch serverState {
        case .stopped, .running, .error: return true
        case .starting, .stopping: return false
        }
    }

    static func toggleServer(
        serverState: ServerState,
        start: () -> Void,
        stop: () -> Void
    ) {
        switch serverState {
        case .running: stop()
        case .stopped, .error: start()
        default: break
        }
    }
}
