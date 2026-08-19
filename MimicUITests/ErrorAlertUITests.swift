import AppKit
import Darwin
import Foundation
import XCTest

/// Every failure surface the window has: the four alerts, the autosave failure arm, the inline
/// validation notes, and the empty states that are genuinely reachable.
///
/// All of it was at zero coverage. The identifiers this suite targets — `storeFailure.continueButton`
/// and `commandError.okButton` above all — were added so a test could dismiss an alert, and then no
/// test was written, so the alerts stayed as unreachable to the suite as they were before the
/// identifiers landed.
///
/// **Two rules shape the whole file.**
///
/// *The launch environment binds at spawn*, so anything a test needs from it goes through
/// ``configureLaunchEnvironment(_:)`` and the settable properties above it — set them before
/// `launchApp()`, never inside a test body after the process is up.
///
/// *A port conflict is produced by the runner, not by a second Mimic.* ``holdPort(from:keepingSuccessorFree:)``
/// binds `127.0.0.1:<port>` in this process and does **not** set `SO_REUSEADDR`, which matters: the
/// engine binds exactly `127.0.0.1` (`MockServerEngine.start`), so an exact-address duplicate is
/// refused with `EADDRINUSE` and `VaporConfigurator.mapStartError` turns that into
/// `MockServerError.portInUse`. A wildcard listener with `SO_REUSEADDR` on both sides is precisely
/// the pair BSD *allows* to coexist, which would make the conflict fail to happen. The descriptor is
/// closed in `tearDownWithError`, because a listener leaked out of one test breaks every later test
/// that tries to bind a port.
///
/// **A third rule was learned from the first CI run, and it is about what a query may assume.** Nine
/// of these twelve tests failed on a handle that does not exist in the tree — an alert message
/// addressed by the identifier its `Text` was given, a `DSTextField` validation note addressed by
/// the identifier `DSTextField` builds for it, a warning row whose identifier resolves to the *icon*
/// beside the sentence. Every one is the accessibility-tree rule the UI skill states: a container's
/// `.accessibilityIdentifier` overrides its descendants'. `NewProjectSheet` stamps `serverPortField`
/// on the whole `DSTextField` — which is how `app.textFields["serverPortField"]` finds the input —
/// and that same stamp lands on the validation note underneath it, so
/// `ds.textfield.newProject.port.error` is a name nothing in the window answers to. What survives
/// the flattening is the element's **label**, which for all three of these is the sentence the user
/// reads. So the queries here address a failure surface by what it *says*, falling back to the
/// identifier rather than the other way round; the assertions are stronger for it, because a note
/// found by its words has already proved it carries them.
final class ErrorAlertUITests: MimicUITestCase {

    // MARK: - Launch configuration

    /// `MIMIC_DATABASE_PATH` for the next launch, or `nil` to leave the run's own store alone.
    ///
    /// `/dev/null/mimic.sqlite` is the spelling the store-failure tests use: `/dev/null` exists and
    /// is not a directory, so `DatabaseFactory.makeAppDatabaseQueue`'s `createDirectory` throws
    /// before SQLite is ever opened, and `ProjectStore.open` degrades to memory with a non-nil
    /// `failure` rather than trapping. It is also inert for the reset — `UITestSupport.resetApp`
    /// deletes exactly this path, and nothing can be removed from inside `/dev/null`.
    private var databasePathOverride: String?

    /// Whether this launch gets `WriteFailingProjectRepository`: reads work, every write throws.
    private var failsProjectWrites = false

    /// A listening socket held open in the runner, so the app's bind fails. `-1` when none is held.
    private var heldSocket: Int32 = -1

    /// Why no candidate port could be held, syscall and `errno` named — empty when one was.
    ///
    /// The first CI run failed three of these tests on `XCTAssertTrue(holdPort(…))` and the log said
    /// only "The runner should be able to hold port 62311". A boolean fixture that cannot say what
    /// the kernel told it is a fixture that has to be re-run to be diagnosed, which on a hosted
    /// runner means a round trip per guess.
    private var portHoldDiagnosis = ""

    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Port 0 lets the OS pick the control plane's port, so a run collides neither with a
        // developer's running instance nor with a second run on the same machine. The discovery-file
        // half of that isolation is exported by the launch contract itself.
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
        if let databasePathOverride {
            app.launchEnvironment["MIMIC_DATABASE_PATH"] = databasePathOverride
        }
        if failsProjectWrites {
            app.launchEnvironment["MIMIC_FAIL_PROJECT_WRITES"] = "1"
        }
    }

    override func tearDownWithError() throws {
        releaseHeldPort()
        try super.tearDownWithError()
    }

    // MARK: - ERRSTORE — the store cannot be opened

    /// The alert that says the session is ephemeral, the sentence explaining why, the dismissal, and
    /// that the ephemeral session is still a usable one.
    ///
    /// Launched through ``launchUntilStoreFailureAlert()`` rather than the usual path: the alert comes
    /// up *over* the welcome window, so the window cannot be the readiness condition — the alert is.
    @MainActor
    func testStoreFailureAlertExplainsTheEphemeralSessionAndDismisses() throws {
        databasePathOverride = "/dev/null/mimic.sqlite"

        // ERRSTORE-01 / ERRSTORE-02. Matched on the alert's *title*, which is a `String` the window
        // owns rather than a sentence a validator produced, and on the body's own words after it.
        // `storeFailure.message` is still tried first — see ``alertText(messageIdentifier:)`` for why
        // it may not be in the tree at all.
        XCTAssertTrue(
            launchUntilStoreFailureAlert(),
            "A store that cannot be opened should raise the \"Your work will not be saved\" alert — "
                + "the window reads: " + alertText(messageIdentifier: "storeFailure.message")
        )
        XCTAssertTrue(
            waitForAlert(messageIdentifier: "storeFailure.message", saying: "in memory", timeout: 5),
            "The alert should say the session is running in memory — read: "
                + alertText(messageIdentifier: "storeFailure.message")
        )

        // ERRSTORE-03.
        alertButton(identifier: "storeFailure.continueButton", label: "Continue anyway").click()
        XCTAssertTrue(
            waitForAlertToClear(messageIdentifier: "storeFailure.message", saying: "will not be saved"),
            "\"Continue anyway\" should dismiss the alert"
        )

        // ERRSTORE-04. Everything works in the fallback store; only quitting loses it.
        XCTAssertTrue(welcome.assertVisible(timeout: 10), "The welcome window should be usable")
        createProjectViaUI(name: "Ephemeral")
        XCTAssertTrue(
            workspace.assertVisible(),
            "A project created in an ephemeral session should open like any other"
        )
    }

    /// ERRSTORE-05 — the alert is about the store, not about launching.
    ///
    /// Both launches are in one test on purpose. A test that merely launches normally and finds no
    /// alert would pass with the alert deleted; failing first and then succeeding is what ties the
    /// alert to the store it is reporting on.
    @MainActor
    func testRelaunchWithAReachableStoreShowsNoStoreFailureAlert() throws {
        databasePathOverride = "/dev/null/mimic.sqlite"
        XCTAssertTrue(
            launchUntilStoreFailureAlert(),
            "The unopenable store should raise the alert on the first launch — the window reads: "
                + alertText(messageIdentifier: "storeFailure.message")
        )

        app.terminate()
        // Clearing the key rather than naming another path: with no override,
        // `UITestSupport.databaseURL` resolves to `mimic-uitests.sqlite`, which is the run's own
        // store and the only one this suite may open.
        app.launchEnvironment["MIMIC_DATABASE_PATH"] = nil

        XCTAssertTrue(
            UITestApp.launchAndBringToForeground(app) { self.welcome.assertVisible(timeout: 1) },
            "The app should relaunch onto a usable welcome window"
        )
        XCTAssertFalse(
            waitForAlert(
                messageIdentifier: "storeFailure.message",
                saying: "will not be saved",
                timeout: 3
            ),
            "A store that opens normally must not report a failure"
        )
    }

    // MARK: - ERRCMD — an edit the command executor refuses

    /// ERRCMD-01 / -02 / -03 — a header name the RFC 9110 token grammar refuses.
    ///
    /// **A lone space does not reach the executor**, which is worth stating because it looks like the
    /// obvious trigger: `EndpointEditorView.headersDictionary(from:)` trims each name and drops the
    /// ones that trim to nothing, so `" "` produces the same empty dictionary the scenario already
    /// holds, `headersAreDirty` answers `false`, and no command is ever issued.
    ///
    /// **A comma, one keystroke, is the trigger this uses**, and the choice is about determinism
    /// rather than about taste. `","` is not a `tchar` (RFC 9110 §5.6.2), so the *first* character
    /// typed is already refused — with a name like `"X Bad"` the debounce commits the honest prefix
    /// `"X"` first, which is a perfectly valid header, and the refusal then arrives on some later
    /// keystroke with the remaining ones landing on an alert that is already up. One character means
    /// one settle, one command, one alert, and nothing typed into it afterwards. It is also the
    /// vector `EndpointValidator.validateHeader` names: a separator character in a name ends the
    /// name, and everything after it is read by the client as a further header.
    ///
    /// **It used to type `":"`, and that made the test depend on the host's keyboard layout.** On a
    /// British layout `:` is Shift-`;`, and `typeText(":")` is silently dropped — the field kept
    /// whatever it already held and no command was ever issued, so the assertion that fired was the
    /// one about the missing alert and it pointed squarely at the app's header validation. The
    /// validation was never at fault; nothing had been typed for it to refuse. Proven by typing a
    /// plain `"a"` first: the `a` landed and the `:` after it did not. `,` is unshifted on both US
    /// and British layouts and is equally absent from the token grammar, so the test now asserts the
    /// same rule without asserting anything about the machine it runs on.
    @MainActor
    func testRefusedHeaderNameRaisesTheCommandErrorAlert() throws {
        launchApp()
        createProjectViaUI(name: "Header Refusal")
        createEndpointViaUI(name: "Users", path: "/api/users")

        // Hide the drawer and scroll each target into view before clicking it — the idiom every
        // other editor test here uses. Not what was breaking this one, but this test was the only
        // editor interaction in the suite that skipped it.
        hideRequestLogDrawer()

        XCTAssertTrue(addHeaderButton.waitForExistence(timeout: 5), "The editor should offer 'Add header'")
        XCTAssertTrue(revealInEditor(addHeaderButton), "'Add header' should be reachable in the editor")
        addHeaderButton.click()

        let key = endpointEditor.headerKeyField(at: 0)
        XCTAssertTrue(key.waitForExistence(timeout: 5), "Adding a header should give the row a name field")
        XCTAssertTrue(revealInEditor(key), "The header name field should be reachable in the editor")
        key.click()
        key.typeText(",")

        // Prove the keystroke landed *before* waiting on anything downstream of it.
        //
        // Without this the test cannot tell "the app failed to refuse a bad header" from "the
        // character never reached the field", and those have opposite fixes — the second one is what
        // was actually happening, and it read as the first for as long as this check sat at the end
        // of the test instead of here.
        XCTAssertEqual(
            (key.value as? String) ?? "",
            ",",
            "The comma should have landed in the header name field"
        )

        // The 300ms settle, then `applyScenarioSpec` → `validateHeaders` → `lastCommandError`.
        XCTAssertTrue(
            waitForAlert(
                messageIdentifier: "commandError.message",
                saying: "Couldn't apply that change",
                timeout: 10
            ),
            "A header name that is not a token should raise \"Couldn't apply that change\" — "
                + "the window reads: " + alertText(messageIdentifier: "commandError.message")
        )
        XCTAssertTrue(
            waitForAlert(messageIdentifier: "commandError.message", saying: "header name", timeout: 5),
            "The alert should name the refusal — read: "
                + alertText(messageIdentifier: "commandError.message")
        )

        alertButton(identifier: "commandError.okButton", label: "OK").click()
        XCTAssertTrue(
            waitForAlertToClear(
                messageIdentifier: "commandError.message",
                saying: "Couldn't apply that change"
            ),
            "OK should clear the refusal"
        )
        // The refused text stays in the field: the change was not made, and the editor does not
        // silently rewrite what you typed. An editor that reverted to the model would show an empty
        // field here — which is exactly the silent-revert this alert was added to end.
        XCTAssertEqual(
            (key.value as? String) ?? "",
            ",",
            "The editor should still show the text the executor refused"
        )
    }

    /// ERRCMD-05 (with ERRPORT-01 / -02 on the way in) — accepting the next port after a conflict on
    /// 65535 reports the refusal instead of quietly doing nothing.
    ///
    /// `AppState.retryStartOnNextPort` runs `.serverConfigure(port: 65536)` *before* it starts, and
    /// bails when the command declines — so the only evidence the user gets is this alert.
    ///
    /// **65535 is the one port in this file that cannot be swapped for a quieter one**, and it is
    /// worth saying why rather than leaving the next reader to wonder. `PortConflictAlertData`
    /// computes `conflictingPort + 1` with nothing clamping it, so 65535 is the *only* conflict that
    /// reaches the refusal — and `conflictingPort` comes from the engine's own `EADDRINUSE`, so
    /// there is no way to reach it but to genuinely hold 65535. It is also the top of the ephemeral
    /// range and therefore the likeliest port on the machine to be transiently busy, which is a real
    /// weakness of the fixture with no alternative available: what it gets instead is a failure that
    /// prints the `errno`, so a busy machine is distinguishable from a runner that cannot listen at
    /// all. See the report for the production change — clamping the offer — that would remove the
    /// need for this fixture altogether.
    @MainActor
    func testAcceptingTheNextPortAbove65535ReportsTheRefusal() throws {
        let port = try XCTUnwrap(
            holdPort(from: [65535]),
            "The runner should be able to hold port 65535 — \(portHoldDiagnosis)"
        )

        launchApp()
        createProjectViaUI(name: "Last Port", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            waitForAlert(messageIdentifier: "portConflict.message", saying: "already in use", timeout: 20),
            "Starting on a port the runner holds should report the conflict — the window reads: "
                + alertText(messageIdentifier: "portConflict.message")
        )
        alertButton(
            identifier: "portConflict.tryPortButton",
            label: "Try port \(port + 1)"
        ).click()

        XCTAssertTrue(
            waitForAlert(messageIdentifier: "commandError.message", saying: "65536", timeout: 10),
            "Port 65536 is out of range, and the refusal must be reported rather than swallowed — "
                + "the window reads: " + alertText(messageIdentifier: "commandError.message")
        )

        alertButton(identifier: "commandError.okButton", label: "OK").click()
        XCTAssertTrue(
            waitForAlertToClear(
                messageIdentifier: "commandError.message",
                saying: "Couldn't apply that change"
            ),
            "OK should clear the refusal"
        )
        XCTAssertFalse(
            waitForServerToReportAURL(timeout: 2),
            "A refused configuration must not leave a server running on a port the project does not hold"
        )
    }

    // MARK: - ERRPORT — the port is already in use

    /// ERRPORT-01 / -02 / -03 / -05 — the conflict, the offer, the start on the next port, and the
    /// accepted port surviving a close and reopen.
    ///
    /// The last of those is the half that used to be lost: the accepted port is written to the
    /// project by `.serverConfigure` before the runtime is told, so reopening has to find it.
    @MainActor
    func testPortConflictOffersTheNextPortAndStoresIt() throws {
        let port = try XCTUnwrap(
            holdPort(from: Self.conflictPorts, keepingSuccessorFree: true),
            "The runner should be able to hold one of \(Self.conflictPorts) — \(portHoldDiagnosis)"
        )

        launchApp()
        createProjectViaUI(name: "Port Conflict", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            waitForAlert(messageIdentifier: "portConflict.message", saying: "\(port)", timeout: 20),
            "A port another process holds should raise the conflict alert naming that port — "
                + "the window reads: " + alertText(messageIdentifier: "portConflict.message")
        )

        alertButton(identifier: "portConflict.tryPortButton", label: "Try port \(port + 1)").click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port + 1, timeout: 20),
            "Accepting the suggestion should start the server on the next port"
        )

        // ERRPORT-05: the accepted port is a setting, not a runtime detail.
        workspace.serverToggleButton.click()
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible(), "Closing should return to the welcome window")

        let reopened = welcome.findRecentProject(named: "Port Conflict")
        XCTAssertNotNil(reopened, "The project should be listed in recents")
        reopened?.click()
        XCTAssertTrue(workspace.assertVisible(), "The project should reopen")

        let portRow = element(identifier: "inspector.overview.port")
        XCTAssertTrue(
            portRow.waitForExistence(timeout: 10),
            "The inspector's overview should report the project's port"
        )
        XCTAssertTrue(
            waitForText(portRow, containing: "\(port + 1)"),
            "The accepted port should have been stored on the project — read: "
                + combinedText(of: portRow)
        )
    }

    /// ERRPORT-04 — "Keep server stopped" clears the alert and starts nothing.
    @MainActor
    func testPortConflictKeepingTheServerStopped() throws {
        let port = try XCTUnwrap(
            holdPort(from: Self.keepStoppedPorts),
            "The runner should be able to hold one of \(Self.keepStoppedPorts) — \(portHoldDiagnosis)"
        )

        launchApp()
        createProjectViaUI(name: "Keep Stopped", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            waitForAlert(messageIdentifier: "portConflict.message", saying: "already in use", timeout: 20),
            "A port another process holds should raise the conflict alert — the window reads: "
                + alertText(messageIdentifier: "portConflict.message")
        )
        alertButton(identifier: "portConflict.keepStoppedButton", label: "Keep server stopped").click()

        XCTAssertTrue(
            waitForAlertToClear(messageIdentifier: "portConflict.message", saying: "already in use"),
            "Declining the suggestion should dismiss the alert"
        )
        XCTAssertTrue(serverURLWell.waitForExistence(timeout: 5), "The status well should still be there")
        XCTAssertFalse(
            waitForServerToReportAURL(timeout: 2),
            "Keeping the server stopped must not start it on any port"
        )
    }

    // MARK: - ERRSRV — a start failure that is not a port conflict

    /// ERRSRV-01 / -02 / -03 — a privileged port.
    ///
    /// `NewProjectSheet` accepts 1 (its rule is `1...65535`), a sandboxed non-root bind of it fails
    /// with `EACCES`, and `VaporConfigurator.mapStartError` rewrites only "address already in use" —
    /// so this takes the `genericStartError` branch, which is the one arm of `startServer`'s failure
    /// handling a port conflict never reaches.
    @MainActor
    func testPrivilegedPortRaisesTheGenericServerErrorAlert() throws {
        launchApp()
        createProjectViaUI(name: "Privileged Port", port: 1)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            waitForAlert(messageIdentifier: "serverError.message", saying: "Server error", timeout: 20),
            "A bind the OS refuses should raise the generic \"Server error\" alert — the window reads: "
                + alertText(messageIdentifier: "serverError.message")
        )
        // The message is whatever the runtime threw, so there is no literal to match on — only that
        // the alert says something beyond its own title. An empty body is the failure worth catching
        // here: `genericStartError` carrying "" would render an alert that reports nothing.
        XCTAssertFalse(
            alertBody(messageIdentifier: "serverError.message", title: "Server error").isEmpty,
            "The alert should carry the engine's own diagnosis, not just its title"
        )

        alertButton(identifier: "serverError.okButton", label: "OK").click()
        XCTAssertTrue(
            waitForAlertToClear(messageIdentifier: "serverError.message", saying: "Server error"),
            "OK should dismiss the server error"
        )

        // ERRSRV-03: dismissing the alert is not the same as clearing the failure. The runtime is in
        // `.error`, and the toolbar has to keep saying so.
        XCTAssertTrue(
            waitForText(serverURLWell, containing: "error", timeout: 10),
            "The status well should still report the error state — read: "
                + combinedText(of: serverURLWell)
        )
    }

    // MARK: - ERRSAVE — autosave cannot write

    /// ERRSAVE-01 / -02 — the indicator's `.failed` arm, which no sequence of clicks could produce
    /// until `WriteFailingProjectRepository` existed: both real stores are GRDB queues that succeed.
    ///
    /// The session keeps working throughout — reads are forwarded, and every mutation publishes to
    /// the open project before its write is attempted — so the endpoint appears in the editor while
    /// the toolbar says the work is not being saved. That combination *is* the failure being
    /// covered.
    @MainActor
    func testAutosaveReportsFailureWhenTheStoreRefusesWrites() throws {
        failsProjectWrites = true
        launchApp()
        createProjectViaUI(name: "Refused Writes")
        XCTAssertTrue(
            workspace.assertVisible(),
            "A refused write must not stop the project opening in the session"
        )

        createEndpointViaUI(name: "Users", path: "/api/users")
        XCTAssertTrue(
            endpointEditor.statusCodeField.waitForExistence(timeout: 10),
            "The endpoint should be editable even though nothing can be written"
        )

        XCTAssertTrue(
            autosaveFailedIndicator.waitForExistence(timeout: 15),
            "An edit the store refuses should surface as \"Save failed\" in the toolbar"
        )
    }

    // MARK: - ERRVALID — inline validation

    /// ERRVALID-01 / -02 / -03 — the new-project sheet's port.
    ///
    /// The pre-existing `testPortValidationShowsInlineError` is misnamed: it asserts the Create
    /// button's enabled state and never looks at the note. This is the note.
    @MainActor
    func testNewProjectSheetExplainsAPortOutOfRange() throws {
        launchApp()
        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 5), "The sheet should open")

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Port Note")
        replaceText(in: newProjectSheet.portField, with: "99999")

        // Not `newProjectSheet.portValidationError`: that page object queries
        // `ds.textfield.newProject.port.error`, and `NewProjectSheet` stamps `serverPortField` on the
        // whole `DSTextField`, so the note reports the wrapper's name and the built one is in no
        // tree. Matching the rule's own words is the handle that survives — and it asserts the
        // content in the same breath, so there is no second assertion to forget.
        XCTAssertTrue(
            UITestApp.waitForAny(validationNotes(saying: "between 1 and 65535"), timeout: 5),
            "A port above 65535 should be explained under the field, stating the rule"
        )
        XCTAssertFalse(
            newProjectSheet.createButton.isEnabled,
            "Create project should be disabled while the port is out of range"
        )

        // ERRVALID-03: an unfinished form is not a mistake. `portValidationMessage` is deliberately
        // silent on an empty field, and the button stays disabled without a complaint.
        replaceText(in: newProjectSheet.portField, with: "")
        XCTAssertTrue(
            waitForNoValidationNote(saying: "between 1 and 65535"),
            "An empty port field should say nothing at all"
        )

        newProjectSheet.cancelButton.click()
    }

    /// ERRVALID-04 / -05 — the new-endpoint sheet's path.
    @MainActor
    func testNewEndpointSheetExplainsAPathWithoutALeadingSlash() throws {
        launchApp()
        createProjectViaUI(name: "Path Note")

        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5), "The sheet should open")
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("Users")
        replaceText(in: newEndpointSheet.pathField, with: "api/users")

        // `newEndpointSheet.pathError` documents that `newEndpoint.pathError` never existed and names
        // `ds.textfield.newEndpoint.path.error` as the real identifier. That is half a correction:
        // the sheet stamps `newEndpoint.pathField` on the whole `DSTextField`, which is what makes
        // `app.textFields["newEndpoint.pathField"]` resolve, and the same stamp lands on the note. So
        // neither identifier reaches the tree, and the note is matched by its sentence.
        XCTAssertTrue(
            UITestApp.waitForAny(validationNotes(saying: "must start with"), timeout: 5),
            "A path without a leading slash should be explained under the field, stating the rule"
        )
        XCTAssertFalse(
            newEndpointSheet.createButton.isEnabled,
            "Add endpoint should be disabled while the path lacks a leading slash"
        )

        newEndpointSheet.cancelButton.click()
    }

    /// ERRVALID-06 / -07 / -08 / -09 — the two editor fields that refuse a value and say why.
    ///
    /// Both refusals used to be silent: the field went on showing what you typed while the endpoint
    /// kept the value it had, and switching endpoints quietly put the old one back.
    @MainActor
    func testEndpointEditorExplainsARefusedStatusCodeAndDelay() throws {
        launchApp()
        createProjectViaUI(name: "Editor Notes")
        createEndpointViaUI(name: "Users", path: "/api/users")
        XCTAssertTrue(endpointEditor.statusCodeField.waitForExistence(timeout: 10))

        // ERRVALID-06. The message is raised at the 300ms settle, not per keystroke — "6" and "60"
        // are honest prefixes of "600".
        replaceText(in: endpointEditor.statusCodeField, with: "600")
        XCTAssertTrue(
            statusCodeNote.waitForExistence(timeout: 10),
            "A status code outside 200...599 should be explained under the field"
        )
        XCTAssertTrue(
            waitForText(statusCodeNote, containing: "must be between 200 and 599"),
            "The note should state the rule — read: " + combinedText(of: statusCodeNote)
        )

        // ERRVALID-07. An empty field gets its own wording: this field is live, so blank means the
        // endpoint is still serving a code the editor has stopped showing.
        replaceText(in: endpointEditor.statusCodeField, with: "")
        XCTAssertTrue(
            waitForText(statusCodeNote, containing: "Enter a status code", timeout: 10),
            "An empty status code should ask for one — read: " + combinedText(of: statusCodeNote)
        )

        // ERRVALID-08. The delay commits on blur, so the complaint arrives when focus leaves.
        replaceText(in: endpointEditor.delayField, with: "abc")
        endpointEditor.groupTagField.click()
        XCTAssertTrue(
            delayNote.waitForExistence(timeout: 10),
            "A delay that is not a whole number should be explained under the field"
        )
        XCTAssertTrue(
            waitForText(delayNote, containing: "whole number"),
            "The note should state the rule — read: " + combinedText(of: delayNote)
        )

        // ERRVALID-09. Typing clears the note (`.onChange(of: delayString)`), so it has to come back
        // on the next blur rather than never having gone.
        replaceText(in: endpointEditor.delayField, with: "-5")
        XCTAssertTrue(
            delayNote.waitForNonExistence(timeout: 5),
            "Editing the field should drop the previous complaint"
        )
        endpointEditor.groupTagField.click()
        XCTAssertTrue(
            delayNote.waitForExistence(timeout: 10),
            "A negative delay should be refused the same way"
        )
    }

    /// ERRVALID-10 — malformed JSON is a *warning*, and the wording is the point: the body is saved
    /// and served exactly as written, because a mock has to be able to serve a broken payload.
    @MainActor
    func testResponseBodyWarnsAboutInvalidJSONWithoutRefusingIt() throws {
        launchApp()
        createProjectViaUI(name: "JSON Warning")
        createEndpointViaUI(name: "Users", path: "/api/users")

        // Before the body can be reached at all: the log takes the bottom of the window and the body
        // card is the last one in the form, so on a runner's window the editor sits under the drawer.
        hideRequestLogDrawer()

        // Letters only, deliberately. The paste inserts verbatim, so bracket completion cannot reach
        // this payload — but "not json" is invalid under any editor's behaviour, which keeps the
        // trigger for the warning independent of what a source-editor dependency does next.
        XCTAssertTrue(
            setResponseBody("not json"),
            "The response body editor should be reachable and should hold what was put in it — it "
                + "holds: " + bodyText()
        )

        // The editor's own contents go into the message beside the warning row. The warning is a
        // function of what the editor holds, so "no warning" has two causes — the row never rendered
        // because the text never arrived, or it rendered and says nothing the tree can read — and a
        // message quoting only the row cannot separate them. `CodeEditor` is an
        // `NSViewRepresentable` around an `NSTextView`, which publishes its string as the element's
        // value, so this reads back the eight characters that were pasted if they landed at all.
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) {
                self.jsonWarningText().localizedCaseInsensitiveContains("not valid JSON")
            },
            "A malformed body should raise the \"Not valid JSON\" warning — read: " + jsonWarningText()
                + " — and the body editor holds: " + bodyText()
        )
        XCTAssertTrue(
            jsonWarningText().localizedCaseInsensitiveContains("still saved"),
            "The warning must say the body is kept, not rejected — read: " + jsonWarningText()
        )
    }

    /// ERRVALID-12 / -13 / -14 / -15 / -16 / -17 — every rule the journey step sheet enforces, in the
    /// order `commit()` checks them.
    ///
    /// One test rather than six launches: the assertions are independent, and each field has to be
    /// made valid before the next refusal can be reached at all — which is itself the ordering the
    /// sheet promises.
    @MainActor
    func testJourneyStepSheetRefusesEachInvalidFieldInTurn() throws {
        launchApp()
        createProjectViaUI(name: "Step Validation")

        let journeys = JourneysNavigatorPage(app: app)
        let newJourneySheet = NewJourneySheetPage(app: app)
        let stepSheet = JourneyStepSheetPage(app: app)

        journeysTab.click()
        XCTAssertTrue(journeys.waitUntilVisible(), "The journeys navigator should appear")
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()
        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5), "The naming sheet should open")
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText("Step rules")
        newJourneySheet.createButton.click()

        XCTAssertTrue(journeys.addStepButton.waitForExistence(timeout: 10), "The editor should appear")
        journeys.addStepButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5), "The step sheet should open")

        // `JourneyStepSheetPage` carries the fields the journeys suite drives; these two are named
        // here rather than added to it, because this file may not edit that one. Both identifiers
        // sit directly on the `TextField`, the way `stepSheet.pathField` does.
        let delayField = app.textFields["stepSheet.delayField"]
        let repeatField = app.textFields["stepSheet.repeatField"]

        // ERRVALID-12. Only the *empty* case disables the button; a malformed path stays clickable,
        // because the click is what produces the explanation.
        XCTAssertFalse(stepSheet.saveButton.isEnabled, "Add step should be disabled with no path")
        replaceText(in: stepSheet.pathField, with: "/ok")
        let enabledWithAPath = waitForEnabled(stepSheet.saveButton, isEnabled: true)
        XCTAssertTrue(enabledWithAPath, "Add step should enable once there is a path")
        replaceText(in: stepSheet.pathField, with: "")
        let disabledWithoutAPath = waitForEnabled(stepSheet.saveButton, isEnabled: false)
        XCTAssertTrue(disabledWithoutAPath, "Clearing the path should disable Add step again")
        replaceText(in: stepSheet.pathField, with: "/ok")

        // ERRVALID-13. Checked, not coerced: `Int(delayMs) ?? 0` used to turn "abc" into a step that
        // answers instantly, silently.
        replaceText(in: delayField, with: "abc")
        stepSheet.saveButton.click()
        XCTAssertTrue(
            stepSheet.validationMessage.waitForExistence(timeout: 5),
            "A non-numeric delay should be explained rather than coerced"
        )
        XCTAssertTrue(
            waitForText(stepSheet.validationMessage, containing: "Delay must be a whole number"),
            "The complaint should be about the delay — read: "
                + combinedText(of: stepSheet.validationMessage)
        )

        // ERRVALID-14.
        replaceText(in: delayField, with: "0")
        replaceText(in: repeatField, with: "0")
        stepSheet.saveButton.click()
        XCTAssertTrue(
            waitForText(stepSheet.validationMessage, containing: "Serve count must be 1 or more"),
            "A serve count below 1 should be refused — read: "
                + combinedText(of: stepSheet.validationMessage)
        )

        // ERRVALID-15.
        replaceText(in: repeatField, with: "1")
        replaceText(in: stepSheet.statusField, with: "600")
        stepSheet.saveButton.click()
        XCTAssertTrue(
            waitForText(stepSheet.validationMessage, containing: "Status code must be between 200 and 599"),
            "A status code outside 200...599 should be refused — read: "
                + combinedText(of: stepSheet.validationMessage)
        )

        // ERRVALID-17. Switching outcome hides the field the message was pointing at, and a complaint
        // with nothing to point at reads as a bug in the sheet.
        outcomeSegment("Time out").click()
        XCTAssertTrue(
            stepSheet.validationMessage.waitForNonExistence(timeout: 5),
            "Switching the outcome should take the complaint with it"
        )

        // ERRVALID-16.
        XCTAssertTrue(stepSheet.holdField.waitForExistence(timeout: 5), "Time out should offer a hold field")
        replaceText(in: stepSheet.holdField, with: "-5")
        stepSheet.saveButton.click()
        XCTAssertTrue(
            waitForText(stepSheet.validationMessage, containing: "Hold duration must be zero or greater"),
            "A negative hold should be refused — read: "
                + combinedText(of: stepSheet.validationMessage)
        )

        stepSheet.cancelButton.click()
    }

    // MARK: - ERRDEAD — the reachable dead ends

    /// ERRDEAD-04 / -05 / -08 / -11 — four states that say "there is nothing here yet" rather than
    /// leaving a panel blank.
    ///
    /// ERRDEAD-04 is covered in the form the app can actually produce: the Journeys tab with nothing
    /// selected. The journey navigator selects whatever it creates and offers no way to deselect, so
    /// "journeys present *and* none selected" is not a state a user can reach — see the report.
    @MainActor
    func testReachableEmptyStates() throws {
        launchApp()
        createProjectViaUI(name: "Empty States")

        // ERRDEAD-04.
        journeysTab.click()
        XCTAssertTrue(
            waitForEmptyState(identifier: "center.noJourneySelection", heading: "No journey selected"),
            "The centre pane should explain that no journey is selected"
        )

        // ERRDEAD-05.
        let journeys = JourneysNavigatorPage(app: app)
        let newJourneySheet = NewJourneySheetPage(app: app)
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()
        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5))
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText("Fresh")
        newJourneySheet.createButton.click()
        XCTAssertTrue(
            waitForEmptyState(identifier: "journeyEditor.steps", heading: "No steps yet", timeout: 15),
            "A journey with no steps should say so and offer to add one"
        )

        // ERRDEAD-11.
        endpointsTab.click()
        createEndpointViaUI(name: "Users", path: "/api/users")
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    app.staticTexts["endpointEditor.headers.empty"],
                    app.staticTexts["No custom headers"].firstMatch,
                ],
                timeout: 10
            ),
            "An endpoint with no response headers should say so"
        )

        // ERRDEAD-08. The inspector's tab strip flattens its children's identifiers, so the tab is
        // targeted by the label `DSTabStrip` speaks — which is `EndpointTab.traffic.help`.
        app.buttons["Show the requests this endpoint answered"].firstMatch.click()
        XCTAssertTrue(
            waitForEmptyState(identifier: "endpointTraffic.empty", heading: "No traffic yet"),
            "An endpoint nothing has called should say so in the Traffic tab"
        )
    }

    /// ERRDEAD-07 — the log's other empty state, the one that means "your filter matched nothing"
    /// rather than "nothing has arrived".
    ///
    /// Traffic is driven from the runner rather than seeded, for the reason the base class's
    /// `sendRequest` records: what the log shows has to be what the engine actually recorded.
    @MainActor
    func testRequestLogReportsAFilterThatMatchesNothing() async throws {
        // Below the ephemeral range, for the reason ``holdPort(from:keepingSuccessorFree:)`` records:
        // this one is bound by the *app*, but a port the kernel may already have handed to an
        // outbound socket is no better a choice there.
        let port = 21314

        launchApp()
        createProjectViaUI(name: "Log Filter", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port, timeout: 20),
            "The server should report its base URL once running"
        )

        await sendRequest(port: port, path: "/api/users")
        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForExistence(timeout: 15),
            "The request should reach the log"
        )

        XCTAssertTrue(
            UITestApp.waitForAny(filterFieldHandles, timeout: 5),
            "A non-empty log should offer a filter"
        )
        let filter = try XCTUnwrap(
            filterFieldHandles.first(where: { $0.exists }),
            "A non-empty log should offer a filter"
        )
        filter.click()
        filter.typeText("no-such-route")

        XCTAssertTrue(
            waitForEmptyState(identifier: "drawer.noMatches", heading: "No matching requests"),
            "A filter that matches nothing should say so, not show an empty table"
        )

        workspace.serverToggleButton.click()
    }

    // MARK: - Alert elements

    /// Everything the alert on screen is saying, as one string.
    ///
    /// This file used to address the four alert bodies by identifier alone —
    /// `storeFailure.message`, `commandError.message`, `portConflict.message`,
    /// `serverError.message` — on the grounds that the words are interpolated or come from a
    /// validator and so cannot be matched on. The grounds are sound and the conclusion was wrong:
    /// **none of those identifiers is known to reach the tree.** A SwiftUI `.alert` realizes as an
    /// AppKit alert whose body is a `StaticText` the framework builds, and `WelcomeProjectUITests`
    /// already hedges its one alert-message query with "SwiftUI may still flatten it into an
    /// `NSAlert`'s informative text and drop the identifier on the way". No test in this repository
    /// has ever proved one of them lands, and four of the failures in this suite's first CI run are
    /// consistent with none of them doing so.
    ///
    /// So the identifier is tried *and* the alert container is read, together — the sheet or dialog
    /// AppKit realized the alert as, its own label, and every static text inside it. That subtree is
    /// half a dozen elements, so reading all of it costs nothing like a `CONTAINS` predicate over
    /// the window; and a caller asking "does the alert say X" gets an answer that does not depend on
    /// which of the two handles SwiftUI happened to leave behind.
    @MainActor
    private func alertText(messageIdentifier: String) -> String {
        var parts: [String] = []

        let named = element(identifier: messageIdentifier)
        if named.exists {
            parts.append(named.label)
            if let value = named.value { parts.append(String(describing: value)) }
        }

        for container in [app.sheets.firstMatch, app.dialogs.firstMatch] where container.exists {
            parts.append(container.label)
            for text in container.staticTexts.allElementsBoundByIndex {
                parts.append(text.label)
                if let value = text.value { parts.append(String(describing: value)) }
            }
        }

        return parts.joined(separator: " | ")
    }

    /// What the alert says beyond its own title.
    ///
    /// For the one alert whose body has no literal to match on: `genericStartError` is whatever the
    /// runtime threw, and the failure worth catching is an alert that renders a title over nothing.
    @MainActor
    private func alertBody(messageIdentifier: String, title: String) -> String {
        alertText(messageIdentifier: messageIdentifier)
            .replacingOccurrences(of: title, with: "")
            .replacingOccurrences(of: "|", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Polls until the alert on screen says `fragment`.
    @MainActor
    @discardableResult
    private func waitForAlert(
        messageIdentifier: String,
        saying fragment: String,
        timeout: TimeInterval = 20
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            self.alertText(messageIdentifier: messageIdentifier)
                .localizedCaseInsensitiveContains(fragment)
        }
    }

    /// Polls until nothing on screen is saying `fragment` any more.
    @MainActor
    @discardableResult
    private func waitForAlertToClear(
        messageIdentifier: String,
        saying fragment: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            !self.alertText(messageIdentifier: messageIdentifier)
                .localizedCaseInsensitiveContains(fragment)
        }
    }

    /// Launches with an unopenable store and keeps activating until the alert is on screen.
    ///
    /// The welcome-window assertion cannot be the readiness condition here — the alert comes up over
    /// it — but the activation *retry* around that assertion must not go with it: rule 6 of the UI
    /// Definition of Done is that a launch without the retry can leave a window the accessibility
    /// layer never sees, and a window nothing can see has no alert in it either. So this passes the
    /// alert itself as the condition to `launchApp(waitingFor:)`, which is `UITestApp
    /// .launchAndBringToForeground` with its five attempts intact.
    @MainActor
    @discardableResult
    private func launchUntilStoreFailureAlert() -> Bool {
        launchApp(waitingFor: { self.storeFailureAlertIsUp() })
    }

    @MainActor
    private func storeFailureAlertIsUp() -> Bool {
        alertText(messageIdentifier: "storeFailure.message")
            .localizedCaseInsensitiveContains("will not be saved")
    }

    /// An alert's button, by identifier where it lands and by its visible words where it does not.
    ///
    /// Both are tried for the reason `EndpointEditorPage.moreMenu` gives: which of the two reaches
    /// the tree is a SwiftUI realization detail that has changed before. The label fallback is safe
    /// here only because exactly one alert is up at each call site — `commandError.okButton` and
    /// `serverError.okButton` are both spelled "OK", which is why `WorkspaceView` gave them separate
    /// identifiers in the first place.
    @MainActor
    private func alertButton(identifier: String, label: String) -> XCUIElement {
        let byIdentifier = app.buttons[identifier]
        if byIdentifier.exists { return byIdentifier }
        return app.buttons[label].firstMatch
    }

    // MARK: - Workspace elements

    @MainActor private var serverURLWell: XCUIElement { element(identifier: "serverStatusWell.url") }
    @MainActor private var statusCodeNote: XCUIElement { element(identifier: "endpointEditor.statusCode.error") }
    @MainActor private var delayNote: XCUIElement { element(identifier: "endpointEditor.delay.error") }

    /// What `DSJSONEditor`'s warning row says — **the whole row, not one element of it**.
    ///
    /// The row is an `HStack` of an `exclamationmark.triangle.fill` and a `Text`, with the identifier
    /// on the stack and no `.accessibilityElement(children:)`, so `ds.jsoneditor.editor.body.error`
    /// lands on *both* children. A type-agnostic `firstMatch` over it therefore resolves to the icon,
    /// whose label is the single word "Warning" — `EndpointEditorUITests` failed its own version of
    /// this assertion reading exactly `Warning|`, which is that icon and nothing else.
    ///
    /// Scoping to `staticTexts` was the previous correction and it was a guess about a realization:
    /// it read empty here, which says the sentence is not in `app.staticTexts` under either handle.
    /// So this stops guessing which element carries the sentence and enumerates every element that
    /// carries the identifier, reading label and value from each. Whatever type SwiftUI gives the
    /// `Text`, it is in that list, and the icon merely adds "Warning" to the front of the string.
    ///
    /// The distinct return for an absent row matters as much as the text: "the warning row is not on
    /// screen" and "the warning row is on screen and says nothing" are different failures — the first
    /// is the typing never reaching the editor, the second is the row's own accessibility — and a
    /// bare empty string reported both as the second. Guarded on `firstMatch.exists` because `count`
    /// on a query with no matches raises rather than answering zero.
    ///
    /// The words are still polled as a second handle, in case the identifier does not propagate at
    /// all. `staticTexts` is the cheap typed query, unlike a `CONTAINS` over every descendant.
    @MainActor
    private func jsonWarningText() -> String {
        let byWords = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", "valid JSON", "valid JSON"
        )
        let sentences = app.staticTexts.matching(byWords).allElementsBoundByIndex
            .map { combinedText(of: $0) }

        let carriers = app.descendants(matching: .any)
            .matching(identifier: "ds.jsoneditor.editor.body.error")
        guard carriers.firstMatch.exists else {
            return (["<no warning row on screen>"] + sentences).joined(separator: " | ")
        }
        let row = (0..<carriers.count).map { combinedText(of: carriers.element(boundBy: $0)) }
        return (row + sentences).joined(separator: " | ")
    }

    /// The drawer's text filter, by identifier and by label together.
    ///
    /// `drawer.filterField` is a plain `TextField` in a `DSPanelHeader`'s trailing slot, and the
    /// header stamps `ds.panelheader.requestLog` over its leaves — so whether the identifier lands is
    /// a SwiftUI detail, and the label is what survives either way. `RequestLogUITests.filterField`
    /// resolves the same control the same way, and its filter test got past this point in the run
    /// that failed here.
    @MainActor private var filterFieldHandles: [XCUIElement] {
        [
            app.descendants(matching: .textField)
                .matching(identifier: "drawer.filterField").firstMatch,
            app.textFields["Filter request log"].firstMatch,
        ]
    }

    /// The `.failed` arm of the autosave indicator. There is no `autosaveStatusIndicator` to query —
    /// the toolbar slot is deliberately unnamed, and the three state-specific identifiers are the
    /// addressable surface.
    @MainActor private var autosaveFailedIndicator: XCUIElement {
        element(identifier: "autosaveStatus.failed")
    }

    /// The navigator's tabs, by the label `DSTabStrip` speaks — their own identifiers do not survive
    /// the strip, which stamps `ds.tabstrip.navigator` over every descendant.
    @MainActor private var journeysTab: XCUIElement { app.buttons["Show journeys"].firstMatch }
    @MainActor private var endpointsTab: XCUIElement { app.buttons["Show endpoints"].firstMatch }

    /// The editor's "Add" action for response headers. Inside a `DSSectionHeader`, which is paired
    /// with `.contain` — so the identifier may or may not land, and the label is the fallback the
    /// skill's rule prescribes for a leaf control in a named container.
    @MainActor private var addHeaderButton: XCUIElement {
        let byIdentifier = app.buttons["endpointEditor.addHeaderButton"]
        if byIdentifier.exists { return byIdentifier }
        return app.buttons["Add header"].firstMatch
    }

    /// The response body's **text view**, not the scroll view wearing the identifier.
    ///
    /// `DSJSONEditor` puts `ds.jsoneditor.editor.body` on a `CodeEditor`, which is an
    /// `NSViewRepresentable` wrapping a scroll view around an `NSTextView`, so the name lands on the
    /// wrapper and the typed content is one level down. Clicking the wrapper is what this file did
    /// for a round: it reported success and the keystrokes went nowhere, because the caret was never
    /// in a text view. `EndpointEditorUITests.bodyTextView()` resolves the same control the same way,
    /// and its JSON tests pass.
    @MainActor
    private func bodyTextView() -> XCUIElement {
        let container = element(identifier: "ds.jsoneditor.editor.body")
        if container.exists {
            let inner = container.descendants(matching: .textView).firstMatch
            if inner.exists { return inner }
            if container.elementType == .textView { return container }
        }
        return app.textViews.firstMatch
    }

    /// What the body editor holds. `NSTextView` publishes its string as the element's value.
    @MainActor
    private func bodyText() -> String { combinedText(of: bodyTextView()) }

    /// Gives the editor the request log's height back.
    ///
    /// The body editor is the last card in a scrolling form and the log occupies the bottom of the
    /// window, so on a hosted runner the card sits under the drawer — which is how CI came to report
    /// `Unable to find hit point for ScrollView, {{333.0, 467.0}, {320.0, 240.0}}, identifier:
    /// 'ds.jsoneditor.editor.body'`. One toolbar click is cheaper and steadier than scrolling, and
    /// `EndpointEditorUITests` and `JourneyEditorUITests` both open with it. Guarded on the drawer
    /// being up, so this cannot hide a log a later assertion needs and cannot toggle it back on.
    @MainActor
    private func hideRequestLogDrawer() {
        guard workspace.toggleDrawerButton.waitForExistence(timeout: 5) else { return }
        guard workspace.drawerEmptyHeading.exists else { return }
        workspace.toggleDrawerButton.click()
        _ = workspace.drawerEmptyHeading.waitForNonExistence(timeout: 3)
    }

    /// The editor form's scroller, for the case where hiding the drawer is not enough.
    @MainActor
    private var editorScrollView: XCUIElement {
        let editor = element(identifier: "endpointEditor")
        if editor.exists {
            let inner = editor.descendants(matching: .scrollView).firstMatch
            if inner.exists { return inner }
        }
        return app.scrollViews.firstMatch
    }

    /// Scrolls until `element` can actually be clicked. Both directions, because
    /// `scroll(byDeltaX:deltaY:)`'s sign convention is a wheel gesture's rather than a content
    /// offset's, and getting it backwards would silently scroll away from the target.
    @MainActor
    private func revealInEditor(_ element: XCUIElement) -> Bool {
        if element.isHittable { return true }
        let scroller = editorScrollView
        guard scroller.exists else { return element.isHittable }
        for delta in [-90.0, -90.0, -90.0, -90.0, 90.0, 90.0, 90.0, 90.0, 90.0, 90.0] {
            scroller.scroll(byDeltaX: 0, deltaY: CGFloat(delta))
            if element.isHittable { return true }
        }
        return element.isHittable
    }

    /// Puts `text` in the response body by **pasting** it, and answers whether it landed there.
    ///
    /// Pasted rather than typed, which is `EndpointEditorUITests.setResponseBody`'s rule and worth
    /// keeping even for a payload with no brackets in it: `CodeEditor` is a source editor and may
    /// complete a character as it arrives, and ⌘V inserts verbatim. It is a real user action, not a
    /// back door — the app keeps the standard Edit menu, so the key equivalent reaches the text
    /// view's `paste:` the way a person's would.
    ///
    /// The return value is the text having *arrived*, read back out of the editor. A click that
    /// lands on the wrapper, or on the drawer covering it, is then a failure that says the editor
    /// could not be reached rather than one that says the warning never appeared — which would be a
    /// true sentence about the wrong thing.
    @MainActor
    private func setResponseBody(_ text: String) -> Bool {
        let editor = bodyTextView()
        guard editor.waitForExistence(timeout: 10) else { return false }
        guard revealInEditor(editor) else { return false }
        guard clickIfHittable(editor) else { return false }

        editor.typeKey("a", modifierFlags: .command)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)

        return UITestApp.waitUntil(timeout: 5) { self.bodyText().contains(text) }
    }

    /// Clicks an element only when it is there to be clicked, so a probe cannot fail the test.
    @MainActor
    private func clickIfHittable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        element.click()
        return true
    }

    /// A segment of the step sheet's outcome picker. A `.segmented` picker realizes as a radio group
    /// on macOS, so the segments are radio buttons rather than buttons — `app.buttons[…]` would never
    /// match. Both are tried so a style change does not silently break the selection.
    @MainActor
    private func outcomeSegment(_ title: String) -> XCUIElement {
        let byRadio = app.radioButtons[title].firstMatch
        if byRadio.exists { return byRadio }
        let byButton = app.buttons[title].firstMatch
        if byButton.exists { return byButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", title))
            .firstMatch
    }

    // MARK: - Query helpers

    /// Matches an identifier across element types.
    ///
    /// Type-agnostic on purpose: a status-code note is an `.accessibilityElement()` over an icon and
    /// a sentence, an empty state is a container, and an overview row is a combined element — three
    /// different realizations of "the thing carrying this name". Identifier matching is also the
    /// cheap kind; a `CONTAINS` predicate over `descendants(matching: .any)` evaluates against every
    /// element in the window and has timed this suite out inside XCUITest's own query engine.
    ///
    /// It answers a question about a *name*, and a name is exactly what a flattening container takes
    /// away — so it is the wrong tool for anything inside one. `alertText(messageIdentifier:)` and
    /// `validationNotes(saying:)` exist because four alerts and two `DSTextField` notes are inside
    /// one; this is still right for the elements that carry their own identifier, and every remaining
    /// caller is one of those.
    @MainActor
    private func element(identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Everything an element says, as one string, so a caller can assert on *which* message is up.
    ///
    /// Label and value both, because which of the two carries the text depends on how SwiftUI
    /// realized the element — `DSEmptyState`'s heading arrives as the value, a validation note's as
    /// the label. Empty when the element is absent, so a poll cannot mistake "gone" for "unchanged".
    @MainActor
    private func combinedText(of element: XCUIElement) -> String {
        guard element.exists else { return "" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "\(element.label) \(value)"
    }

    /// Polls until an element's text contains `fragment`.
    ///
    /// Needed because several of these surfaces reuse one element for several messages — the status
    /// code note says one thing for 600 and another for a blank field, and the step sheet refuses
    /// through a single view for six different rules. Asserting existence alone would pass on the
    /// previous complaint.
    @MainActor
    @discardableResult
    private func waitForText(
        _ element: XCUIElement,
        containing fragment: String,
        timeout: TimeInterval = 5
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            self.combinedText(of: element).localizedCaseInsensitiveContains(fragment)
        }
    }

    /// Polls an element's enabled state.
    ///
    /// A `.disabled(…)` binding is re-evaluated on the next SwiftUI update, so reading `isEnabled`
    /// immediately after a keystroke reads the state from before it.
    @MainActor
    private func waitForEnabled(
        _ element: XCUIElement,
        isEnabled: Bool,
        timeout: TimeInterval = 5
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) { element.isEnabled == isEnabled }
    }

    /// Whether the status well reports a running base URL within `timeout`.
    ///
    /// Asserted in the negative by the two tests that must prove a *refused* start did not quietly
    /// happen anyway: the well always exists — it reads "Server error" or "Server stopped" — so its
    /// presence says nothing, and only `localhost:` means something bound.
    @MainActor
    private func waitForServerToReportAURL(timeout: TimeInterval) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            self.combinedText(of: self.serverURLWell).contains("localhost:")
        }
    }

    /// A `DSTextField`'s inline validation note, matched by the words it shows.
    ///
    /// **Not by `ds.textfield.<id>.error`.** `DSTextField` builds that name and hangs it on the note,
    /// but every caller stamps its own identifier on the whole field — `NewProjectSheet` tags it
    /// `serverPortField`, which is what makes `app.textFields["serverPortField"]` resolve, and
    /// `DSTextField`'s own comment records that pairing it with `.accessibilityElement(children:)`
    /// would break that lookup. A container's identifier overrides its descendants', so the note ends
    /// up reporting the wrapper's name and the built one exists nowhere. Three suites failed on it in
    /// the same CI run — here, `WelcomeProjectUITests` and `EndpointEditorUITests` — which is what
    /// one shared cause looks like.
    ///
    /// What the note keeps is its **label**: `validationRow` is an `.accessibilityElement()` with
    /// `.accessibilityLabel(message)`, and a flattened child keeps its own label and value even when
    /// it loses its identifier. Which element *type* that lands as is not something to guess at — an
    /// `.accessibilityElement()` over an icon and a sentence can realize as a static text, a group or
    /// a plain element — so the three are polled together rather than chained. Typed queries, not a
    /// predicate over `descendants(matching: .any)`, which scans the window and has timed this suite
    /// out inside the query engine.
    @MainActor
    private func validationNotes(saying fragment: String) -> [XCUIElement] {
        let predicate = NSPredicate(
            format: "label CONTAINS[c] %@ OR value CONTAINS[c] %@", fragment, fragment
        )
        return [
            app.staticTexts.matching(predicate).firstMatch,
            app.groups.matching(predicate).firstMatch,
            app.otherElements.matching(predicate).firstMatch,
        ]
    }

    /// Polls until no validation note is saying `fragment` — the negative of ``validationNotes(saying:)``.
    @MainActor
    private func waitForNoValidationNote(saying fragment: String, timeout: TimeInterval = 5) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            self.validationNotes(saying: fragment).allSatisfy { !$0.exists }
        }
    }

    /// Waits for a `DSEmptyState`, polling every form it can arrive in.
    ///
    /// The component pairs its container identifier with `.contain`, and that keeps a child as its
    /// own element with its own label and value — *not* with its own identifier. Dumped from
    /// `app.debugDescription`, the heading reads
    /// `StaticText, identifier: 'ds.empty.sidebar.endpoints', value: No endpoints`: the container's
    /// name, the heading's words. So the container name, the heading's own name and the literal text
    /// are all polled together rather than chained, which is the `a || b` trap the UI Definition of
    /// Done forbids.
    @MainActor
    private func waitForEmptyState(
        identifier: String,
        heading: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        UITestApp.waitForAny(
            [
                element(identifier: "ds.empty.\(identifier)"),
                element(identifier: "ds.empty.\(identifier).heading"),
                app.staticTexts[heading].firstMatch,
            ],
            timeout: timeout
        )
    }

    /// Replaces a field's contents. Select-all then type, or select-all then delete when clearing —
    /// `typeText("")` types nothing and would leave the old value in place.
    @MainActor
    private func replaceText(in field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5), "Field should exist before it is typed into")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        if text.isEmpty {
            field.typeKey(.delete, modifierFlags: [])
        } else {
            field.typeText(text)
        }
    }

    // MARK: - Holding a port in the runner

    /// Candidates for the conflict the app is meant to hit, and for the "keep stopped" variant.
    ///
    /// **Both lists sit below 49152, and that is the fix for the first CI run.** This suite asked for
    /// 62311, 62313 and 65535 and could hold none of them; `WorkspaceShellUITests` asked for 62116,
    /// through an entirely different mechanism — an `NWListener` rather than a raw socket — and could
    /// not hold that either. Two unrelated implementations failing the same way is evidence about the
    /// ports, not about either implementation. All four sit inside macOS's ephemeral range
    /// (`net.inet.ip.portrange` — 49152 through 65535), which is where the kernel draws source ports
    /// for *outbound* sockets; this process opens plenty of loopback connections of its own, and a
    /// listener bind of a port an ephemeral socket already holds is refused with `EADDRINUSE` that no
    /// amount of `SO_REUSEADDR` would talk it out of — and `SO_REUSEADDR` is deliberately not set
    /// here, for the reason ``bindListener(on:)`` gives. Ports below 49152 are never handed out that
    /// way.
    ///
    /// That is the best explanation the evidence supports and it is not proof: nothing in the run
    /// recorded the `errno`. It does now — ``portHoldDiagnosis`` carries it — so if the next run
    /// fails here it will say whether the kernel is reporting a busy port or refusing to let this
    /// process listen at all, which are two different bugs with two different fixes.
    ///
    /// Several candidates rather than one so that a machine which genuinely has the first busy moves
    /// on rather than failing a test about alerts.
    private static let conflictPorts = [21311, 21411, 21511, 21611]
    private static let keepStoppedPorts = [21313, 21413, 21513, 21613]

    /// Binds and listens on `127.0.0.1` at the first candidate the kernel allows, and answers which.
    ///
    /// `keepingSuccessorFree` is for the test that accepts the alert's offer: the alert proposes
    /// `port + 1` and the app then has to be able to bind it, so the successor is probed and released
    /// before the candidate is accepted. A candidate whose successor is busy is skipped rather than
    /// held, because holding it would make the *app's* retry fail and the test would report a missing
    /// server URL instead of a busy machine.
    ///
    /// Returns `nil` when no candidate could be held; ``portHoldDiagnosis`` then names each candidate
    /// with the syscall and `errno` that refused it.
    private func holdPort(from candidates: [Int], keepingSuccessorFree: Bool = false) -> Int? {
        releaseHeldPort()
        var reasons: [String] = []

        for candidate in candidates {
            guard candidate > 0, candidate <= 65535 else {
                reasons.append("\(candidate): not a TCP port")
                continue
            }
            guard !(keepingSuccessorFree && candidate == 65535) else {
                reasons.append("\(candidate): there is no port above it for the alert to offer")
                continue
            }

            switch bindListener(on: UInt16(candidate)) {
            case let .failure(reason):
                reasons.append("\(candidate): \(reason)")
            case let .success(descriptor):
                if keepingSuccessorFree {
                    switch bindListener(on: UInt16(candidate + 1)) {
                    case let .success(probe):
                        Darwin.close(probe)
                    case let .failure(reason):
                        Darwin.close(descriptor)
                        reasons.append("\(candidate + 1) (the port the alert will offer): \(reason)")
                        continue
                    }
                }
                heldSocket = descriptor
                portHoldDiagnosis = ""
                return candidate
            }
        }

        portHoldDiagnosis = reasons.joined(separator: "; ")
        return nil
    }

    private enum BindOutcome {
        case success(Int32)
        case failure(String)
    }

    /// One `socket`/`bind`/`listen`, with the reason it stopped where it stopped.
    ///
    /// **No `SO_REUSEADDR`, deliberately.** The engine binds exactly `127.0.0.1`, and BSD refuses a
    /// second listener on an identical address whatever the option says — but a *wildcard* listener
    /// with `SO_REUSEADDR` on both sides is the pair BSD permits, which would silently let the start
    /// succeed and turn every assertion in the port tests into a timeout with a misleading message.
    ///
    /// A raw socket rather than `Network`'s `NWListener`, which is what `WorkspaceShellUITests` uses:
    /// there is no queue, no state handler and no semaphore here, so "the listener never became
    /// ready" is not a failure this can have. Either the three calls return or they say why.
    private func bindListener(on port: UInt16) -> BindOutcome {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return .failure("socket() refused — \(errnoText())") }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        // `in_addr_t` from `inet_addr` is already in network byte order; the port is not.
        address.sin_port = port.bigEndian
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))

        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.bind(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let reason = "bind() refused — \(errnoText())"
            Darwin.close(descriptor)
            return .failure(reason)
        }
        guard Darwin.listen(descriptor, 1) == 0 else {
            let reason = "listen() refused — \(errnoText())"
            Darwin.close(descriptor)
            return .failure(reason)
        }
        return .success(descriptor)
    }

    /// The last error the kernel set, by number and by name.
    ///
    /// Read immediately after the failing call and never across another one — `errno` is clobbered by
    /// the next syscall, `Darwin.close` included, which is why every caller above builds this string
    /// before it closes anything.
    private func errnoText() -> String {
        let code = errno
        guard let reason = strerror(code) else { return "errno \(code)" }
        return "errno \(code) (\(String(cString: reason)))"
    }

    /// Closes the held listener. Called from `tearDownWithError` as well as from
    /// ``holdPort(from:keepingSuccessorFree:)``: a descriptor leaked out of one test would make every
    /// later test that binds a port fail for a reason nothing in that test explains.
    private func releaseHeldPort() {
        guard heldSocket >= 0 else { return }
        Darwin.close(heldSocket)
        heldSocket = -1
    }
}
