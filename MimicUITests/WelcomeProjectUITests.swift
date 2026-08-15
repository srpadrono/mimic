import AppKit
import Foundation
import XCTest

/// The welcome window and the project lifecycle around it: what the first screen says, how the
/// recents list behaves under the keyboard, and what duplicating, deleting and creating a project
/// actually do to the list.
///
/// This suite is deliberately separate from `MimicUITests`. It inherits ``MimicUITestCase`` for the
/// launch contract and the state builders, and it *reuses* that file's page objects rather than
/// growing a second set — `WelcomePage`, `NewProjectSheetPage`, `WorkspacePage` and
/// `DeleteConfirmationPage` are file-scope types in the same target, and a second copy of them would
/// be the same duplication that let the journeys suite ship without the activation retry.
///
/// Three things about the queries here are worth knowing before changing them.
///
/// **Which project is open is asserted by an endpoint path, not by a window title.** Every project
/// these tests create gets one endpoint with a unique path, and the sidebar draws that path as a
/// `Text` — `app.staticTexts["/older"]` is the same query `testSidebarSearchFiltersEndpoints` already
/// relies on. A window title would be cheaper and is what `WelcomePage` falls back to, but no test in
/// this repository has ever asserted on one alone, so it is not a query form to build a discrimination
/// on.
///
/// **The keyboard tests clamp rather than count.** `List` selection starts on the first row
/// (`WelcomeWindow.validSelection` via `onAppear`), and a click in the list's empty space may or may
/// not clear it — that is AppKit's business, not the window's. So no test here presses Down exactly
/// once and predicts a row: they press it more times than there are rows, which lands on the last row
/// from *any* starting point, and then step back up by one. The assertion is the same either way,
/// which is what makes it a test of the arrow keys rather than of a guess about focus semantics.
///
/// **They also assume a click in the list's empty area gives it keyboard focus.** `onKeyPress(.return)`
/// and the arrow keys both need it, and clicking a row is not an option — that opens the project. If
/// these tests ever fail together with "the recents list never took keyboard focus", that assumption
/// is what broke, and the fix is a production one: the list needs a focus surface a test can drive.
///
/// **A recents row is addressed by its label, never by `recentProject-<name>`.** The identifier is set
/// on the row and does not reach the tree: the `List` above it is tagged `welcome.recents.list`, and a
/// container's identifier is stamped over its descendants'. Pairing it with
/// `.accessibilityElement(children: .contain)` keeps each child as an element with its own *label and
/// value* — which is not the same as its own identifier, and is exactly the distinction the
/// `mimic-ui-tests` skill's `references/accessibility-tree.md` says has now cost this suite twice.
/// ``recentsRow(named:)`` is the query that works, and the journeys navigator — `journeys.list` over
/// rows tagged `journeys.row.<uuid>` — is the same shape, which is why
/// `JourneyNavigatorPage.journeyRow(named:)` has always matched by label too.
final class WelcomeProjectUITests: MimicUITestCase {

    // MARK: - Welcome window chrome

    /// WELC-02, WELC-03, WELC-04, WELC-05, WELC-08, and the empty half of WELC-06.
    @MainActor
    func testWelcomeWindowShowsHeroVersionAndEmptyRecentsGuidance() throws {
        launchApp()

        XCTAssertTrue(
            welcome.waitForHeroTitle(timeout: 5),
            "The hero title should be on the first screen"
        )

        XCTAssertTrue(
            app.windows["Mimic"].firstMatch.waitForExistence(timeout: 3),
            "With no project open the window should be titled Mimic"
        )

        // The one number on the first screen, and the first thing anyone quotes in a bug report. It
        // read "Version 1.0" while the bundle had moved on, so both halves are asserted: that the
        // line is there, and that it names something.
        let version = app.staticTexts["welcomeVersionLabel"]
        XCTAssertTrue(version.waitForExistence(timeout: 3), "The version line should be under the hero title")
        let versionText = shownText(of: version)
        XCTAssertTrue(
            versionText.hasPrefix("Version "),
            "The version line should read 'Version <x.y.z>', got '\(versionText)'"
        )
        XCTAssertTrue(
            versionText.count > "Version ".count,
            "The version line should name a version rather than the bare word, got '\(versionText)'"
        )

        // The recents pane wears a panel header even when it has nothing to list.
        XCTAssertTrue(
            staticTextExists(exactly: "Projects"),
            "The recents pane should carry the Projects panel header"
        )
        // `recentCountSubtitle` returns nil rather than "0" when the list is empty — an empty panel
        // does not need a number to say it is empty.
        XCTAssertFalse(
            staticTextExists(exactly: "0", timeout: 1),
            "An empty recents pane should show no count at all, not a zero"
        )

        let hint = app.staticTexts["noRecentProjectsHint"]
        XCTAssertTrue(hint.waitForExistence(timeout: 3), "The empty state should say how the list gets filled")
        XCTAssertTrue(
            shownText(of: hint).contains("Create one"),
            "The empty-state hint should tell the user to create a project, got '\(shownText(of: hint))'"
        )
    }

    /// WELC-06 — the count in the panel header's subtitle slot tracks the list.
    @MainActor
    func testRecentsPanelHeaderCountsTheProjects() throws {
        launchApp()

        createProjectViaUI(name: "Count One")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        XCTAssertTrue(
            staticTextExists(exactly: "1"),
            "The Projects header should report a count of 1 with one project stored"
        )

        createProjectViaUI(name: "Count Two")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        XCTAssertTrue(
            staticTextExists(exactly: "2"),
            "The Projects header count should follow the list to 2"
        )
    }

    /// WELC-10 — a row says when its project was last opened.
    @MainActor
    func testRecentProjectRowStatesWhenItWasLastOpened() throws {
        launchApp()

        createProjectViaUI(name: "Recency Row")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let row = recentsRow(named: "Recency Row")
        XCTAssertTrue(
            row.waitForExistence(timeout: 5),
            "The row should be addressable by the label it reads out, \"Recency Row, last opened …\""
        )

        // `.contain` keeps the name and the times inside the row as elements of their own, so both are
        // asserted through the row rather than app-wide. It is only the row's *identifier* that the
        // list's identifier overrides — see `recentsRow(named:)`.
        XCTAssertTrue(
            rowText(in: row, beginningWith: "Last opened").exists,
            "The row should state when the project was last opened"
        )
        XCTAssertTrue(
            rowText(in: row, exactly: "Recency Row").exists,
            "The row should name its project"
        )
    }

    // MARK: - Keyboard navigation of the recents list

    /// WELC-13, WELC-14 — Down moves the selection and Return opens what it lands on.
    @MainActor
    func testArrowKeysMoveTheRecentsSelectionAndReturnOpensIt() throws {
        launchApp()

        createProjectWithEndpoint(named: "Arrow Older", path: "/older")
        createProjectWithEndpoint(named: "Arrow Newer", path: "/newer")

        // Most recently opened first, so the selection starts on Arrow Newer.
        XCTAssertNotNil(welcome.findRecentProject(named: "Arrow Newer"))
        XCTAssertNotNil(welcome.findRecentProject(named: "Arrow Older"))

        focusRecentsList()
        // More presses than there are rows: the selection ends on the last row whether the click
        // above cleared it or left it on the first.
        press(.downArrow, times: 4)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            app.staticTexts["/older"].firstMatch.waitForExistence(timeout: 10),
            "Return should have opened Arrow Older — the row the arrow keys moved the selection to. "
                + "If nothing opened, the recents list never took keyboard focus."
        )
        XCTAssertFalse(
            app.staticTexts["/newer"].firstMatch.exists,
            "Return opened Arrow Newer, so the arrow keys did not move the selection"
        )
    }

    /// WELC-13 in the other direction — Up steps back off the last row onto the middle one.
    ///
    /// Three projects, because a two-row list cannot tell "Up moved one row" from "Up clamped to the
    /// top": the middle row is a result no wrong implementation reaches by accident.
    @MainActor
    func testUpArrowMovesTheRecentsSelectionBackTowardTheTop() throws {
        launchApp()

        createProjectWithEndpoint(named: "Keyboard Third", path: "/third")
        createProjectWithEndpoint(named: "Keyboard Second", path: "/second")
        createProjectWithEndpoint(named: "Keyboard First", path: "/first")

        XCTAssertNotNil(welcome.findRecentProject(named: "Keyboard First"))
        XCTAssertNotNil(welcome.findRecentProject(named: "Keyboard Second"))
        XCTAssertNotNil(welcome.findRecentProject(named: "Keyboard Third"))

        focusRecentsList()
        press(.downArrow, times: 5)
        press(.upArrow, times: 1)
        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            app.staticTexts["/second"].firstMatch.waitForExistence(timeout: 10),
            "Down to the last row then Up once should select the middle row, Keyboard Second"
        )
        XCTAssertFalse(
            app.staticTexts["/third"].firstMatch.exists,
            "Up did not move the selection off the last row"
        )
        XCTAssertFalse(
            app.staticTexts["/first"].firstMatch.exists,
            "The selection never left the first row, so neither arrow key moved it"
        )
    }

    /// WELC-15, PROJDEL-07, PROJDEL-08 — deleting the selected row repairs the selection instead of
    /// leaving it pointing at a project that no longer exists.
    ///
    /// The deleted row is the *last* one, and the fallback is asserted to be the *first*: that is
    /// `validSelection`'s rule (`entries.first`) rather than "the nearest surviving neighbour", and
    /// the two are only distinguishable this way round.
    @MainActor
    func testRecentsSelectionFallsBackAfterDeletingTheSelectedProject() throws {
        launchApp()

        createProjectWithEndpoint(named: "Fallback Older", path: "/older")
        createProjectWithEndpoint(named: "Fallback Newer", path: "/newer")

        focusRecentsList()
        press(.downArrow, times: 4)

        // The row the arrows landed on is the row being deleted, so the selection is unambiguous
        // whether or not a right-click also moves it.
        beginDeleting("Fallback Older")
        deleteConfirmation.deleteButton.click()

        // Through `recentsRow`, not `welcome.recentProjectRow`: that one queries
        // `recentProject-Fallback Older`, which is never in the tree at all, so waiting for it to
        // *not* exist returned true whether or not anything was deleted. A negative assertion on a
        // query that cannot match is green by construction and evidence about nothing.
        XCTAssertTrue(
            recentsRow(named: "Fallback Older").waitForNonExistence(timeout: 5),
            "The deleted project should leave the recents list"
        )
        XCTAssertFalse(
            staticTextExists(exactly: "Fallback Older", timeout: 1),
            "Nothing on the welcome window should still name the deleted project"
        )
        XCTAssertNotNil(
            welcome.findRecentProject(named: "Fallback Newer"),
            "Deleting one of several projects should leave the others listed"
        )

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            app.staticTexts["/newer"].firstMatch.waitForExistence(timeout: 10),
            "After the selected project was deleted the selection should fall back to the first "
                + "surviving row, so Return opens Fallback Newer rather than doing nothing"
        )
    }

    // MARK: - The recents context menu

    /// WELC-19 — Open on the context menu opens the project.
    ///
    /// The existing suite asserts the item exists and stops there, so until now nothing proved the
    /// menu's own route into a project works; every test opened by clicking the row.
    @MainActor
    func testOpenFromTheRecentsContextMenuOpensTheProject() throws {
        launchApp()

        createProjectWithEndpoint(named: "Menu Open", path: "/menuopen")

        guard let row = welcome.findRecentProject(named: "Menu Open") else {
            XCTFail("Menu Open should be listed in recents")
            return
        }
        row.rightClick()

        let openItem = app.menuItems["Open"]
        XCTAssertTrue(openItem.waitForExistence(timeout: 3), "The recents context menu should offer Open")
        openItem.click()

        XCTAssertTrue(workspace.assertVisible(), "Open should have opened the project")
        XCTAssertTrue(
            app.staticTexts["/menuopen"].firstMatch.waitForExistence(timeout: 10),
            "The workspace should be showing Menu Open, the project the menu belonged to"
        )
    }

    /// WELC-20 — Escape closes the context menu and does nothing else.
    @MainActor
    func testEscapeDismissesTheRecentsContextMenu() throws {
        launchApp()

        createProjectWithEndpoint(named: "Escape Menu", path: "/escapemenu")

        guard let row = welcome.findRecentProject(named: "Escape Menu") else {
            XCTFail("Escape Menu should be listed in recents")
            return
        }
        row.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 3), "The context menu should be open")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            duplicateItem.waitForNonExistence(timeout: 3),
            "Escape should dismiss the recents context menu"
        )
        XCTAssertTrue(
            welcome.newProjectButton.exists,
            "Dismissing the menu should leave the welcome window exactly as it was"
        )
        XCTAssertFalse(
            app.staticTexts["/escapemenu"].firstMatch.exists,
            "Escape should not have opened the project the menu belonged to"
        )
    }

    // MARK: - Deleting a project

    /// PROJDEL-03, PROJDEL-05 — the alert says which project and what deleting costs, and Keep
    /// project backs out of it.
    @MainActor
    func testDeleteConfirmationNamesTheProjectAndKeepProjectCancels() throws {
        launchApp()

        createProjectViaUI(name: "Doomed API")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        beginDeleting("Doomed API")

        // The alert's title is a `String` rather than a view, so it has no identifier to hang a query
        // on: it arrives either as a static text inside the sheet or as the sheet's own label,
        // depending on how AppKit realizes the alert. Both are accepted; what is asserted is that the
        // project is named somewhere in the confirmation, which is the point of the step.
        let alert = app.sheets.firstMatch
        XCTAssertTrue(alert.exists, "The delete confirmation should be a sheet")
        let titleInSheet = alert.staticTexts
            .matching(NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "Doomed API", "Doomed API"))
            .firstMatch
        XCTAssertTrue(
            titleInSheet.exists || alert.label.contains("Doomed API"),
            "The confirmation should name the project it is about to delete"
        )

        // The message *is* a view, and it carries `welcome.deleteAlert.message`. SwiftUI may still
        // flatten it into an `NSAlert`'s informative text and drop the identifier on the way, so the
        // sentence itself is the second candidate — polled together, never chained.
        let messageByIdentifier = app.descendants(matching: .any)
            .matching(identifier: "welcome.deleteAlert.message")
            .firstMatch
        let messageByText = app.staticTexts
            .matching(NSPredicate(
                format: "value CONTAINS %@ OR label CONTAINS %@",
                "cannot be undone",
                "cannot be undone"
            ))
            .firstMatch
        XCTAssertTrue(
            UITestApp.waitForAny([messageByIdentifier, messageByText], timeout: 3),
            "The confirmation should warn that deleting a project cannot be undone"
        )

        deleteConfirmation.keepButton.click()

        XCTAssertTrue(
            deleteConfirmation.deleteButton.waitForNonExistence(timeout: 3),
            "Keep project should dismiss the confirmation"
        )
        XCTAssertNotNil(
            welcome.findRecentProject(named: "Doomed API"),
            "Keep project should leave the project in the list"
        )
        XCTAssertFalse(
            welcome.waitForNoRecentProjectsLabel(timeout: 1),
            "The empty state must not appear — nothing was deleted"
        )
    }

    /// PROJDEL-06 — Escape backs out of the confirmation the same way Keep project does.
    @MainActor
    func testEscapeDismissesTheDeleteConfirmation() throws {
        launchApp()

        createProjectViaUI(name: "Escape Delete")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        beginDeleting("Escape Delete")

        app.typeKey(.escape, modifierFlags: [])

        XCTAssertTrue(
            deleteConfirmation.deleteButton.waitForNonExistence(timeout: 3),
            "Escape should dismiss the delete confirmation"
        )
        XCTAssertNotNil(
            welcome.findRecentProject(named: "Escape Delete"),
            "Escaping the confirmation should leave the project in the list"
        )
        XCTAssertFalse(
            welcome.waitForNoRecentProjectsLabel(timeout: 1),
            "The empty state must not appear — nothing was deleted"
        )
    }

    // MARK: - Duplicating a project

    /// PROJDUP-03 — the copy is a copy: opening it finds the original's endpoints.
    ///
    /// The existing duplicate test duplicates an *empty* project and never opens the result, so
    /// nothing yet proved a duplicate carries anything at all.
    @MainActor
    func testDuplicateCarriesTheEndpointsIntoTheCopy() throws {
        launchApp()

        createProjectWithEndpoint(named: "Origin", path: "/origin")

        guard let row = welcome.findRecentProject(named: "Origin") else {
            XCTFail("Origin should be listed in recents")
            return
        }
        row.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 3), "The context menu should offer Duplicate")
        duplicateItem.click()

        guard let copy = welcome.findRecentProject(named: "Origin (Copy)") else {
            XCTFail("The duplicate should appear in recents as 'Origin (Copy)'")
            return
        }
        copy.click()

        XCTAssertTrue(workspace.assertVisible(), "The copy should open")
        XCTAssertTrue(
            app.staticTexts["/origin"].firstMatch.waitForExistence(timeout: 10),
            "The copy should carry the original's endpoints"
        )
    }

    /// PROJDUP-04 — duplicating the same project twice leaves two copies, not one.
    ///
    /// `ProjectWorkspace.duplicateProject` names the copy `"\(source.name) (Copy)"` and nothing
    /// uniques it, so duplicating "Twin" twice leaves *two* rows both reading "Twin (Copy)" — the
    /// second is not "Twin (Copy) (Copy)" (that is what duplicating the copy would give) and not
    /// "Twin (Copy 2)". Both are listed because recents are keyed by project id, so the list has to be
    /// counted rather than searched. The header's count is asserted alongside it, because two rows
    /// carrying one name and a store holding two projects are different claims.
    @MainActor
    func testDuplicatingTwiceProducesTwoCopies() throws {
        launchApp()

        createProjectViaUI(name: "Twin")
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        duplicateProjectFromRecents(named: "Twin")
        XCTAssertTrue(
            recentsRow(named: "Twin (Copy)").waitForExistence(timeout: 5),
            "The first duplicate should appear in recents"
        )

        duplicateProjectFromRecents(named: "Twin")

        // Counted as the name `Text` inside each row rather than as the rows themselves. Neither
        // identifier form can do this job — `recentProject-Twin (Copy)` never reaches the tree — and
        // counting elements that match the row's *label* would be counting whatever wrapping a `List`
        // row arrives in as well as the row, which can repeat that label. A leaf static text is one
        // element per row, and the match is exact so "Twin" cannot answer for "Twin (Copy)".
        let copies = app.staticTexts.matching(
            NSPredicate(format: "value == %@ OR label == %@", "Twin (Copy)", "Twin (Copy)")
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { copies.count == 2 },
            "Duplicating twice should leave two copies in the list, found \(copies.count)"
        )
        XCTAssertTrue(
            staticTextExists(exactly: "3"),
            "The Projects header should count the original and both copies"
        )
    }

    // MARK: - Creating a project

    /// NEWPROJ-03, NEWPROJ-04, NEWPROJ-07 — the sheet opens ready to type, prefilled, and refusing.
    @MainActor
    func testNewProjectSheetOpensFocusedOnTheNameFieldWithPortPrefilled() throws {
        launchApp()

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 3), "The sheet should open")

        XCTAssertEqual(
            newProjectSheet.portField.value as? String,
            "8080",
            "The port field should open prefilled with 8080"
        )
        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))
        XCTAssertFalse(
            newProjectSheet.createButton.isEnabled,
            "Create project should be disabled while the name is empty"
        )

        // Deliberately no click first — that is the whole point of `.defaultFocus`, and every other
        // test in the repository clicks the field before typing, so nothing exercised it.
        app.typeText("Focused Start")

        XCTAssertEqual(
            newProjectSheet.nameField.value as? String,
            "Focused Start",
            "Typing straight after the sheet opens should land in the name field"
        )
        XCTAssertTrue(
            newProjectSheet.createButton.isEnabled,
            "Create project should enable once the name field holds a name"
        )
    }

    /// NEWPROJ-08, NEWPROJ-16 — a name made of spaces is not a name, and Return does not force it
    /// through.
    @MainActor
    func testWhitespaceOnlyNameKeepsCreateDisabledAndReturnInert() throws {
        launchApp()

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 3), "The sheet should open")

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("   ")

        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))
        XCTAssertFalse(
            newProjectSheet.createButton.isEnabled,
            "A whitespace-only name should leave Create project disabled"
        )

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(
            newProjectSheet.createButton.exists,
            "Return on an invalid form should leave the sheet open"
        )
        XCTAssertFalse(
            workspace.sidebarEmptyHeading.exists,
            "Return on an invalid form should not have created a project"
        )

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Trimmed")

        let enabled = NSPredicate(format: "isEnabled == true")
        expectation(for: enabled, evaluatedWith: newProjectSheet.createButton)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(
            (newProjectSheet.nameField.value as? String)?.contains("Trimmed") == true,
            "The real name should have landed in the same field the spaces did"
        )
    }

    /// NEWPROJ-10, NEWPROJ-11, NEWPROJ-12 — the inline port message, and the one case it stays quiet
    /// for.
    @MainActor
    func testPortValidationMessageAppearsAndClearsWithTheField() throws {
        launchApp()

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.portField.waitForExistence(timeout: 3), "The sheet should open")

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Port Message")
        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))

        replacePortField(with: "70000")

        XCTAssertTrue(
            portValidationMessage.waitForExistence(timeout: 3),
            "An out-of-range port should be explained under the field"
        )
        XCTAssertTrue(
            shownText(of: portValidationMessage).contains("between 1 and 65535"),
            "The message should state the range, got '\(shownText(of: portValidationMessage))'"
        )
        XCTAssertFalse(newProjectSheet.createButton.isEnabled, "An out-of-range port should refuse Create")

        // An empty port field is a form you have not finished, not a mistake you have made.
        clearPortField()

        XCTAssertTrue(
            portValidationMessage.waitForNonExistence(timeout: 3),
            "An empty port field should be silent rather than accusing"
        )
        XCTAssertFalse(
            newProjectSheet.createButton.isEnabled,
            "Silent is not the same as valid — Create should stay disabled with no port"
        )

        replacePortField(with: "abc")

        XCTAssertTrue(
            portValidationMessage.waitForExistence(timeout: 3),
            "A non-numeric port should be refused the same way an out-of-range one is"
        )
        XCTAssertFalse(newProjectSheet.createButton.isEnabled, "A non-numeric port should refuse Create")
    }

    /// NEWPROJ-19 — creating a project while one is open swaps the workspace over to the new one.
    ///
    /// The existing ⌘N test cancels the sheet, which is what proves cancelling is harmless; nothing
    /// yet confirmed it.
    @MainActor
    func testCreatingAProjectFromAnOpenProjectSwapsTheWorkspace() throws {
        launchApp()

        createProjectViaUI(name: "First Project")
        createEndpointViaUI(name: "First EP", path: "/first")
        waitForAsyncSave()

        let newProjectItem = app.menuItems["New Project\u{2026}"]
        XCTAssertTrue(newProjectItem.waitForExistence(timeout: 5), "File ▸ New Project… should exist")
        newProjectItem.click()

        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 5), "The sheet should open")
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Second Project")
        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))
        newProjectSheet.createButton.click()

        XCTAssertTrue(
            workspace.sidebarEmptyHeading.waitForExistence(timeout: 10),
            "The workspace should swap to the new, empty project"
        )
        XCTAssertFalse(
            app.staticTexts["/first"].firstMatch.exists,
            "The first project's endpoints should not still be on screen"
        )
    }

    // MARK: - Closing a project

    /// PROJREOPEN-02 — Close Project is disabled until there is something to close.
    @MainActor
    func testCloseProjectIsDisabledWhileNoProjectIsOpen() throws {
        launchApp()

        // The menu has to be *open* for AppKit to have validated its items; a closed menu's item can
        // report itself enabled whatever the scene says.
        XCTAssertFalse(
            closeProjectMenuItemIsEnabled(),
            "File ▸ Close Project should be disabled while no project is open"
        )

        createProjectViaUI(name: "Enables Close")

        XCTAssertTrue(
            closeProjectMenuItemIsEnabled(),
            "File ▸ Close Project should enable once a project is open"
        )
    }

    // MARK: - Helpers

    /// Creates a project, gives it one endpoint whose path identifies it, and returns to the welcome
    /// window with everything saved.
    ///
    /// The endpoint is how a later assertion tells *which* project was opened: the sidebar draws the
    /// path, so `app.staticTexts[path]` is a positive identification the window title cannot give.
    @MainActor
    private func createProjectWithEndpoint(named name: String, path: String) {
        createProjectViaUI(name: name)
        createEndpointViaUI(name: "\(name) EP", path: path)
        waitForAsyncSave()
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible(), "Closing \(name) should return to the welcome window")
    }

    /// A recents row, matched by the label it reads out rather than by its identifier.
    ///
    /// `recentProject-<name>` is set on the row and never reaches the tree: `welcome.recents.list` is
    /// stamped over every descendant of the list, and pairing that identifier with
    /// `.accessibilityElement(children: .contain)` does not stop it — `.contain` keeps each child as
    /// an element with its own *label and value*, which is a different thing. So the rule from the
    /// `mimic-ui-tests` skill applies: target a leaf inside a named container by label.
    ///
    /// The prefix is the row's own `accessibilityLabel`, `"<name>, last opened <when>"`, and it
    /// includes the comma and the phrase on purpose. `"Twin"` alone is a prefix of `"Twin (Copy)"`
    /// and would match a project's own duplicate; it is also the exact text of the name `Text` inside
    /// the row, so a bare-name match could return a leaf where the row was wanted and every
    /// `row.staticTexts` query beneath it would find nothing.
    ///
    /// `label` only, matching `JourneyNavigatorPage.journeyRow(named:)` — the label is set explicitly
    /// on the row, so it cannot arrive as a value.
    @MainActor
    private func recentsRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), last opened"))
            .firstMatch
    }

    /// The `Text` that draws a recent project's name, matched exactly.
    ///
    /// Exact rather than `CONTAINS`, which is what makes it safe once a copy exists: "Twin" must not
    /// answer for "Twin (Copy)".
    @MainActor
    private func recentProjectNameText(_ name: String) -> XCUIElement {
        app.staticTexts
            .matching(NSPredicate(format: "value == %@ OR label == %@", name, name))
            .firstMatch
    }

    /// The inline validation message under the new-project sheet's port field.
    ///
    /// By the sentence it reads out, not by `ds.textfield.newProject.port.error`, which is not in the
    /// tree — and the spelling is not the problem. `NewProjectSheet` stamps `serverPortField` on the
    /// whole `DSTextField`, and that is the *point*: the wrapper lends its name to the single input
    /// inside it, which is why `app.textFields["serverPortField"]` matches at all. The same
    /// propagation reaches the validation row, so whatever identifier `DSTextField` builds for it is
    /// overwritten. What survives is the row's `.accessibilityElement()` + `.accessibilityLabel(message)`.
    ///
    /// `NewProjectSheetPage.portValidationError` and `NewEndpointSheetPage.pathError` both still ask
    /// for the identifier; both live in `MimicUITests.swift`, so this file cannot fix them.
    ///
    /// The message tracks the field's binding, not its commit: `portValidationMessage` in
    /// `NewProjectSheet` is derived from `form.portString`, and a SwiftUI `TextField` over a `String`
    /// updates that on every keystroke — so nothing has to be blurred or submitted first.
    @MainActor
    private var portValidationMessage: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(
                format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                "Port must be",
                "Port must be"
            ))
            .firstMatch
    }

    /// The recents list itself, matched across element types.
    ///
    /// A SwiftUI `List` realizes as a table, an outline or a plain group depending on how AppKit
    /// collapses it, so `app.tables[…]` would be a guess; matching the identifier across every type
    /// is the form this suite already uses for the toolbar's Import menu.
    @MainActor
    private var recentsList: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "welcome.recents.list").firstMatch
    }

    /// Gives the recents list keyboard focus without opening anything.
    ///
    /// Clicking a row opens its project, so the click has to land in the empty space *below* the
    /// rows — the list fills the right column and no test here creates enough projects to reach the
    /// bottom of it. Whether that click also clears the selection is AppKit's business; every caller
    /// clamps with more arrow presses than there are rows, so it does not matter.
    @MainActor
    private func focusRecentsList() {
        XCTAssertTrue(
            recentsList.waitForExistence(timeout: 5),
            "The recents list should be addressable as welcome.recents.list"
        )
        recentsList.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.92)).click()
    }

    @MainActor
    private func press(_ key: XCUIKeyboardKey, times: Int) {
        for _ in 0..<times {
            app.typeKey(key, modifierFlags: [])
        }
    }

    /// Right-clicks a recent project and chooses Delete project…, leaving the confirmation up.
    @MainActor
    private func beginDeleting(_ name: String) {
        guard let row = welcome.findRecentProject(named: name) else {
            XCTFail("\(name) should be listed in recents")
            return
        }
        row.rightClick()

        let deleteItem = app.menuItems["Delete project\u{2026}"]
        XCTAssertTrue(
            deleteItem.waitForExistence(timeout: 3),
            "The recents context menu should offer Delete project…"
        )
        deleteItem.click()

        XCTAssertTrue(
            deleteConfirmation.deleteButton.waitForExistence(timeout: 5),
            "The delete confirmation should appear"
        )
    }

    /// Right-clicks a recent project by its exact name and chooses Duplicate.
    ///
    /// Neither form `findRecentProject` tries will do here. The identifier it asks for first is not in
    /// the tree at all (see ``recentsRow(named:)``), and its text fallback matches on `CONTAINS`: once
    /// a copy exists, "Twin" is a substring of "Twin (Copy)" and the fallback would happily duplicate
    /// the copy instead of the original. The name `Text` matched *exactly* is unambiguous, and it is
    /// the element the fallback right-clicks on every other recents test in this file, so the context
    /// menu is known to open from it.
    @MainActor
    private func duplicateProjectFromRecents(named name: String) {
        let nameText = recentProjectNameText(name)
        XCTAssertTrue(
            nameText.waitForExistence(timeout: 5),
            "\(name) should have a row of its own in recents"
        )
        nameText.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 3), "The context menu should offer Duplicate")
        duplicateItem.click()
    }

    @MainActor
    private func clearPortField() {
        newProjectSheet.portField.click()
        newProjectSheet.portField.typeKey("a", modifierFlags: .command)
        newProjectSheet.portField.typeKey(.delete, modifierFlags: [])
        // Move focus off the field so the form has committed before anything is asserted.
        newProjectSheet.nameField.click()
    }

    @MainActor
    private func replacePortField(with text: String) {
        newProjectSheet.portField.click()
        newProjectSheet.portField.typeKey("a", modifierFlags: .command)
        newProjectSheet.portField.typeText(text)
        newProjectSheet.nameField.click()
    }

    /// Opens the File menu, reads whether Close Project is enabled, and closes the menu again.
    @MainActor
    private func closeProjectMenuItemIsEnabled() -> Bool {
        let fileMenu = app.menuBars.menuBarItems["File"]
        XCTAssertTrue(fileMenu.waitForExistence(timeout: 5), "The File menu should exist")
        fileMenu.click()

        let item = app.menuItems["Close Project"]
        XCTAssertTrue(item.waitForExistence(timeout: 3), "File ▸ Close Project should exist")
        let isEnabled = item.isEnabled

        app.typeKey(.escape, modifierFlags: [])
        // Not `waitForNonExistence`: menu items stay in the accessibility tree with the menu closed —
        // that is why `closeProjectViaMenu` can click one without opening File first. Hittability is
        // what actually tracks the open menu, and waiting on it keeps the next click from landing on
        // a window this one is still covering.
        _ = UITestApp.waitUntil(timeout: 2) { item.isHittable == false }

        return isEnabled
    }

    /// True when some static text on screen reads exactly `text`.
    ///
    /// Matched on `value` as well as `label` because a `DSPanelHeader` flattens its leaves: the dump
    /// in the `mimic-ui-tests` skill's `references/accessibility-tree.md` shows the title and the
    /// subtitle arriving as the element's *value*, under the header's identifier rather than their
    /// own. Exact rather than `CONTAINS`, so a one-character count cannot be satisfied by a timestamp.
    @MainActor
    private func staticTextExists(exactly text: String, timeout: TimeInterval = 3) -> Bool {
        let predicate = NSPredicate(format: "value == %@ OR label == %@", text, text)
        return app.staticTexts.matching(predicate).firstMatch.waitForExistence(timeout: timeout)
    }

    @MainActor
    private func rowText(in row: XCUIElement, exactly text: String) -> XCUIElement {
        row.staticTexts
            .matching(NSPredicate(format: "value == %@ OR label == %@", text, text))
            .firstMatch
    }

    @MainActor
    private func rowText(in row: XCUIElement, beginningWith prefix: String) -> XCUIElement {
        row.staticTexts
            .matching(NSPredicate(format: "value BEGINSWITH %@ OR label BEGINSWITH %@", prefix, prefix))
            .firstMatch
    }

    /// What an element actually reads as: a SwiftUI `Text` surfaces its string as a value in some
    /// subtrees and as a label in others.
    @MainActor
    private func shownText(of element: XCUIElement) -> String {
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
    }
}
