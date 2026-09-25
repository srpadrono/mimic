import SwiftUI
import Domain

struct ContentView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var appState = appState
        @Bindable var updates = appState.updates

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
                    onRequestRenameProject: { entry in
                        appState.projectRenameTarget = .init(id: entry.id, name: entry.name)
                    },
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
        .sheet(item: $appState.projectRenameTarget) { target in
            RenameItemSheet(
                title: "Rename project", fieldLabel: "Project name",
                identifier: "projectRename", initialName: target.name
            ) { name in
                appState.renameProject(id: target.id, name: name)
            }
        }
        // One presenter, for the same reason the new-project sheet has one: the menu item works from
        // the welcome window and from an open project, and the background check can raise it from
        // either.
        .sheet(isPresented: $updates.isShowingSheet, onDismiss: updates.sheetDidDismiss) {
            UpdateSheet(service: appState.updates)
        }
        // The automatic check, once the window is up.
        //
        // Delayed, and `Task.sleep` rather than `DispatchQueue.asyncAfter` — the house rule. The
        // delay is not cosmetic: launch is already opening the store, restoring a project and
        // starting the control plane, and a network request in the middle of that competes with
        // work the user is waiting for. `UpdatePreferences.isAutomaticCheckDue` decides whether
        // anything actually happens, so on all but one launch a day this is a sleep and a `false`.
        .task {
            #if DEBUG
            // Never in a test run — see `UITestSupport.suppressesAutomaticUpdateChecks`. A unit
            // suite is hosted by this app, so without the guard every `swift`/`xcodebuild test`
            // invocation would call GitHub; and a UI test would race its own sheet against one this
            // raised behind it.
            guard !UITestSupport.suppressesAutomaticUpdateChecks() else { return }
            #endif
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            appState.updates.checkAutomaticallyIfDue()
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
            // The reason is `ProjectStore`'s prose about why the store would not open, so a test can
            // only reach it as a substring of the window's static texts. Named, like the button
            // above it, so asserting *which* failure was reported does not mean matching on a
            // sentence somebody will reword.
            Text(reason)
                .accessibilityIdentifier("storeFailure.message")
        }
        // A store one version ahead opens, reads, and looks completely normal — and loses data the
        // moment anything is saved, with no error raised anywhere. That is why it gets an alert of
        // its own rather than a line in a status bar: by the time a symptom is visible, the writing
        // has already happened. See `StoreProvenance` for how the condition is detected.
        .alert(
            "These projects were saved by a newer Mimic",
            isPresented: $appState.isShowingNewerStoreWarning,
            presenting: appState.newerStoreWarning
        ) { _ in
            Button("Continue anyway") { appState.newerStoreWarning = nil }
                .accessibilityIdentifier("newerStore.continueButton")
                .accessibilityLabel("Continue anyway")
        } message: { warning in
            Text(warning)
                .accessibilityIdentifier("newerStore.message")
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
            // The refusal itself — a validator's sentence, which is the thing worth asserting when a
            // change is silently not made. Named for the same reason the store-failure message is.
            Text(message)
                .accessibilityIdentifier("commandError.message")
        }
    }
}

#if DEBUG
#Preview {
    ContentView()
        .environment(AppState.preview())
}
#endif
