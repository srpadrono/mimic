import XCTest
import AppKit
import Foundation

// MARK: - Tests

/// Full end-to-end UI journey tests for Project Management (Phase 3) and Workspace Layout (Phase 5).
///
/// Each test resets state by passing `-MimicResetForTesting` launch argument, which wipes
/// the database and UserDefaults from within the sandboxed app.
final class MimicUITests: MimicUITestCase {

    // MARK: - 1. Welcome Screen Layout

    @MainActor
    func testWelcomeScreenShowsHeroAndButtons() throws {
        launchApp()

        XCTAssertTrue(welcome.assertVisible(),
                      "Welcome screen should be visible")
        XCTAssertTrue(welcome.newProjectButton.exists,
                      "New Project button should be visible")
        XCTAssertTrue(welcome.waitForNoRecentProjectsLabel(timeout: 3),
                      "No Recent Projects label should show on fresh launch")
    }

    // MARK: - 2. New Project → Workspace Layout

    @MainActor
    func testCreateNewProject() throws {
        launchApp()

        welcome.newProjectButton.click()

        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 3),
                      "Project name field should appear in sheet")
        XCTAssertTrue(newProjectSheet.portField.exists)

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Test API")

        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))
        XCTAssertTrue(newProjectSheet.createButton.isEnabled,
                      "Create button should be enabled after typing a name")

        newProjectSheet.createButton.click()

        XCTAssertTrue(workspace.assertVisible(),
                      "Workspace should appear after project creation")
    }

    // MARK: - 3. Workspace Shows 4-Panel Layout

    @MainActor
    func testWorkspaceShowsFourPanelLayout() throws {
        launchApp()
        createProjectViaUI(name: "Layout Test")

        // Sidebar with empty state
        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
                      "Sidebar should show 'No endpoints' empty state")

        // Center pane with empty state
        XCTAssertTrue(workspace.centerEmptyHeading.exists,
                      "Center pane should show 'No endpoint selected' empty state")

        // Drawer with empty state
        XCTAssertTrue(workspace.drawerEmptyHeading.exists,
                      "Drawer should show 'No requests yet' empty state")

        // The navigator owns "add", because what it adds depends on which tab is showing.
        XCTAssertTrue(workspace.addEndpointButton.exists,
                      "Add endpoint button should be in the navigator strip")

        // Toolbar buttons
        XCTAssertTrue(workspace.toggleInspectorButton.exists,
                      "Toggle inspector button should be in toolbar")
        XCTAssertTrue(workspace.toggleDrawerButton.exists,
                      "Toggle drawer button should be in toolbar")

        // Both of these used to sit in the toolbar and were removed: "add endpoint" duplicated the
        // navigator's own button and was wrong on the Journeys tab, and the journeys button opened a
        // window that ⌘2 now reaches in place. Asserted rather than assumed, so a well-meaning
        // restoration has to argue with a failing test first.
        XCTAssertFalse(workspace.toolbarAddEndpointButton.exists,
                       "Add endpoint should not be duplicated in the toolbar")
        XCTAssertFalse(workspace.toolbarJourneysButton.exists,
                       "Journeys should not have a toolbar button — the navigator has a Journeys tab")
    }

    // MARK: - 4. Autosave Status Indicator

    @MainActor
    func testAutosaveIndicatorAppearsAfterEdit() throws {
        launchApp()
        createProjectViaUI(name: "Autosave Test")

        // Trigger a fresh autosave with a discrete edit, then assert the transient indicator surfaces.
        // The assertion begins polling the instant the edit is committed, so it catches the indicator
        // as it appears rather than racing one that has already cycled saving → saved → idle.
        workspace.addEndpointButton.click()
        _ = newEndpointSheet.nameField.waitForExistence(timeout: 3)
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("Trigger Save")
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/trigger")
        newEndpointSheet.createButton.click()

        XCTAssertTrue(
            UITestApp.waitForAny(
                [workspace.autosaveSavingIndicator, workspace.autosaveSavedIndicator],
                timeout: 6
            ),
            "Autosave indicator should surface after an edit"
        )
    }

    // MARK: - 5. Close and Reopen Restores Project from Recents

    @MainActor
    func testCloseAndReopenProjectFromRecents() throws {
        launchApp()
        createProjectViaUI(name: "Persistent Project")

        XCTAssertTrue(workspace.assertVisible())

        waitForAsyncSave()

        closeProjectViaMenu()

        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "Persistent Project")
        XCTAssertNotNil(recentElement, "Created project should appear in recents list")
        recentElement!.click()

        XCTAssertTrue(workspace.assertVisible(),
                      "Workspace should appear after reopening from recents")
    }

    // MARK: - 6. Cmd+N Returns to Welcome with Recents

    /// The regression test for the defect this command used to be: "New Project" was wired straight
    /// to `closeProject`, so ⌘N discarded your place instead of creating anything.
    @MainActor
    func testNewProjectOpensTheSheetAndLeavesTheProjectOpen() throws {
        launchApp()
        createProjectViaUI(name: "Stays Open")
        XCTAssertTrue(workspace.assertVisible())

        let newProjectItem = app.menuItems["New Project\u{2026}"]
        XCTAssertTrue(newProjectItem.waitForExistence(timeout: 5), "File ▸ New Project… should exist")
        newProjectItem.click()

        XCTAssertTrue(
            newProjectSheet.nameField.waitForExistence(timeout: 5),
            "New Project should open the new-project sheet"
        )
        newProjectSheet.cancelButton.click()

        // Cancelling has to leave you exactly where you were. If the command still closed the project
        // first, this lands on the welcome window instead.
        XCTAssertTrue(
            workspace.assertVisible(),
            "Cancelling the sheet should leave the open project untouched"
        )
    }

    @MainActor
    func testClosingAProjectReturnsToWelcomeWithRecents() throws {
        launchApp()
        createProjectViaUI(name: "Test API")

        XCTAssertTrue(workspace.assertVisible())
        waitForAsyncSave()

        closeProjectViaMenu()

        XCTAssertTrue(welcome.assertVisible())

        let recentRow = welcome.recentProjectRow(named: "Test API")
        let textFallback = welcome.recentProjectText(named: "Test API")
        XCTAssertTrue(
            UITestApp.waitForAny([recentRow, textFallback], timeout: 5),
            "Test API should appear in recent projects after Cmd+N"
        )
    }

    // MARK: - 7. Context Menu on Recent Project

    @MainActor
    func testContextMenuOnRecentProject() throws {
        launchApp()
        createProjectViaUI(name: "Context Menu Test")

        waitForAsyncSave()

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "Context Menu Test")
        XCTAssertNotNil(recentElement, "Recent project should exist")
        recentElement!.rightClick()

        XCTAssertTrue(app.menuItems["Open"].waitForExistence(timeout: 3),
                      "Open menu item should exist")
        XCTAssertTrue(app.menuItems["Duplicate"].exists,
                      "Duplicate menu item should exist")
        XCTAssertTrue(app.menuItems["Delete project…"].exists,
                      "Delete menu item should exist")

        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - 8. Duplicate Project

    @MainActor
    func testDuplicateProject() throws {
        launchApp()
        createProjectViaUI(name: "Original")

        waitForAsyncSave()

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "Original")
        XCTAssertNotNil(recentElement, "Original project should exist in recents")
        recentElement!.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 3))
        duplicateItem.click()

        let copyElement = welcome.findRecentProject(named: "Original (Copy)")
        XCTAssertNotNil(copyElement,
                        "Duplicated project 'Original (Copy)' should appear in recents")
    }

    // MARK: - 9. Delete Project with Confirmation

    @MainActor
    func testDeleteProjectWithConfirmation() throws {
        launchApp()
        createProjectViaUI(name: "To Delete")

        waitForAsyncSave()

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "To Delete")
        XCTAssertNotNil(recentElement, "Project should exist in recents")
        recentElement!.rightClick()

        let deleteItem = app.menuItems["Delete project…"]
        XCTAssertTrue(deleteItem.waitForExistence(timeout: 3))
        deleteItem.click()

        XCTAssertTrue(deleteConfirmation.deleteButton.waitForExistence(timeout: 3),
                      "Delete confirmation dialog should appear")
        XCTAssertTrue(deleteConfirmation.keepButton.exists,
                      "Keep project button should exist in confirmation")

        deleteConfirmation.deleteButton.click()

        XCTAssertTrue(welcome.waitForNoRecentProjectsLabel(timeout: 5),
                      "After deleting last project, empty state should show")
    }

    // MARK: - 10. Port Validation

    @MainActor
    func testPortValidationShowsInlineError() throws {
        launchApp()
        welcome.newProjectButton.click()

        XCTAssertTrue(newProjectSheet.portField.waitForExistence(timeout: 3))
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Port Validation Test")
        XCTAssertTrue(newProjectSheet.createButton.isEnabled,
                      "Create button should be enabled once the project name and default port are valid")

        newProjectSheet.portField.click()
        newProjectSheet.portField.typeKey("a", modifierFlags: .command)
        newProjectSheet.portField.typeText("99999")
        newProjectSheet.nameField.click()

        let invalidPredicate = NSPredicate(format: "isEnabled == false")
        expectation(for: invalidPredicate, evaluatedWith: newProjectSheet.createButton)
        waitForExpectations(timeout: 3)
        XCTAssertFalse(newProjectSheet.createButton.isEnabled,
                       "Create button should disable for invalid port 99999")

        newProjectSheet.portField.click()
        newProjectSheet.portField.typeKey("a", modifierFlags: .command)
        newProjectSheet.portField.typeText("3000")
        newProjectSheet.nameField.click()

        let validPredicate = NSPredicate(format: "isEnabled == true")
        expectation(for: validPredicate, evaluatedWith: newProjectSheet.createButton)
        waitForExpectations(timeout: 3)
        XCTAssertTrue(newProjectSheet.createButton.isEnabled,
                      "Create button should re-enable for valid port 3000")
    }

    // MARK: - 11a. Escape Dismisses Sheet

    @MainActor
    func testEscapeDismissesNewProjectSheet() throws {
        launchApp()

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 3))

        app.typeKey(.escape, modifierFlags: [])

        let sheetDismissed = newProjectSheet.nameField.waitForNonExistence(timeout: 3)
        XCTAssertTrue(sheetDismissed, "Sheet should be dismissed after Escape")
        XCTAssertTrue(welcome.assertVisible(timeout: 3),
                      "Welcome screen should still be visible")
    }

    // MARK: - 11b. Return Submits Sheet

    @MainActor
    func testReturnSubmitsNewProjectSheet() throws {
        launchApp()

        welcome.newProjectButton.click()

        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 3))

        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Return Test")

        XCTAssertTrue(newProjectSheet.createButton.waitForExistence(timeout: 2))
        let enabledPredicate = NSPredicate(format: "isEnabled == true")
        expectation(for: enabledPredicate, evaluatedWith: newProjectSheet.createButton, handler: nil)
        waitForExpectations(timeout: 3)

        app.typeKey(.return, modifierFlags: [])

        XCTAssertTrue(workspace.assertVisible(),
                      "Return key should submit the form and show workspace")
    }

    // MARK: - 12. Cancel Button Dismisses Sheet

    @MainActor
    func testCancelButtonDismissesNewProjectSheet() throws {
        launchApp()

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.cancelButton.waitForExistence(timeout: 3),
                      "Cancel button should appear in the New Project sheet")

        newProjectSheet.cancelButton.click()

        XCTAssertTrue(welcome.assertVisible(timeout: 3),
                      "Welcome screen should remain after dismissing the sheet")
        XCTAssertTrue(welcome.newProjectButton.exists,
                      "New Project button should still be visible")
    }

    // MARK: - 13. Toggle Inspector Panel

    @MainActor
    func testToggleInspectorPanel() throws {
        launchApp()
        createProjectViaUI(name: "Inspector Test")

        XCTAssertTrue(workspace.toggleInspectorButton.waitForExistence(timeout: 5),
                      "Toggle inspector button should exist")

        // Inspector should be visible by default
        let overview = InspectorPage(app: app).element("inspector.overview")
        XCTAssertTrue(overview.waitForExistence(timeout: 5))
        workspace.toggleInspectorButton.click()
        XCTAssertTrue(overview.waitForNonExistence(timeout: 5), "The inspector must actually close")

        workspace.toggleInspectorButton.click()
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "The inspector must actually reopen")
    }

    // MARK: - 14. Toggle Request Log Drawer

    @MainActor
    func testToggleDrawerPanel() throws {
        launchApp()
        createProjectViaUI(name: "Drawer Test")

        XCTAssertTrue(workspace.toggleDrawerButton.waitForExistence(timeout: 5),
                      "Toggle drawer button should exist")

        // Drawer should be visible by default with empty state
        XCTAssertTrue(workspace.drawerEmptyHeading.exists,
                      "Drawer empty state should be visible")

        // Hide drawer
        workspace.toggleDrawerButton.click()

        // Drawer empty state should disappear
        let drawerHidden = workspace.drawerEmptyHeading.waitForNonExistence(timeout: 3)
        XCTAssertTrue(drawerHidden, "Drawer should be hidden after toggle")

        // Show drawer again
        workspace.toggleDrawerButton.click()

        XCTAssertTrue(workspace.drawerEmptyHeading.waitForExistence(timeout: 3),
                      "Drawer should reappear after toggle")
    }

    // MARK: - 15. Create Endpoint via Toolbar

    @MainActor
    func testCreateEndpointViaToolbar() throws {
        launchApp()
        createProjectViaUI(name: "Endpoint Test")

        workspace.addEndpointButton.click()

        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 3),
                      "New endpoint sheet should appear")

        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("Get Users")

        // Path should already default to "/"
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/api/v1/users")

        newEndpointSheet.createButton.click()

        // Endpoint should appear in sidebar — sidebar empty state should disappear
        let sidebarEmpty = workspace.sidebarEmptyHeading.waitForNonExistence(timeout: 5)
        XCTAssertTrue(sidebarEmpty, "Sidebar empty state should disappear after adding endpoint")

        // Editor should appear in center pane
        XCTAssertTrue(endpointEditor.pathLabel.waitForExistence(timeout: 5),
                      "Endpoint path should be visible in editor")
    }

    // MARK: - 16. Edit Endpoint Status Code

    @MainActor
    func testEditEndpointStatusCode() throws {
        launchApp()
        createProjectViaUI(name: "Edit Test")
        createEndpointViaUI(name: "Test Endpoint", path: "/api/test")

        XCTAssertTrue(endpointEditor.statusCodeField.waitForExistence(timeout: 5),
                      "Status code field should be visible in editor")

        endpointEditor.statusCodeField.click()
        endpointEditor.statusCodeField.typeKey("a", modifierFlags: .command)
        endpointEditor.statusCodeField.typeText("404")

        // Verify the field accepted the value
        XCTAssertEqual(endpointEditor.statusCodeField.value as? String, "404")
    }

    // MARK: - 17. Delete Endpoint with Confirmation

    @MainActor
    func testDeleteEndpointWithConfirmation() throws {
        launchApp()
        createProjectViaUI(name: "Delete EP Test")
        createEndpointViaUI(name: "To Delete", path: "/api/delete-me")

        XCTAssertTrue(endpointEditor.moreMenu.waitForExistence(timeout: 5))
        endpointEditor.moreMenu.click()

        // Click "Delete endpoint…" from the more-options menu
        let deleteMenuItem = app.menuItems["Delete endpoint\u{2026}"]
        XCTAssertTrue(deleteMenuItem.waitForExistence(timeout: 3))
        deleteMenuItem.click()

        // Confirmation dialog
        let confirmSheet = app.sheets.firstMatch
        XCTAssertTrue(confirmSheet.buttons["Delete"].waitForExistence(timeout: 3),
                      "Delete confirmation should appear")
        confirmSheet.buttons["Delete"].click()

        // Sidebar should return to empty state
        XCTAssertTrue(workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
                      "Sidebar should show empty state after deleting last endpoint")
    }

    // MARK: - 18. Endpoint Persists After Close and Reopen

    @MainActor
    func testEndpointPersistsAfterCloseAndReopen() throws {
        launchApp()
        createProjectViaUI(name: "Persist EP Test")
        createEndpointViaUI(name: "Saved EP", path: "/api/saved")

        waitForAsyncSave()

        // Close project
        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        // Reopen
        let recentElement = welcome.findRecentProject(named: "Persist EP Test")
        XCTAssertNotNil(recentElement, "Project should appear in recents")
        recentElement!.click()

        XCTAssertTrue(workspace.endpointPathText("/api/saved").waitForExistence(timeout: 5),
                      "The exact saved endpoint must return after reopening")
    }

    // MARK: - 19. Default Scenario Visible and Active in Inspector

    @MainActor
    func testDefaultScenarioVisibleInInspector() throws {
        launchApp()
        createProjectViaUI(name: "Scenario Test")
        createEndpointViaUI(name: "Scenario EP", path: "/api/scenarios")

        // The default scenario should be visible and active in the inspector
        XCTAssertTrue(inspector.isScenarioActive(named: "Default"),
                      "Default scenario should be visible and active in inspector")
    }

    // MARK: - 20. Duplicate Scenario via Context Menu

    @MainActor
    func testDuplicateScenario() throws {
        launchApp()
        createProjectViaUI(name: "Dup Scenario Test")
        createEndpointViaUI(name: "Dup EP", path: "/api/dup")

        // Right-click the Default scenario to duplicate
        let defaultRow = inspector.findScenario(named: "Default")
        XCTAssertTrue(defaultRow.waitForExistence(timeout: 5))
        defaultRow.rightClick()

        let duplicateItem = app.menuItems["Duplicate"]
        XCTAssertTrue(duplicateItem.waitForExistence(timeout: 3))
        duplicateItem.click()

        // Duplicated scenario should appear
        let copyRow = inspector.findScenario(named: "Default (Copy)")
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5),
                      "Duplicated scenario 'Default (Copy)' should appear in list")
    }

    // MARK: - 21. Switch Active Scenario via Click

    @MainActor
    func testSwitchActiveScenarioViaClick() throws {
        launchApp()
        createProjectViaUI(name: "Switch Test")
        createEndpointViaUI(name: "Switch EP", path: "/api/switch")

        // Duplicate to get a second scenario
        let defaultRow = inspector.findScenario(named: "Default")
        XCTAssertTrue(defaultRow.waitForExistence(timeout: 5))
        defaultRow.rightClick()

        app.menuItems["Duplicate"].click()

        let copyRow = inspector.findScenario(named: "Default (Copy)")
        XCTAssertTrue(copyRow.waitForExistence(timeout: 5))

        // Click the copy to make it active
        copyRow.click()

        // Verify it became active
        XCTAssertTrue(inspector.isScenarioActive(named: "Default (Copy)"),
                      "Clicked scenario should become active")
    }

    // MARK: - 22. Search Filter in Sidebar

    @MainActor
    func testSidebarSearchFiltersEndpoints() throws {
        launchApp()
        createProjectViaUI(name: "Search Test")
        createEndpointViaUI(name: "Get Users", path: "/api/users")
        createEndpointViaUI(name: "Get Posts", path: "/api/posts")

        // Navigator rows expose method, path and name as one accessible element.
        let usersPath = workspace.endpointPathText("/api/users")
        let postsPath = workspace.endpointPathText("/api/posts")
        XCTAssertTrue(usersPath.waitForExistence(timeout: 5),
                      "Get Users endpoint should be visible")
        XCTAssertTrue(postsPath.waitForExistence(timeout: 5),
                      "Get Posts endpoint should be visible")

        // The search field is pinned above the list, not a row inside it.
        // Address the field itself, not the filter's container. AppKit can flatten a container
        // identifier onto its children differently across macOS releases.
        let searchField = app.textFields["sidebar.filter.field"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "Search field should be available in sidebar")
        searchField.click()
        searchField.typeText("users")
        XCTAssertTrue(usersPath.waitForExistence(timeout: 5))
        XCTAssertTrue(postsPath.waitForNonExistence(timeout: 5),
                      "Filtering for users must actually remove the posts row")

        // After filtering, "No matches" should NOT appear (we should still have "users")
        let noMatches = app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", "No endpoints match", "No endpoints match")
        ).firstMatch
        XCTAssertFalse(noMatches.waitForExistence(timeout: 2),
                       "Should not show 'no matches' when filtering for 'users'")

        // Clear search — both should return
        searchField.click()
        searchField.typeKey("a", modifierFlags: .command)
        searchField.typeKey(.delete, modifierFlags: [])

        // After clearing, both endpoints should be visible again
        XCTAssertTrue(usersPath.waitForExistence(timeout: 3),
                      "/api/users should be visible after clearing search")
        XCTAssertTrue(postsPath.waitForExistence(timeout: 3),
                      "/api/posts should be visible after clearing search")
    }

    // MARK: - 24. Request Log Drawer Shows Header and Empty State

    @MainActor
    func testRequestLogDrawerShowsHeaderAndEmptyState() throws {
        launchApp()
        createProjectViaUI(name: "Log Test")

        // Drawer should show header and empty state
        XCTAssertTrue(requestLogDrawer.emptyHeading.waitForExistence(timeout: 5),
                      "Request log should show empty state when no requests")

        // Filter controls only appear when there are log entries (nothing to filter when empty)
        XCTAssertFalse(requestLogDrawer.filterField.exists,
                       "Filter field should not show when log is empty")
    }

    // MARK: - 24c. Capturing Selected Traffic as a Journey

    /// Picking a run of requests out of the log and saving it as a journey — how a flow gets built
    /// from a session rather than one call at a time.
    ///
    /// Covers the two things that are only observable end to end: that ⌘-click actually reaches the
    /// app as a modifier (the row reads `NSEvent.modifierFlags` at click time rather than composing
    /// gestures per chord), and that the menu counts what it is about to capture.
    @MainActor
    func testCapturingSelectedRequestsAsJourney() async throws {
        let port = 62096

        launchApp()
        createProjectViaUI(name: "Capture Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "Server should report its base URL once running"
        )

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)

        XCTAssertTrue(
            requestLogDrawer.waitForRowCount(2, timeout: 15),
            "Both requests should reach the log"
        )

        let rows = requestLogDrawer.distinctRows(limit: 2)
        XCTAssertEqual(rows.count, 2, "Both requests should be listed as separate rows")
        let firstRow = rows[0]
        let secondRow = rows[1]

        // ⌘-click adds the second row to the selection instead of replacing it — the row reads
        // `NSEvent.modifierFlags` at click time, and this held-modifier dance is the only way to
        // exercise that from a test. The drawer does now answer ⌘A while its table holds keyboard
        // focus, but that is a different path — it never reaches the row's modifier reading at all
        // — and it takes *every* row the filter is showing, so on a two-row log it would satisfy
        // the menu's count while saying nothing about the mechanism this test exists for.
        //
        // The menu naming a *count* is the real check: a selection collapsed to one row says
        // "Add to journey" instead, so the assertion cannot pass for the wrong reason.
        //
        // When this assertion spends several runs failing while the dance looks right, suspect the
        // *menu's visibility* before the modifier. Five consecutive CI runs failed here after the
        // row composed itself with `.accessibilityElement(children: .ignore)` — the menu, then
        // attached *beneath* that modifier, still opened for the pointer, but its items surfaced
        // through the swallowed subtree and never existed as elements, so `app.menuItems` matched
        // nothing whatever the selection held. That read as a dropped modifier, and the retry
        // iteration resumed *after* the failed test rather than re-running it, so "passes on
        // retry" was a misreading of the resumed suite's log. The row now attaches its menu after
        // forming the element, and the failure message below prints what the tree actually holds.
        let captureMenu = app.menuItems["Add 2 requests to journey"]
        let collapsedMenu = app.menuItems["Add to journey"]
        firstRow.click()
        // Selecting the first row opens the inspector with an animation, and the drawer narrows
        // underneath it while that runs. The ⌘-click and the right-click below are both aimed at a
        // frame, so they race it — and a ⌘-click that lands between two rows leaves the selection at
        // one, which presents here as the modifier having been dropped. It is not; the row moved.
        UITestApp.waitForStableFrame(secondRow)

        XCUIElement.perform(withKeyModifiers: .command) {
            secondRow.click()
        }
        secondRow.rightClick()
        // Polled together — waiting out one item's timeout before looking at the other is the
        // `a || b` trap rule 9 of the UI Definition of Done names.
        _ = UITestApp.waitForAny([captureMenu, collapsedMenu], timeout: 5)
        if !captureMenu.exists {
            // Name what the runner actually saw, so a red run's CI failure step prints a diagnosis
            // instead of a hypothesis: the singular menu means the modifier did not reach the app;
            // no menu items at all means the menu never opened — or opened with its items invisible
            // to the tree, which is the swallowed-subtree failure above. (`menus` counts open
            // AXMenu elements, so "menu open, items missing" and "no menu" read differently here.)
            let visible = app.menuItems.allElementsBoundByIndex.prefix(8).map(\.title)
            XCTFail(
                "The context menu should offer to capture the whole selection, not just the clicked "
                    + "row. collapsed=\(collapsedMenu.exists) openMenus=\(app.menus.count) "
                    + "visibleMenuItems=\(visible)"
            )
        }
        // The ellipsis promises a dialog, and now there is one. Driven through the shared helper
        // rather than clicked here: this is the nested-menu interaction that has flaked in two
        // different suites, and `UITestApp.chooseFromSubmenu` carries the account of why widening the
        // wait was the wrong fix for it. The assertion is unchanged — every attempt ends waiting for
        // this same field.
        let sheetAppeared = UITestApp.chooseFromSubmenu(
            in: app,
            parent: captureMenu,
            item: app.menuItems["New journey from these 2 requests\u{2026}"],
            thenAwait: captureSheet.nameField,
            reopenMenu: { secondRow.rightClick() },
            menuIsAlreadyOpen: true
        )
        if !sheetAppeared {
            let visible = app.menuItems.allElementsBoundByIndex.prefix(8).map(\.title)
            XCTFail(
                "Capturing into a new journey should ask for a name first. "
                    + "openMenus=\(app.menus.count) visibleMenuItems=\(visible) "
                    + "journeyEditorOpen=\(app.staticTexts["journeyEditor.name"].exists)"
            )
        }
        captureSheet.nameField.click()
        captureSheet.nameField.typeKey("a", modifierFlags: .command)
        captureSheet.nameField.typeText("Captured session")
        captureSheet.createButton.click()

        // Capturing has to *show* the journey, or the command reads as having done nothing.
        XCTAssertTrue(
            app.staticTexts["journeyEditor.name"].waitForExistence(timeout: 5),
            "Creating the journey should open it in the editor"
        )
    }

    // MARK: - 24b. Selecting a Request Shows It in the Inspector

    /// The whole point of moving detail out of the drawer: clicking a row has to put the request and
    /// its body somewhere you can actually read them.
    @MainActor
    func testSelectingLoggedRequestShowsDetailInInspector() async throws {
        let port = 62091
        let payload = #"{"name":"Ada Lovelace","role":"engineer"}"#

        launchApp()
        createProjectViaUI(name: "Traffic Detail Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")
        // A small CI display can put the entire server summary in AppKit's native toolbar overflow.
        // Make the status visible before asserting on its address and starting traffic.
        workspace.fillWindow()

        workspace.serverToggleButton.click()
        guard workspace.waitForServerURL(port: port) else {
            XCTFail("Server should report its base URL once running")
            return
        }

        await sendRequest(port: port, path: "/api/users", method: "POST", body: payload)

        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForExistence(timeout: 10),
            "The request should appear in the log once the server has answered it"
        )
        requestLogDrawer.firstLogRow.click()

        // The inspector takes over — this is the behaviour the redesign exists for.
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Selecting a logged request should switch the inspector to request detail"
        )
        XCTAssertTrue(
            requestDetail.path.waitForExistence(timeout: 5),
            "Request detail should show the path"
        )

        // Body tab: the payload has to be visible and searchable.
        requestDetail.tab("Body").click()
        XCTAssertTrue(
            UITestApp.waitForAny(
                [requestDetail.responseBody, requestDetail.bodySearchField],
                timeout: 5
            ),
            "The Body tab should render the exchange"
        )

        XCTAssertTrue(
            requestDetail.bodySearchField.waitForExistence(timeout: 5),
            "The Body tab should offer a find field"
        )
        requestDetail.bodySearchField.click()
        requestDetail.bodySearchField.typeText("Lovelace")

        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    requestDetail.responseBodyMatches,
                    app.descendants(matching: .any)
                        .matching(identifier: "requestLog.body.request.matches")
                        .firstMatch
                ],
                timeout: 5
            ),
            "Searching should report how many times the term appears in a body"
        )

        // Copying is the other half of "I found the request" — it must not silently do nothing.
        XCTAssertTrue(requestDetail.copyCurlButton.waitForExistence(timeout: 5),
                      "Request detail should offer a copy-as-curl button")
        requestDetail.copyCurlButton.click()
        XCTAssertTrue(
            requestDetail.copyConfirmation.waitForExistence(timeout: 3),
            "Copying should confirm it happened"
        )

        // Closing returns the panel to whatever it was showing before.
        requestDetail.closeButton.click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Scenarios"),
            "Closing request detail should restore the endpoint inspector"
        )

        workspace.serverToggleButton.click()
    }

    // MARK: - 24d. Moving Through the Request Log With the Keyboard

    /// The half of keyboard navigation that unit tests cannot reach.
    ///
    /// `RequestLogDrawerView.nextSelection(key:…)` is a pure function and is covered thoroughly, but
    /// every one of those tests calls it directly. None of them can say whether a key press ever
    /// *arrives* — that depends on the table taking focus, on `.onKeyPress` being attached where the
    /// press lands, and on nothing upstream claiming the chord first, which is exactly the layer a
    /// unit test is blind to.
    ///
    /// Arrow keys rather than ⌘A on purpose. AppKit offers an enabled menu item's key equivalent to
    /// the menu before the focused view, and the default Edit menu carries Select All; whether that
    /// item validates disabled here is a claim about the responder chain that this suite should not
    /// assert until somebody has watched it. The arrows compete with nothing.
    @MainActor
    func testArrowKeysMoveThroughTheRequestLog() async throws {
        let port = 62097

        launchApp()
        createProjectViaUI(name: "Keyboard Test", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")

        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "Server should report its base URL once running"
        )

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/orders", method: "GET", body: nil)

        XCTAssertTrue(
            requestLogDrawer.waitForRowCount(2, timeout: 15),
            "Both requests should reach the log"
        )

        // The click is what hands the table keyboard focus, so it is a precondition of the press
        // rather than part of what is being tested.
        let rows = requestLogDrawer.distinctRows(limit: 2)
        XCTAssertEqual(rows.count, 2, "Both requests should be listed as separate rows")
        rows[0].click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Clicking a row should show it in the inspector"
        )
        XCTAssertTrue(
            requestDetail.path.waitForExistence(timeout: 5),
            "Request detail should name the request it is showing"
        )

        // What the inspector says *before* the press, so the assertion is that the selection moved
        // rather than that it landed on a particular path. Which row is second depends on the log's
        // sort order, and a test that hard-codes one of the two paths passes or fails on that rather
        // than on the keyboard.
        let before = requestDetail.shownPath()
        app.typeKey(.downArrow, modifierFlags: [])

        // Polled by re-querying one identified element, never by walking the tree: an
        // `app.descendants(matching: .any)` carrying a `CONTAINS` predicate evaluates it against
        // every element in the window and times out inside XCUITest's own query evaluation, which
        // is how this test first failed. `waitForExistence` on an element that already exists is
        // the suite's idiom for spacing out a poll without `sleep`.
        var after = before
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, after == before {
            _ = requestDetail.path.waitForExistence(timeout: 0.3)
            after = requestDetail.shownPath()
        }
        XCTAssertNotEqual(
            after,
            before,
            "The down arrow should move the selection to the next row and show it in the inspector"
        )

        workspace.serverToggleButton.click()
    }

    // MARK: - 25. Import Menu Opens HAR Import Sheet

    @MainActor
    func testImportMenuOpensHARSheet() throws {
        launchApp()
        createProjectViaUI(name: "HAR Import Test")
        workspace.compactWindow()
        // At the smallest CI window size AppKit moves the whole editor group into its own
        // toolbar overflow. Expand enough to test the app's Import action rather than that
        // system overflow's presentation.
        if !workspace.overflowMenu.exists { workspace.fillWindow() }

        // Import menu button should exist in toolbar
        XCTAssertTrue(workspace.importMenuButton.waitForExistence(timeout: 5),
                      "Import menu button should exist in toolbar")

        workspace.importMenuButton.click()

        // Click HAR import menu item
        let harMenuItem = workspace.importHARMenuItem
        XCTAssertTrue(harMenuItem.waitForExistence(timeout: 3),
                      "Import HAR menu item should exist")
        harMenuItem.click()

        // HAR import sheet should appear with empty state
        XCTAssertTrue(harImportPage.emptyHeading.waitForExistence(timeout: 5),
                      "HAR import should show empty state initially")

        // Dismiss via Escape
        app.typeKey(.escape, modifierFlags: [])

        let sheetDismissed = harImportPage.emptyHeading.waitForNonExistence(timeout: 3)
        XCTAssertTrue(sheetDismissed, "HAR import sheet should dismiss on escape")
    }

    // MARK: - 26. Import Menu Opens OpenAPI Import Sheet

    @MainActor
    func testImportMenuOpensOpenAPISheet() throws {
        launchApp()
        createProjectViaUI(name: "OpenAPI Import Test")
        workspace.compactWindow()
        if !workspace.overflowMenu.exists { workspace.fillWindow() }

        workspace.importMenuButton.click()

        // Click OpenAPI import menu item
        let openAPIMenuItem = workspace.importOpenAPIMenuItem
        XCTAssertTrue(openAPIMenuItem.waitForExistence(timeout: 3),
                      "Import OpenAPI menu item should exist")
        openAPIMenuItem.click()

        // OpenAPI import sheet should appear with empty state
        XCTAssertTrue(openAPIImportPage.emptyHeading.waitForExistence(timeout: 5),
                      "OpenAPI import should show empty state initially")

        // Dismiss via Escape
        app.typeKey(.escape, modifierFlags: [])

        let sheetDismissed = openAPIImportPage.emptyHeading.waitForNonExistence(timeout: 3)
        XCTAssertTrue(sheetDismissed, "OpenAPI import sheet should dismiss on escape")
    }

    // MARK: - 27. Custom Project Port Persists After Reopen

    @MainActor
    func testCustomProjectPortPersistsAfterCloseAndReopen() throws {
        let customPort = 62084

        launchApp()
        createProjectViaUI(name: "Port Persist Test", port: customPort)

        XCTAssertTrue(workspace.assertVisible())
        // Let the create-time save settle before closing; the reopened-server-URL check below is the
        // authoritative verification that the custom port persisted.
        waitForAsyncSave()

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "Port Persist Test")
        XCTAssertNotNil(recentElement, "Project should appear in recents")
        recentElement!.click()

        XCTAssertTrue(workspace.assertVisible())
        XCTAssertTrue(workspace.serverToggleButton.waitForExistence(timeout: 5),
                      "Server toggle button should be visible after reopening the project")

        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: customPort),
            "Starting the reopened project should use the persisted custom port"
        )

        workspace.serverToggleButton.click()
    }

    // MARK: - 28. Endpoint Status Code Persists After Reopen

    @MainActor
    func testEndpointStatusCodePersistsAfterCloseAndReopen() throws {
        launchApp()
        createProjectViaUI(name: "Status Persist Test")
        createEndpointViaUI(name: "Auth Endpoint", path: "/api/auth")

        XCTAssertTrue(endpointEditor.statusCodeField.waitForExistence(timeout: 5),
                      "Status code field should be visible in editor")

        endpointEditor.statusCodeField.click()
        endpointEditor.statusCodeField.typeKey("a", modifierFlags: .command)
        endpointEditor.statusCodeField.typeText("401")

        XCTAssertTrue(
            endpointEditor.waitForStatusCodeValue("401", timeout: 5),
            "Status code field should update to 401"
        )

        // Kept, but no longer for the reason it was written. Closing used to *drop* a not-yet-saved
        // edit — `ProjectWorkspace.closeProject()` cleared `currentProject`, and the pending
        // debounced write then woke, found the guard false, and returned having saved nothing. It now
        // flushes the pending edit first, capturing the project by value, so this wait is no longer
        // load-bearing.
        //
        // It stays because it costs nothing and because what this test is *for* is the round trip
        // through the store, not the flush: waiting here means a failure below says "the store lost
        // it" rather than "something about the timing". `Tests/MimicTests/ProjectWorkspaceTests.swift`
        // covers the flush itself, without the debounce in the way.
        waitForAsyncSave()

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible())

        let recentElement = welcome.findRecentProject(named: "Status Persist Test")
        XCTAssertNotNil(recentElement, "Project should appear in recents")
        recentElement!.click()

        XCTAssertTrue(workspace.assertVisible())

        let endpointPath = workspace.endpointPathText("/api/auth")
        XCTAssertTrue(endpointPath.waitForExistence(timeout: 5),
                      "Persisted endpoint should be visible in the sidebar after reopening")
        endpointPath.click()

        XCTAssertTrue(endpointEditor.statusCodeField.waitForExistence(timeout: 5))
        XCTAssertEqual(endpointEditor.statusCodeField.value as? String, "401",
                       "Reopened endpoint should preserve the edited 401 status code")
    }

    // MARK: - 29. Project, Endpoint and Journey Survive a Fresh App Process

    @MainActor
    func testProjectEndpointAndJourneySurviveAppRelaunch() throws {
        let projectName = "Relaunch Persist Test"
        let endpointPath = "/api/relaunch"
        let journeyName = "Relaunch journey"

        launchApp()
        createProjectViaUI(name: projectName)
        createEndpointViaUI(name: "Relaunch endpoint", path: endpointPath)
        let journeys = JourneysNavigatorPage(app: app)
        WorkspaceShellPage(app: app).journeysTab.click()
        XCTAssertTrue(journeys.addButton.waitForExistence(timeout: 5))
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()
        let newJourney = NewJourneySheetPage(app: app)
        XCTAssertTrue(newJourney.nameField.waitForExistence(timeout: 5))
        newJourney.nameField.click()
        newJourney.nameField.typeText(journeyName)
        newJourney.createButton.click()
        XCTAssertTrue(journeys.journeyRow(named: journeyName).waitForExistence(timeout: 5))
        waitForAsyncSave()

        app.terminate()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 10), "The first app process should exit")

        // Keep the same MIMIC_DEFAULTS_SUITE and test-owned database. Only remove the reset flag:
        // a second reset would erase the very project this fresh-process check must recover.
        app.launchArguments.removeAll { $0 == "-MimicResetForTesting" }
        XCTAssertTrue(
            UITestApp.launchAndBringToForeground(app) { self.workspace.assertVisible(timeout: 1) },
            "A new app process should restore the project from the test database"
        )

        let title = workspace.projectTitle
        XCTAssertTrue(title.waitForExistence(timeout: 5), "The restored workspace should name its project")
        XCTAssertTrue(
            title.label == projectName || (title.value as? String) == projectName,
            "The restored project should be the one saved before quitting"
        )
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(
            workspace.endpointPathText(endpointPath).waitForExistence(timeout: 5),
            "The endpoint should survive closing and reopening the SQLite database"
        )
        WorkspaceShellPage(app: app).journeysTab.click()
        XCTAssertTrue(
            journeys.journeyRow(named: journeyName).waitForExistence(timeout: 5),
            "The journey should survive closing and reopening the SQLite database"
        )
    }

    // MARK: - 30. Evidence Screenshots

    /// Walks the core journey and captures labelled screenshots as verification evidence.
    /// PNGs are written under the UI runner's temporary `mimic-screenshots` directory and attached
    /// to the xcresult.
    @MainActor
    func testCaptureEvidenceScreenshots() throws {
        launchApp()
        captureEvidenceScreenshot("01-welcome")

        createProjectViaUI(name: "Mimic Demo", port: 8472)
        XCTAssertTrue(workspace.assertVisible())
        captureEvidenceScreenshot("02-empty-workspace")

        // Editor + inspector (default scenario shown on the right) in one populated view.
        createEndpointViaUI(name: "List Users", path: "/api/v1/users")
        captureEvidenceScreenshot("03-endpoint-and-inspector")

        endpointEditor.statusCodeField.click()
        endpointEditor.statusCodeField.typeKey("a", modifierFlags: .command)
        endpointEditor.statusCodeField.typeText("200")
        XCTAssertTrue(endpointEditor.waitForStatusCodeValue("200", timeout: 3),
                      "The response edit must be visible before capturing its screenshot")
        captureEvidenceScreenshot("04-response-configured")

        XCTAssertTrue(workspace.serverToggleButton.waitForExistence(timeout: 5))
        workspace.serverToggleButton.click()
        XCTAssertTrue(workspace.waitForServerURL(port: 8472, timeout: 8),
                      "The server must actually bind before its screenshot is labelled running")
        XCTAssertEqual(workspace.serverToggleButton.label, "Stop server")
        captureEvidenceScreenshot("05-server-running")

        workspace.serverToggleButton.click()
    }

    /// Captures a screenshot to the xcresult (always works) and to a guaranteed-writable temp
    /// directory, printing each path to the test log so it can be collected after the run.
    @MainActor
    private func captureEvidenceScreenshot(_ name: String) {
        let shot = app.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mimic-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        do {
            try shot.pngRepresentation.write(to: url)
            print("MIMIC_SHOT \(url.path)")
        } catch {
            print("MIMIC_SHOT_FAIL \(name): \(error)")
        }
    }

}
