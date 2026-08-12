import SwiftUI
import Domain

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState

        // Deliberately unanimated, and it must stay that way. This branch swaps 100% of the window's
        // contents, so any transition here is the whole window cross-fading — and `WorkspaceView`
        // builds all four of its panels on first appearance, so what would fade in is a
        // half-assembled workspace. `⌘N` closes a project and takes this branch mid-session,
        // not only at launch. An instant swap is what a document-based Mac app does, and it is also
        // the only version of this that has nothing for Reduce Motion to suppress: neither branch
        // carries a `.transition`, and no caller wraps `openProject`/`closeProject` in
        // `withAnimation`, so there is no ambient animation for the switch to inherit.
        Group {
            if appState.currentProject != nil {
                WorkspaceView(layoutStore: appState.panelLayoutStore)
            } else {
                WelcomeWindow(
                    recentProjects: appState.recentProjects,
                    onOpenProject: appState.openProject(id:),
                    onDuplicateProject: appState.duplicateProject(id:),
                    onDeleteProject: appState.deleteProject(id:),
                    onRequestNewProject: { appState.showNewProjectSheet = true }
                )
            }
        }
        .navigationTitle(appState.currentProject?.name ?? "Mimic")
        // Presented here rather than inside `WelcomeWindow`, because File ▸ New Project has to work
        // whichever branch is showing — and one sheet with one presenter is what stops the two
        // branches drifting into two slightly different new-project dialogs.
        //
        // Creating from an open project replaces it, which is what `createProject` already does:
        // it stops the server first, then swaps the workspace. Nothing is lost, because a project is
        // saved as you edit it.
        .sheet(isPresented: $appState.showNewProjectSheet) {
            NewProjectSheet { name, port in
                appState.createProject(name: name, port: port)
            }
        }
        // Losing everything on quit is not something to mention in a status bar. If the store could
        // not be opened, the session is ephemeral and the user needs to know before they do work.
        .alert(
            "Your work will not be saved",
            isPresented: $appState.isShowingStoreFailure,
            presenting: appState.storeFailure
        ) { _ in
            // The one control in this file, and it was the one element in the app with no identifier
            // and no label: nothing could dismiss the alert from a test, so the failure path was
            // unreachable to the suite that is supposed to prove it works.
            Button("Continue anyway") { appState.storeFailure = nil }
                .accessibilityIdentifier("storeFailure.continueButton")
                .accessibilityLabel("Continue anyway")
        } message: { reason in
            Text(reason)
        }
        // Every rule the window breaks is refused by `ProjectCommandExecutor`, and until this alert
        // existed the refusal went nowhere: `AppState.run` set `lastCommandError` and nothing in the
        // app, the tests, or the UI suite ever read it. Type a header value containing a newline and
        // the editor kept showing it, the endpoint kept the old one, and switching endpoints put the
        // old value back — a change silently not made, which is the worst way for a validator to
        // fail. Presented here for the same reason the store-failure alert is: one presenter, so both
        // branches of the window report a refusal the same way.
        .alert(
            "Couldn't apply that change",
            isPresented: $appState.isShowingCommandError,
            presenting: appState.lastCommandError
        ) { _ in
            Button("OK") { appState.lastCommandError = nil }
                .accessibilityIdentifier("commandError.okButton")
                .accessibilityLabel("OK")
        } message: { message in
            Text(message)
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environment(AppState.preview())
}
#endif
