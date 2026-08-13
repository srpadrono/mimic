import XCTest
import AppKit
import Foundation

// MARK: - Page Objects (xcuitest-pro pattern)

/// Page object for the journeys navigator — the sidebar's second tab.
///
/// Journeys used to have a window of their own as well as this tab, which meant one feature with two
/// homes and no way to tell which was authoritative. The window is gone; this drives what is left.
@MainActor
struct JourneysNavigatorPage {
    let app: XCUIApplication

    /// The main window. There is no longer a journeys window to distinguish it from.
    var window: XCUIElement { app.windows.firstMatch }

    /// The navigator's tab, matched by **label**.
    ///
    /// Its identifier does not survive: `DSTabStrip` pairs its own identifier with
    /// `.accessibilityElement(children: .contain)`, and that keeps children as their own elements
    /// with their own labels and values but *not* their own identifiers — dumped from
    /// `app.debugDescription`, all three of the strip's buttons report `ds.tabstrip.navigator`. The
    /// label comes from `NavigatorTab.journeys.help`.
    var tab: XCUIElement { app.buttons["Show journeys"].firstMatch }

    /// The navigator's add control, matched by **its own label** — which nothing else carries.
    ///
    /// This used to match on label *and element type*, and the element type was the half doing the
    /// separating. Dumped from `app.debugDescription` back then, with the Journeys tab showing and
    /// no journeys yet, the two controls read:
    ///
    /// ```
    /// MenuButton, identifier: 'ds.tabstrip.navigator',   label: 'Add journey'   ← this one
    /// Button,     identifier: 'ds.empty.journeys.empty', label: 'Add journey'   ← the empty state
    /// ```
    ///
    /// Same words on two controls that do different things: this one opens a chooser, the empty
    /// state's adds a journey outright — so a query that resolved to the wrong one would wait
    /// forever for a menu item that never appears. `MenuButton` versus `Button` separated them, and
    /// that is a property of `DSIconMenu`'s *menu style*, not of either control. It made a
    /// deprecated modifier unmovable: change the style and this query silently changes what it
    /// finds. The labels are distinct now — "Choose how to add a journey" here,
    /// `JourneyNavigatorList`'s "Add journey" there — and each says what its control does.
    ///
    /// The identifier is still no use: `DSTabStrip` flattens its children's, so the
    /// `journeys.addJourneyButton` set on the menu reports as the strip's own name. The element
    /// type is now only a *locator*, and it is tried both ways for the reason
    /// `RequestDetailPage.tab(_:)` gives — so that a style change breaks nothing here. Today
    /// `DSIconMenu` still takes `.menuStyle(.borderlessButton)`, which AppKit realizes as a
    /// `MenuButton`, and the first branch is the one that answers.
    var addButton: XCUIElement {
        let byMenuButton = app.menuButtons["Choose how to add a journey"].firstMatch
        if byMenuButton.exists { return byMenuButton }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Choose how to add a journey"))
            .firstMatch
    }

    /// The empty state's own call to action, which creates a journey outright rather than opening
    /// the menu above. `DSEmptyState` speaks its visible title as the button's label.
    var emptyStateAddButton: XCUIElement { app.buttons["Add journey"].firstMatch }

    var newEmptyMenuItem: XCUIElement { app.menuItems["journeys.newEmptyMenuItem"] }
    var templateMenuItem: XCUIElement { app.menuItems["journeys.templateMenuItem"] }

    /// The navigator's empty state. `DSEmptyState` prefixes what it is given, and the navigator's
    /// list passes `journeys.empty` where the deleted window passed `journeys.list`.
    var emptyStateHeading: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ds.empty.journeys.empty").firstMatch
    }

    var editorName: XCUIElement { app.staticTexts["journeyEditor.name"] }
    var activeBadge: XCUIElement { app.staticTexts["journeyEditor.activeBadge"] }
    var addStepButton: XCUIElement { app.buttons["journeyEditor.addStepButton"] }
    var stepList: XCUIElement { app.tables["journeyEditor.stepList"].firstMatch }

    var activateButton: XCUIElement { app.buttons["journeyRun.activateButton"] }
    var deactivateButton: XCUIElement { app.buttons["journeyRun.deactivateButton"] }
    var restartButton: XCUIElement { app.buttons["journeyRun.restartButton"] }
    var advanceButton: XCUIElement { app.buttons["journeyRun.advanceButton"] }
    var progressLabel: XCUIElement { app.staticTexts["journeyRun.progress"] }

    func journeyRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label CONTAINS %@", name))
            .firstMatch
    }

    func step(at index: Int) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journeyStep-\(index)").firstMatch
    }

    @discardableResult
    func waitUntilVisible(timeout: TimeInterval = 10) -> Bool {
        UITestApp.waitForAny(
            [addButton, emptyStateHeading, editorName],
            timeout: timeout
        )
    }
}

/// Page object for the built-in template picker.
@MainActor
struct JourneyTemplatePickerPage {
    let app: XCUIApplication

    var list: XCUIElement { app.tables["journeyTemplate.list"].firstMatch }
    var activateToggle: XCUIElement { app.checkBoxes["journeyTemplate.activateToggle"] }
    var addButton: XCUIElement { app.buttons["journeyTemplate.addButton"] }
    var cancelButton: XCUIElement { app.buttons["journeyTemplate.cancelButton"] }

    func template(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "journeyTemplate-\(id)").firstMatch
    }
}

/// Page object for the new-journey sheet.
@MainActor
struct NewJourneySheetPage {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["newJourney.nameField"] }
    var createButton: XCUIElement { app.buttons["newJourney.createButton"] }
    var cancelButton: XCUIElement { app.buttons["newJourney.cancelButton"] }
}

/// Page object for the add/edit step sheet.
@MainActor
struct JourneyStepSheetPage {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["stepSheet.nameField"] }
    var pathField: XCUIElement { app.textFields["stepSheet.pathField"] }
    var statusField: XCUIElement { app.textFields["stepSheet.statusField"] }
    var holdField: XCUIElement { app.textFields["stepSheet.holdField"] }
    var outcomePicker: XCUIElement { app.radioGroups["stepSheet.outcomePicker"].firstMatch }
    var saveButton: XCUIElement { app.buttons["stepSheet.saveButton"] }
    var cancelButton: XCUIElement { app.buttons["stepSheet.cancelButton"] }
    var validationMessage: XCUIElement { app.staticTexts["stepSheet.validationMessage"] }
}

// MARK: - Tests

/// UI coverage for journeys: authoring a sequence, activating it, and reading the run back.
///
/// Journeys live in the sidebar's second navigator. These drive the menu command rather than clicking
/// the tab, because the menu is the path a keyboard user and a script both take — and it is the hop
/// through `AppState.navigatorRequest` that changed when the separate journeys window was removed.
final class JourneyUITests: XCTestCase {

    private var app: XCUIApplication!
    private var welcome: WelcomePage!
    private var newProjectSheet: NewProjectSheetPage!
    private var workspace: WorkspacePage!
    private var journeys: JourneysNavigatorPage!
    private var templatePicker: JourneyTemplatePickerPage!
    private var newJourneySheet: NewJourneySheetPage!
    private var stepSheet: JourneyStepSheetPage!

    private static let testSuite = "com.devxa.Mimic.UITests"

    override func setUpWithError() throws {
        continueAfterFailure = false
        UserDefaults(suiteName: Self.testSuite)?.removePersistentDomain(forName: Self.testSuite)
    }

    override func tearDownWithError() throws {
        app = nil
        welcome = nil
        newProjectSheet = nil
        workspace = nil
        journeys = nil
        templatePicker = nil
        newJourneySheet = nil
        stepSheet = nil
    }

    @MainActor
    private func launchWithProject(named name: String = "Journey Tests") {
        let application = XCUIApplication()
        application.launchArguments = [
            "-MimicResetForTesting",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        application.launchEnvironment["MIMIC_DEFAULTS_SUITE"] = Self.testSuite
        // Port 0 lets the OS pick, so a test run neither collides with a developer's running instance
        // nor with a second run on the same machine.
        application.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"

        app = application
        welcome = WelcomePage(app: application)
        newProjectSheet = NewProjectSheetPage(app: application)
        workspace = WorkspacePage(app: application)
        journeys = JourneysNavigatorPage(app: application)
        templatePicker = JourneyTemplatePickerPage(app: application)
        newJourneySheet = NewJourneySheetPage(app: application)
        stepSheet = JourneyStepSheetPage(app: application)

        XCTAssertTrue(
            UITestApp.launchAndBringToForeground(app) { self.welcome.assertVisible(timeout: 1) },
            "Welcome screen should appear once the app is frontmost"
        )

        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 5))
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText(name)
        newProjectSheet.createButton.click()
        XCTAssertTrue(workspace.assertVisible(timeout: 10), "Workspace should appear")
    }

    /// Switches the navigator to its Journeys tab, via the menu command that used to open a window.
    ///
    /// Driven from the menu bar rather than by clicking the tab, deliberately: it exercises the
    /// `navigatorRequest` hop that Journeys ▸ Show Journeys and ⌘2 both go through, which is the part
    /// that changed when the window was removed. Clicking the tab directly would leave that untested.
    @MainActor
    private func showJourneysNavigator() {
        let menuBar = app.menuBars.firstMatch
        XCTAssertTrue(menuBar.waitForExistence(timeout: 5), "Menu bar should exist")

        let journeysMenu = menuBar.menuBarItems["Journeys"]
        XCTAssertTrue(journeysMenu.waitForExistence(timeout: 5), "Journeys menu should exist")
        journeysMenu.click()

        let showItem = app.menuItems["Show Journeys"]
        XCTAssertTrue(showItem.waitForExistence(timeout: 5), "Show Journeys item should exist")
        showItem.click()

        XCTAssertTrue(journeys.waitUntilVisible(), "Journeys navigator should appear in the sidebar")
    }

    @MainActor
    private func addTemplate(_ id: String, activate: Bool) {
        journeys.addButton.click()
        XCTAssertTrue(journeys.templateMenuItem.waitForExistence(timeout: 5))
        journeys.templateMenuItem.click()

        XCTAssertTrue(templatePicker.addButton.waitForExistence(timeout: 5), "Template picker should open")

        let row = templatePicker.template(id)
        if row.waitForExistence(timeout: 3) {
            row.click()
        }

        // The toggle defaults to on; only click when the caller wants the other state.
        if !activate, templatePicker.activateToggle.exists,
           templatePicker.activateToggle.value as? Int == 1 {
            templatePicker.activateToggle.click()
        }
        templatePicker.addButton.click()
    }

    // MARK: - Tests

    @MainActor
    func testJourneysNavigatorShowsItsEmptyState() throws {
        launchWithProject()
        showJourneysNavigator()

        XCTAssertTrue(
            journeys.emptyStateHeading.waitForExistence(timeout: 5),
            "A project with no journeys should explain what a journey is"
        )

        // Both ways of adding a journey are on screen in this state, and they are asserted together
        // because they used to answer to the same name — "Add journey" on the navigator's menu and
        // on the empty state's button — which left this suite separating them by AppKit element
        // type. Each query names one label and nothing else, so the two resolving at once *is* the
        // assertion that they are still two names on two controls: give either control the other's
        // label and one of these two queries stops matching anything at all.
        XCTAssertTrue(journeys.addButton.exists, "The navigator's add menu should be available")
        XCTAssertTrue(
            journeys.emptyStateAddButton.exists,
            "The empty state should offer its own way to create a journey"
        )
    }

    @MainActor
    func testAddJourneyFromTemplateListsItsStepsInOrder() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: false)

        XCTAssertTrue(
            journeys.editorName.waitForExistence(timeout: 10),
            "The new journey should be selected and shown"
        )
        XCTAssertTrue(journeys.addStepButton.waitForExistence(timeout: 5))

        // Four steps, in run order — the sequence is the feature.
        for index in 0..<4 {
            XCTAssertTrue(
                journeys.step(at: index).waitForExistence(timeout: 5),
                "Step \(index) should be listed"
            )
        }
    }

    @MainActor
    func testActivatingAJourneyEnablesRunControls() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: false)

        XCTAssertTrue(journeys.activateButton.waitForExistence(timeout: 10), "Activate should be offered")
        XCTAssertFalse(journeys.restartButton.isEnabled, "Restart is meaningless before activation")

        journeys.activateButton.click()

        // 10s, not 5. Activating is not a view-local toggle: it mutates the project, schedules a
        // save, and hands the journey to the engine before the button can swap. Waiting less for the
        // *result* of an action than for the affordance that triggers it (10s, on the line above)
        // was the imbalance that made this the one journey test that failed under load.
        XCTAssertTrue(
            journeys.deactivateButton.waitForExistence(timeout: 10),
            "Activating should offer to deactivate"
        )
        XCTAssertTrue(journeys.activeBadge.waitForExistence(timeout: 10), "The journey should read as active")
        XCTAssertTrue(journeys.restartButton.isEnabled, "Restart should now be available")
        XCTAssertTrue(journeys.advanceButton.isEnabled, "Advance should now be available")
    }

    @MainActor
    func testDeactivatingReturnsToEndpointOnlyServing() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: true)

        XCTAssertTrue(journeys.deactivateButton.waitForExistence(timeout: 10), "Should start active")
        journeys.deactivateButton.click()

        XCTAssertTrue(
            journeys.activateButton.waitForExistence(timeout: 5),
            "Deactivating should offer to activate again"
        )
        XCTAssertFalse(journeys.restartButton.isEnabled, "Run controls should be disabled again")
    }

    @MainActor
    func testCreateEmptyJourneyAndAddAStepByHand() throws {
        launchWithProject()
        showJourneysNavigator()

        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()

        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5), "New journey sheet should open")
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText("Hand written")
        newJourneySheet.createButton.click()

        XCTAssertTrue(journeys.addStepButton.waitForExistence(timeout: 10), "Editor should appear")
        journeys.addStepButton.click()

        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5), "Step sheet should open")
        stepSheet.pathField.click()
        stepSheet.pathField.typeText("/account-summary")
        stepSheet.statusField.click()
        stepSheet.statusField.typeKey("a", modifierFlags: .command)
        stepSheet.statusField.typeText("500")
        stepSheet.saveButton.click()

        XCTAssertTrue(
            journeys.step(at: 0).waitForExistence(timeout: 5),
            "The new step should appear in the sequence"
        )
    }

    @MainActor
    func testStepSheetRejectsAPathWithoutALeadingSlash() throws {
        launchWithProject()
        showJourneysNavigator()

        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()
        XCTAssertTrue(newJourneySheet.nameField.waitForExistence(timeout: 5))
        newJourneySheet.nameField.click()
        newJourneySheet.nameField.typeText("Validation")
        newJourneySheet.createButton.click()

        XCTAssertTrue(journeys.addStepButton.waitForExistence(timeout: 10))
        journeys.addStepButton.click()
        XCTAssertTrue(stepSheet.pathField.waitForExistence(timeout: 5))

        stepSheet.pathField.click()
        stepSheet.pathField.typeText("no-leading-slash")
        stepSheet.saveButton.click()

        XCTAssertTrue(
            stepSheet.validationMessage.waitForExistence(timeout: 5),
            "An invalid path should be explained rather than silently accepted"
        )
        XCTAssertTrue(stepSheet.pathField.exists, "The sheet should stay open so the path can be fixed")
    }

    @MainActor
    func testJourneysSurviveClosingAndReopeningTheProject() throws {
        launchWithProject()
        showJourneysNavigator()
        addTemplate("payment-retry", activate: false)
        XCTAssertTrue(journeys.editorName.waitForExistence(timeout: 10))

        // ⌘W used to close the journeys *window*, so this test only ever proved a window could be
        // reopened. With one home for journeys it closes the project, which makes the assertion the
        // stronger one the name always claimed: the journey lives in the store, so it has to survive
        // the project being closed and opened again — not merely a tab being switched away from.
        // File ▸ Close Project, by name. Not ⌘W: that is AppKit's close-the-window, which used to
        // reach the journeys window and close *that*. And not the "Close" item beside it, which is
        // the same AppKit command — "Close Project" is the app's own, and it is the one that returns
        // you to the welcome window rather than disposing of the window you are in.
        app.menuBars.firstMatch.menuBarItems["File"].click()
        let closeItem = app.menuItems["Close Project"]
        XCTAssertTrue(closeItem.waitForExistence(timeout: 5), "File ▸ Close Project should exist")
        closeItem.click()
        XCTAssertTrue(welcome.assertVisible(), "Closing the project should return to the welcome window")

        let projectRow = welcome.findRecentProject(named: "Journey Tests")
        XCTAssertNotNil(projectRow, "The project should still be listed after closing it")
        projectRow?.click()
        XCTAssertTrue(workspace.assertVisible(), "The project should reopen")

        showJourneysNavigator()
        XCTAssertFalse(
            journeys.emptyStateHeading.exists,
            "The empty state should not reappear once a journey exists"
        )

        // The navigator does not auto-select, exactly as the endpoints tab does not — so the journey
        // has to be clicked before the editor shows it.
        journeys.journeyRow(named: "Payment succeeds on retry").click()
        XCTAssertTrue(
            journeys.editorName.waitForExistence(timeout: 10),
            "The journey should still be there after the project is closed and reopened"
        )
    }
}
