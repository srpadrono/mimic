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
/// *A port conflict is produced by the runner, not by a second Mimic.* ``holdPort(_:)`` binds
/// `127.0.0.1:<port>` in this process and does **not** set `SO_REUSEADDR`, which matters: the engine
/// binds exactly `127.0.0.1` (`MockServerEngine.start`), so an exact-address duplicate is refused
/// with `EADDRINUSE` and `VaporConfigurator.mapStartError` turns that into
/// `MockServerError.portInUse`. A wildcard listener with `SO_REUSEADDR` on both sides is precisely
/// the pair BSD *allows* to coexist, which would make the conflict fail to happen. The descriptor is
/// closed in `tearDownWithError`, because a listener leaked out of one test breaks every later test
/// that tries to bind a port.
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
    /// Launched through ``MimicUITestCase/launchAppExpectingFailureAlert()`` rather than the usual
    /// path: the alert comes up *over* the welcome window, and asserting the window first would fail
    /// the test before it reached the thing it is testing.
    @MainActor
    func testStoreFailureAlertExplainsTheEphemeralSessionAndDismisses() throws {
        databasePathOverride = "/dev/null/mimic.sqlite"
        launchAppExpectingFailureAlert()

        // ERRSTORE-01 / ERRSTORE-02. The message is `ProjectStore.open`'s prose, so the identifier is
        // the only stable handle on it — the sentence is one somebody will reword.
        XCTAssertTrue(
            storeFailureMessage.waitForExistence(timeout: 20),
            "A store that cannot be opened should raise the \"Your work will not be saved\" alert"
        )
        XCTAssertTrue(
            waitForText(storeFailureMessage, containing: "in memory"),
            "The alert should say the session is running in memory — read: "
                + combinedText(of: storeFailureMessage)
        )

        // ERRSTORE-03.
        alertButton(identifier: "storeFailure.continueButton", label: "Continue anyway").click()
        XCTAssertTrue(
            storeFailureMessage.waitForNonExistence(timeout: 5),
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
        launchAppExpectingFailureAlert()
        XCTAssertTrue(
            storeFailureMessage.waitForExistence(timeout: 20),
            "The unopenable store should raise the alert on the first launch"
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
            storeFailureMessage.waitForExistence(timeout: 3),
            "A store that opens normally must not report a failure"
        )
    }

    // MARK: - ERRCMD — an edit the command executor refuses

    /// ERRCMD-01 / -02 / -03 — a header name the RFC 9110 token grammar refuses.
    ///
    /// **A lone space does not reach the executor**, which is worth stating because it looks like the
    /// obvious trigger: `EndpointEditorView.headersDictionary(from:)` trims each name and drops the
    /// ones that trim to nothing, so `" "` produces the same empty dictionary the scenario already
    /// holds, `headersAreDirty` answers `false`, and no command is ever issued. A name with an
    /// *interior* space survives the trim, is dirty, and is refused by `EndpointValidator` — which is
    /// the refusal this alert exists to report.
    @MainActor
    func testRefusedHeaderNameRaisesTheCommandErrorAlert() throws {
        launchApp()
        createProjectViaUI(name: "Header Refusal")
        createEndpointViaUI(name: "Users", path: "/api/users")

        addHeaderButton.click()
        let key = endpointEditor.headerKeyField(at: 0)
        XCTAssertTrue(key.waitForExistence(timeout: 5), "Adding a header should give the row a name field")
        key.click()
        key.typeText("X Bad")

        // The 300ms settle, then `applyScenarioSpec` → `validateHeaders` → `lastCommandError`.
        XCTAssertTrue(
            commandErrorMessage.waitForExistence(timeout: 10),
            "A header name that is not a token should raise \"Couldn't apply that change\""
        )
        XCTAssertTrue(
            waitForText(commandErrorMessage, containing: "header name"),
            "The alert should name the refusal — read: " + combinedText(of: commandErrorMessage)
        )

        alertButton(identifier: "commandError.okButton", label: "OK").click()
        XCTAssertTrue(
            commandErrorMessage.waitForNonExistence(timeout: 5),
            "OK should clear the refusal"
        )
        // The refused text stays in the field: the change was not made, and the editor does not
        // silently rewrite what you typed. Asserted as a prefix rather than as the whole string
        // because the alert can rise on a prefix of what is being typed — "X B" is already not a
        // token — and the keystrokes after it then land on the alert. Either way the field must
        // still hold the name the executor refused; an editor that reverted to the model would show
        // an empty field here.
        let shownName = (key.value as? String) ?? ""
        XCTAssertTrue(
            shownName.hasPrefix("X "),
            "The editor should still show the text the executor refused — read: \(shownName)"
        )
    }

    /// ERRCMD-05 (with ERRPORT-01 / -02 on the way in) — accepting the next port after a conflict on
    /// 65535 reports the refusal instead of quietly doing nothing.
    ///
    /// `AppState.retryStartOnNextPort` runs `.serverConfigure(port: 65536)` *before* it starts, and
    /// bails when the command declines — so the only evidence the user gets is this alert.
    @MainActor
    func testAcceptingTheNextPortAbove65535ReportsTheRefusal() throws {
        let port = 65535
        XCTAssertTrue(holdPort(UInt16(port)), "The runner should be able to hold port \(port)")

        launchApp()
        createProjectViaUI(name: "Last Port", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            portConflictMessage.waitForExistence(timeout: 20),
            "Starting on a port the runner holds should report the conflict"
        )
        alertButton(
            identifier: "portConflict.tryPortButton",
            label: "Try port \(port + 1)"
        ).click()

        XCTAssertTrue(
            commandErrorMessage.waitForExistence(timeout: 10),
            "Port 65536 is out of range, and the refusal must be reported rather than swallowed"
        )
        XCTAssertTrue(
            waitForText(commandErrorMessage, containing: "65536"),
            "The refusal should name the port it rejected — read: "
                + combinedText(of: commandErrorMessage)
        )

        alertButton(identifier: "commandError.okButton", label: "OK").click()
        XCTAssertTrue(commandErrorMessage.waitForNonExistence(timeout: 5), "OK should clear the refusal")
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
        let port = 62311
        XCTAssertTrue(holdPort(UInt16(port)), "The runner should be able to hold port \(port)")

        launchApp()
        createProjectViaUI(name: "Port Conflict", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            portConflictMessage.waitForExistence(timeout: 20),
            "A port another process holds should raise the conflict alert"
        )
        XCTAssertTrue(
            waitForText(portConflictMessage, containing: "\(port)"),
            "The alert should name the port in conflict — read: " + combinedText(of: portConflictMessage)
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
        let port = 62313
        XCTAssertTrue(holdPort(UInt16(port)), "The runner should be able to hold port \(port)")

        launchApp()
        createProjectViaUI(name: "Keep Stopped", port: port)
        workspace.serverToggleButton.click()

        XCTAssertTrue(
            portConflictMessage.waitForExistence(timeout: 20),
            "A port another process holds should raise the conflict alert"
        )
        alertButton(identifier: "portConflict.keepStoppedButton", label: "Keep server stopped").click()

        XCTAssertTrue(
            portConflictMessage.waitForNonExistence(timeout: 5),
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
            serverErrorMessage.waitForExistence(timeout: 20),
            "A bind the OS refuses should raise the generic \"Server error\" alert"
        )
        // The message is whatever the runtime threw, so there is no literal to match on — only that
        // the alert carries the engine's sentence rather than an empty body.
        XCTAssertFalse(
            combinedText(of: serverErrorMessage).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "The alert should carry the engine's own diagnosis"
        )

        alertButton(identifier: "serverError.okButton", label: "OK").click()
        XCTAssertTrue(
            serverErrorMessage.waitForNonExistence(timeout: 5),
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

        XCTAssertTrue(
            newProjectSheet.portValidationError.waitForExistence(timeout: 5),
            "A port above 65535 should be explained under the field"
        )
        XCTAssertTrue(
            waitForText(newProjectSheet.portValidationError, containing: "65535"),
            "The note should state the rule — read: "
                + combinedText(of: newProjectSheet.portValidationError)
        )
        XCTAssertFalse(
            newProjectSheet.createButton.isEnabled,
            "Create project should be disabled while the port is out of range"
        )

        // ERRVALID-03: an unfinished form is not a mistake. `portValidationMessage` is deliberately
        // silent on an empty field, and the button stays disabled without a complaint.
        replaceText(in: newProjectSheet.portField, with: "")
        XCTAssertTrue(
            newProjectSheet.portValidationError.waitForNonExistence(timeout: 5),
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

        XCTAssertTrue(
            newEndpointSheet.pathError.waitForExistence(timeout: 5),
            "A path without a leading slash should be explained under the field"
        )
        XCTAssertTrue(
            waitForText(newEndpointSheet.pathError, containing: "must start"),
            "The note should state the rule — read: " + combinedText(of: newEndpointSheet.pathError)
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

        let editor = jsonBodyEditor
        XCTAssertTrue(editor.waitForExistence(timeout: 10), "The response body editor should be present")
        editor.click()
        // Letters only, deliberately: the code editor matches brackets and quotes, and a trigger that
        // depends on whether it auto-closes one is a trigger that will break on a dependency bump.
        app.typeText("not json")

        XCTAssertTrue(
            jsonValidationWarning.waitForExistence(timeout: 10),
            "A malformed body should raise the \"Not valid JSON\" warning"
        )
        XCTAssertTrue(
            waitForText(jsonValidationWarning, containing: "still saved"),
            "The warning must say the body is kept, not rejected — read: "
                + combinedText(of: jsonValidationWarning)
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
        let port = 62314

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

        let filter = requestLogDrawer.filterField
        XCTAssertTrue(filter.waitForExistence(timeout: 5), "A non-empty log should offer a filter")
        filter.click()
        filter.typeText("no-such-route")

        XCTAssertTrue(
            waitForEmptyState(identifier: "drawer.noMatches", heading: "No matching requests"),
            "A filter that matches nothing should say so, not show an empty table"
        )

        workspace.serverToggleButton.click()
    }

    // MARK: - Alert elements

    /// Alert bodies are matched by identifier and never by their words: two of the four interpolate a
    /// port or carry a validator's sentence, so the only content-based query that could reach them is
    /// a `CONTAINS` predicate over the window's static texts — expensive, and satisfied by anything
    /// else on screen that happens to mention the same thing.
    @MainActor private var storeFailureMessage: XCUIElement { element(identifier: "storeFailure.message") }
    @MainActor private var commandErrorMessage: XCUIElement { element(identifier: "commandError.message") }
    @MainActor private var portConflictMessage: XCUIElement { element(identifier: "portConflict.message") }
    @MainActor private var serverErrorMessage: XCUIElement { element(identifier: "serverError.message") }

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
    @MainActor private var jsonValidationWarning: XCUIElement {
        element(identifier: "ds.jsoneditor.editor.body.error")
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

    /// The response-body code editor. `CodeEditor` is an `NSViewRepresentable`, so whether the
    /// wrapper's identifier reaches the tree depends on how AppKit realizes it; the text view is the
    /// fallback, and the editor is the only one in this window.
    @MainActor private var jsonBodyEditor: XCUIElement {
        let byIdentifier = element(identifier: "ds.jsoneditor.editor.body")
        if byIdentifier.exists { return byIdentifier }
        return app.textViews.firstMatch
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
    /// Type-agnostic on purpose: a validation note is an `.accessibilityElement()` over an icon and a
    /// sentence, an alert message is a `Text`, and an overview row is a combined element — three
    /// different realizations of "the thing carrying this name". Identifier matching is also the
    /// cheap kind; a `CONTAINS` predicate over `descendants(matching: .any)` evaluates against every
    /// element in the window and has timed this suite out inside XCUITest's own query engine.
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

    /// Binds and listens on `127.0.0.1:port` in this process, so the app's bind of the same address
    /// fails with `EADDRINUSE`.
    ///
    /// **No `SO_REUSEADDR`, deliberately.** The engine binds exactly `127.0.0.1`, and BSD refuses a
    /// second listener on an identical address whatever the option says — but a *wildcard* listener
    /// with `SO_REUSEADDR` on both sides is the pair BSD permits, which would silently let the start
    /// succeed and turn every assertion below into a timeout with a misleading message.
    ///
    /// Answers whether the port was taken, so a test fails saying "the runner could not hold the
    /// port" rather than "no conflict alert appeared".
    private func holdPort(_ port: UInt16) -> Bool {
        releaseHeldPort()

        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }

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
        guard bound == 0, Darwin.listen(descriptor, 1) == 0 else {
            Darwin.close(descriptor)
            return false
        }

        heldSocket = descriptor
        return true
    }

    /// Closes the held listener. Called from `tearDownWithError` as well as from ``holdPort(_:)``: a
    /// descriptor leaked out of one test would make every later test that binds a port fail for a
    /// reason nothing in that test explains.
    private func releaseHeldPort() {
        guard heldSocket >= 0 else { return }
        Darwin.close(heldSocket)
        heldSocket = -1
    }
}
