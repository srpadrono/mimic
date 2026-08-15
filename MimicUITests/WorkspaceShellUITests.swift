import AppKit
import Foundation
import Network
import XCTest

// MARK: - Page Objects

/// Page object for the jump bar above the centre pane.
///
/// Every query here is type-agnostic on purpose. A crumb with options is a SwiftUI `Menu` styled
/// `.button` + `.plain`, which AppKit realizes as a `MenuButton` or a `PopUpButton` depending on the
/// style; a crumb with none is a combined element built from an `Image` and a `Text`. Both carry the
/// same `breadcrumb.crumb.<level>` identifier, so matching on the identifier across `.any` is the one
/// locator that survives either realization — which is also the difference BREAD-12 is about.
///
/// The identifiers do reach the tree here: `BreadcrumbJumpBar` pairs its container name with
/// `.accessibilityElement(children: .contain)` and — unlike `DSTabStrip` or `DSPanelHeader` — does not
/// flatten its leaves, because each crumb forms its own element before the bar names itself.
@MainActor
struct BreadcrumbPage {
    let app: XCUIApplication

    var bar: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "breadcrumb").firstMatch
    }

    /// One level of the path — `project`, `group`, `endpoint`, `scenario` or `journey`.
    func crumb(_ level: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "breadcrumb.crumb.\(level)")
            .firstMatch
    }

    /// What a crumb is currently saying, as one string, for a failure message.
    ///
    /// Label *and* value, because which of the two a crumb carries its title in depends on how
    /// SwiftUI realized it — the rule `RequestDetailPage.shownPath()` already records for the
    /// inspector's path.
    func crumbDescription(_ level: String) -> String {
        let element = crumb(level)
        guard element.exists else { return "<absent>" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "label: \(element.label), value: \(value)"
    }

    @discardableResult
    func waitForCrumb(_ level: String, toRead title: String, timeout: TimeInterval = 8) -> Bool {
        let element = crumb(level)
        return UITestApp.waitUntil(timeout: timeout) {
            element.label == title || (element.value as? String) == title
        }
    }

    var back: XCUIElement { historyButton("breadcrumb.back") }
    var forward: XCUIElement { historyButton("breadcrumb.forward") }

    private func historyButton(_ identifier: String) -> XCUIElement {
        let byButton = app.buttons[identifier].firstMatch
        if byButton.exists { return byButton }
        return app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// Opens a crumb's menu and picks one of its options.
    ///
    /// Both spellings of the option are polled together, never chained: the *selected* option's
    /// accessibility label reads "<name>, selected" while every other one reads just the name, and
    /// `a.waitForExistence(t) || b.waitForExistence(t)` would spend the whole of `a`'s timeout before
    /// so much as looking at `b` — rule 9 of the UI Definition of Done.
    func jump(
        from level: String,
        to optionTitle: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let crumbElement = crumb(level)
        XCTAssertTrue(
            crumbElement.waitForExistence(timeout: 5),
            "The \(level) crumb should be on the jump bar",
            file: file,
            line: line
        )
        crumbElement.click()

        let plain = app.menuItems[optionTitle]
        let selected = app.menuItems["\(optionTitle), selected"]
        XCTAssertTrue(
            UITestApp.waitForAny([plain, selected], timeout: 5),
            "The \(level) crumb's menu should offer \"\(optionTitle)\"",
            file: file,
            line: line
        )
        if plain.exists {
            plain.click()
        } else {
            selected.click()
        }
    }
}

/// Page object for the inspector's project overview.
///
/// `InspectorOverview` pairs `inspector.overview` with `.accessibilityElement(children: .contain)`,
/// so the rows, the notes and the one button keep their own names. Before that pairing every
/// descendant reported the container's identifier, which is why nothing in the suite could address
/// them.
@MainActor
struct InspectorOverviewPage {
    let app: XCUIApplication

    var container: XCUIElement { named("inspector.overview") }

    /// A label/value row: `status`, `port`, `endpoints`, `scenarios`, `journeys`, `name`,
    /// `progress`, `requests` or `unmatched`. The row combines its two texts into one element, so
    /// the label carries both halves.
    func row(_ name: String) -> XCUIElement { named("inspector.overview.\(name)") }

    var noActiveJourneyNote: XCUIElement { named("inspector.overview.activeJourney.none") }
    var unmatchedNote: XCUIElement { named("inspector.overview.unmatched.note") }

    /// The overview's "Show journeys" button.
    ///
    /// Matched by identifier first, and that matters here more than anywhere else in this file: the
    /// navigator's Journeys tab carries the *same words* as its accessibility label, so a bare
    /// `app.buttons["Show journeys"]` is ambiguous exactly when this button is on screen. The
    /// fallback is scoped inside the overview container so it still cannot resolve to the tab.
    var showJourneysButton: XCUIElement {
        let byIdentifier = app.descendants(matching: .any)
            .matching(identifier: "inspector.overview.openJourneys")
            .firstMatch
        if byIdentifier.exists { return byIdentifier }
        return container.descendants(matching: .button)
            .matching(NSPredicate(format: "label == %@", "Show journeys"))
            .firstMatch
    }

    @discardableResult
    func waitForRow(_ name: String, toContain text: String, timeout: TimeInterval = 8) -> Bool {
        let element = row(name)
        guard element.waitForExistence(timeout: timeout) else { return false }
        return UITestApp.waitUntil(timeout: timeout) {
            element.label.contains(text) || (element.value as? String)?.contains(text) == true
        }
    }

    func rowDescription(_ name: String) -> String {
        let element = row(name)
        guard element.exists else { return "<absent>" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "label: \(element.label), value: \(value)"
    }

    private func named(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

/// Page object for the toolbar's centre well.
///
/// The well pairs its identifier with `.contain`, so the address and the two counts keep their own
/// names. Each of them states what it means through `.accessibilityLabel` rather than through the
/// glyph-and-digit it draws, so the assertions here read labels — "server stopped", "2 requests
/// logged", "1 unmatched request, show it" — rather than the abbreviated text on screen.
@MainActor
struct ServerStatusWellPage {
    let app: XCUIApplication

    var well: XCUIElement { named("serverStatusWell") }
    var address: XCUIElement { named("serverStatusWell.url") }
    var requestCount: XCUIElement { named("serverStatusWell.requestCount") }
    var unmatchedBadge: XCUIElement { named("serverStatusWell.unmatched") }

    func spoken(_ element: XCUIElement) -> String {
        guard element.exists else { return "<absent>" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "label: \(element.label), value: \(value)"
    }

    private func named(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

/// Page object for the window's four panels and the navigator's tab strip.
@MainActor
struct WorkspaceShellPage {
    let app: XCUIApplication

    /// One of the four panel containers: `sidebar`, `centerPane`, `inspector`, `drawer`.
    ///
    /// All four are named *and* paired with `.contain`, so the container itself is an element and its
    /// contents keep their identifiers. Matched across element types because which AppKit role a
    /// SwiftUI container lands on is not something this suite should depend on.
    func panel(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    var endpointsTab: XCUIElement { navigatorTab(labelled: "Show endpoints") }
    var journeysTab: XCUIElement { navigatorTab(labelled: "Show journeys") }

    /// A navigator tab, matched by label **and** pinned to the strip.
    ///
    /// The label alone is what `JourneysNavigatorPage.tab` uses, and it is enough right up until the
    /// inspector's overview offers its own "Show journeys" button — then `firstMatch` picks whichever
    /// the tree listed first. The identifier half removes that coin flip: `DSTabStrip` stamps
    /// `ds.tabstrip.navigator` over its buttons, and the per-tab name it passes down is kept as an
    /// alternative in case a future SwiftUI stops flattening it.
    private func navigatorTab(labelled label: String) -> XCUIElement {
        app.buttons.matching(
            NSPredicate(
                format: "label == %@ AND (identifier == %@ OR identifier == %@ OR identifier == %@)",
                label,
                "ds.tabstrip.navigator",
                "navigator.tab.endpoints",
                "navigator.tab.journeys"
            )
        ).firstMatch
    }
}

/// Page object for the menu bar.
///
/// Menus are opened before their items are read. AppKit populates a menu — and validates its items —
/// when it opens, so `isEnabled` on an item of a closed menu is not an answer about anything; every
/// assertion about a disabled command in this file therefore opens the menu first.
@MainActor
struct MimicMenuBarPage {
    let app: XCUIApplication

    func menu(_ title: String) -> XCUIElement {
        app.menuBars.firstMatch.menuBarItems[title]
    }

    @discardableResult
    func open(_ title: String, file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let item = menu(title)
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("The \(title) menu should be in the menu bar", file: file, line: line)
            return false
        }
        item.click()
        return true
    }

    /// An item of a named menu, scoped to it.
    ///
    /// Scoping is not decoration: View ▸ Journeys and the Journeys menu carry the same word, so a
    /// bare `app.menuItems["Journeys"]` is a query with two candidates.
    func item(_ title: String, in menuTitle: String) -> XCUIElement {
        menu(menuTitle).menuItems[title]
    }

    func close() {
        app.typeKey(.escape, modifierFlags: [])
    }
}

// MARK: - Tests

/// The window's shell: the jump bar, the panels and their toggles, the toolbar's server well, the
/// inspector's overview, and the menu-bar commands that drive all of them.
///
/// These are the surfaces the original suite reaches *through* rather than at — it starts servers by
/// clicking the toolbar's power button and switches navigators by clicking a tab, but never asserted
/// that the menu command, the key equivalent or the breadcrumb does the same job. Each test here
/// drives one of those alternate paths and asserts the state it is supposed to produce.
final class WorkspaceShellUITests: MimicUITestCase {

    private var breadcrumb: BreadcrumbPage!
    private var overview: InspectorOverviewPage!
    private var well: ServerStatusWellPage!
    private var shell: WorkspaceShellPage!
    private var menuBar: MimicMenuBarPage!
    private var journeys: JourneysNavigatorPage!
    private var templatePicker: JourneyTemplatePickerPage!

    /// Whether this run's store should refuse every write.
    ///
    /// Set by the one test whose subject is a failed save, *before* `launchShell()`: the environment
    /// binds at process spawn, so a key set from a test body after launch reaches nothing. The gate
    /// on the app's side is `UITestSupport.projectRepositoryFailingWritesIfRequested`, which requires
    /// a UI-test run as well as this key.
    private var failsProjectWrites = false

    private static let failProjectWritesKey = "MIMIC_FAIL_PROJECT_WRITES"

    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Port 0 lets the OS pick the control plane's port, so a run collides neither with a
        // developer's running instance nor with a second run on the same machine. `JourneyUITests`
        // exports the same thing for the same reason.
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
        if failsProjectWrites {
            app.launchEnvironment[Self.failProjectWritesKey] = "1"
        }
    }

    override func tearDownWithError() throws {
        breadcrumb = nil
        overview = nil
        well = nil
        shell = nil
        menuBar = nil
        journeys = nil
        templatePicker = nil
        try super.tearDownWithError()
    }

    // MARK: - Harness

    /// Launches through the inherited contract, then builds this suite's own page objects.
    ///
    /// They cannot be built in `setUp`: `app` is created inside `launchApp()`, so a page object made
    /// before it would hold `nil`.
    @MainActor
    private func launchShell() {
        launchApp()
        breadcrumb = BreadcrumbPage(app: app)
        overview = InspectorOverviewPage(app: app)
        well = ServerStatusWellPage(app: app)
        shell = WorkspaceShellPage(app: app)
        menuBar = MimicMenuBarPage(app: app)
        journeys = JourneysNavigatorPage(app: app)
        templatePicker = JourneyTemplatePickerPage(app: app)
    }

    @MainActor
    @discardableResult
    private func waitForLabel(
        _ element: XCUIElement,
        toRead text: String,
        timeout: TimeInterval = 8
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) { element.label == text }
    }

    @MainActor
    @discardableResult
    private func waitForLabel(
        _ element: XCUIElement,
        toContain text: String,
        timeout: TimeInterval = 10
    ) -> Bool {
        UITestApp.waitUntil(timeout: timeout) {
            element.label.localizedCaseInsensitiveContains(text)
                || (element.value as? String)?.localizedCaseInsensitiveContains(text) == true
        }
    }

    /// Switches the navigator by clicking its tab.
    ///
    /// `JourneyUITests` deliberately goes through the menu instead, to exercise the
    /// `navigatorRequest` hop; the tab is the other path, and the one SHELL-08 is about.
    @MainActor
    private func showJourneysNavigator() {
        let tab = shell.journeysTab
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "The navigator should offer a Journeys tab")
        tab.click()
        XCTAssertTrue(journeys.waitUntilVisible(), "The journeys navigator should appear in the sidebar")
    }

    /// Adds a built-in template journey, optionally activating it as it lands.
    @MainActor
    private func addTemplate(_ id: String, activate: Bool) {
        journeys.addButton.click()
        XCTAssertTrue(
            journeys.templateMenuItem.waitForExistence(timeout: 5),
            "The navigator's add menu should offer templates"
        )
        journeys.templateMenuItem.click()

        XCTAssertTrue(templatePicker.addButton.waitForExistence(timeout: 5), "Template picker should open")

        let row = templatePicker.template(id)
        if row.waitForExistence(timeout: 3) {
            row.click()
        }

        // The toggle defaults to on; only click it when the caller wants the other state.
        if !activate, templatePicker.activateToggle.exists,
           templatePicker.activateToggle.value as? Int == 1 {
            templatePicker.activateToggle.click()
        }
        templatePicker.addButton.click()
    }

    /// Types a group tag into the editor and commits it with Return.
    ///
    /// The field commits on submit or on losing focus — never on every keystroke — so a test that
    /// only typed would assert against a value the endpoint never received.
    @MainActor
    private func setGroupTag(_ tag: String) {
        let field = endpointEditor.groupTagField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The editor should offer a group tag field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(tag)
        field.typeKey(.return, modifierFlags: [])
        waitForAsyncSave()
    }

    /// Starts the mock server from the toolbar and waits for the well to report its address.
    @MainActor
    private func startServer(onPort port: Int) {
        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "The server should report its base URL once running"
        )
    }

    /// Holds a TCP port from the test process, so the app's bind fails the way a busy machine's does.
    ///
    /// A real listener rather than a fault injected into the app: the port-conflict alert exists to
    /// report `EADDRINUSE` from the kernel, and a hook that faked the error would prove only that the
    /// hook works.
    @MainActor
    private func occupyPort(_ port: Int) throws -> NWListener {
        let endpointPort = try XCTUnwrap(
            NWEndpoint.Port(rawValue: UInt16(port)),
            "\(port) should be a valid TCP port"
        )
        let listener = try NWListener(using: .tcp, on: endpointPort)
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in connection.cancel() }
        listener.start(queue: .global())

        XCTAssertEqual(
            ready.wait(timeout: .now() + 5),
            .success,
            "The test process should be holding port \(port) before the app tries to bind it"
        )
        return listener
    }

    /// How many distinct rows the request log is showing, polled rather than read once.
    ///
    /// Written as a loop rather than through `UITestApp.waitUntil`, because counting rows means
    /// calling a page object from inside the closure; `waitForRowCount` polls the same way for the
    /// same reason.
    @MainActor
    private func waitForDistinctRowCount(_ count: Int, timeout: TimeInterval = 8) -> Int {
        var found = requestLogDrawer.distinctRows(limit: count + 2).count
        let deadline = Date().addingTimeInterval(timeout)
        while found != count, Date() < deadline {
            _ = requestLogDrawer.firstLogRow.waitForExistence(timeout: 0.3)
            found = requestLogDrawer.distinctRows(limit: count + 2).count
        }
        return found
    }

    // MARK: - 1. Shell: the window and its four panels

    /// SHELL-03, SHELL-18.
    ///
    /// The four container identifiers have been declared on `WorkspacePage` since the panels were
    /// built and no test ever asserted one — the layout test checks their *contents'* empty-state
    /// text instead, which passes just as well if a container loses its name and takes every child
    /// identifier down with it.
    @MainActor
    func testWorkspaceShellNamesItsWindowAndFourPanels() throws {
        launchShell()
        createProjectViaUI(name: "Shell Layout")

        XCTAssertTrue(
            app.windows["Shell Layout"].waitForExistence(timeout: 5),
            "The window title should follow the open project's name"
        )

        for identifier in ["sidebar", "centerPane", "inspector", "drawer"] {
            XCTAssertTrue(
                shell.panel(identifier).waitForExistence(timeout: 5),
                "\(identifier) should be an addressable panel container"
            )
        }
    }

    /// SHELL-06, SHELL-08.
    @MainActor
    func testNavigatorTabStripSwitchesTheNavigatorAndCentrePane() throws {
        launchShell()
        createProjectViaUI(name: "Tab Strip")

        XCTAssertTrue(shell.journeysTab.waitForExistence(timeout: 5), "The strip should offer both tabs")
        shell.journeysTab.click()

        // `DSEmptyState` flattens its leaves, so the heading's own identifier never lands — the
        // container's name and the visible words are the two handles, polled together.
        XCTAssertTrue(
            UITestApp.waitForAny(
                [
                    app.staticTexts["No journey selected"],
                    app.descendants(matching: .any)
                        .matching(identifier: "ds.empty.center.noJourneySelection")
                        .firstMatch,
                ],
                timeout: 5
            ),
            "The centre pane should explain that no journey is selected"
        )
        XCTAssertTrue(
            journeys.emptyStateHeading.waitForExistence(timeout: 5),
            "The navigator should have switched to the journeys list"
        )

        shell.endpointsTab.click()
        XCTAssertTrue(
            workspace.centerEmptyHeading.waitForExistence(timeout: 5),
            "The centre pane should go back to the endpoint empty state"
        )
        XCTAssertTrue(
            workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
            "The navigator should go back to the endpoints list"
        )
    }

    // MARK: - 2. The breadcrumb jump bar

    /// BREAD-01, BREAD-02, BREAD-09, BREAD-12.
    @MainActor
    func testJumpBarNamesTheProjectAndHasNowhereToGoYet() throws {
        launchShell()
        createProjectViaUI(name: "Jump Bar")

        XCTAssertTrue(
            breadcrumb.crumb("project").waitForExistence(timeout: 5),
            "The jump bar should start with a project crumb"
        )
        XCTAssertTrue(
            breadcrumb.waitForCrumb("project", toRead: "Jump Bar"),
            "The head of the path should name the project — \(breadcrumb.crumbDescription("project"))"
        )
        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "No endpoint"),
            "With nothing selected the endpoint crumb should say so — "
                + breadcrumb.crumbDescription("endpoint")
        )

        // BREAD-09 — nothing has been visited, so neither arrow has anywhere to go.
        let back = breadcrumb.back
        let forward = breadcrumb.forward
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The jump bar should offer a back arrow")
        XCTAssertTrue(forward.exists, "The jump bar should offer a forward arrow")
        XCTAssertFalse(back.isEnabled, "Back should be disabled with no history to walk")
        XCTAssertFalse(forward.isEnabled, "Forward should be disabled with no history to walk")

        // BREAD-12 — a crumb with nowhere to go is rendered as plain text rather than as a pressable
        // menu, and the difference surfaces as the element's *type*. Asserted as a negative because
        // that is what the rule is; it is not vacuous, because the two assertions above have already
        // established that this identifier resolves to an element reading "No endpoint".
        for type in [XCUIElement.ElementType.menuButton, .popUpButton, .button] {
            let asControl = app.descendants(matching: type)
                .matching(identifier: "breadcrumb.crumb.endpoint")
                .firstMatch
            XCTAssertFalse(
                asControl.exists,
                "A crumb with no siblings to offer should not be a pressable control"
            )
        }
    }

    /// BREAD-03.
    @MainActor
    func testEndpointCrumbJumpsToASibling() throws {
        launchShell()
        createProjectViaUI(name: "Siblings")
        createEndpointViaUI(name: "Get users", path: "/api/users")
        createEndpointViaUI(name: "Get posts", path: "/api/posts")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "Get posts"),
            "The jump bar should name the endpoint just created — "
                + breadcrumb.crumbDescription("endpoint")
        )

        breadcrumb.jump(from: "endpoint", to: "Get users")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "Get users"),
            "Choosing a sibling should move the selection — \(breadcrumb.crumbDescription("endpoint"))"
        )

        let pathLabel = endpointEditor.pathLabel
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                pathLabel.label.contains("/api/users")
                    || (pathLabel.value as? String)?.contains("/api/users") == true
            },
            "The editor should follow the jump bar to the sibling endpoint"
        )
    }

    /// BREAD-04.
    ///
    /// The group crumb is conditional — it renders only when the project has more than one non-empty
    /// group tag — so the test has to build that state before it can assert on it.
    @MainActor
    func testGroupCrumbJumpsToAnotherGroup() throws {
        launchShell()
        createProjectViaUI(name: "Groups")

        createEndpointViaUI(name: "Get users", path: "/api/users")
        setGroupTag("Accounts")
        createEndpointViaUI(name: "Get orders", path: "/api/orders")
        setGroupTag("Checkout")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("group", toRead: "Checkout"),
            "A second group should give the path a group crumb — \(breadcrumb.crumbDescription("group"))"
        )

        breadcrumb.jump(from: "group", to: "Accounts")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("group", toRead: "Accounts"),
            "The group crumb should follow the jump — \(breadcrumb.crumbDescription("group"))"
        )
        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "Get users"),
            "A group option stands for the first endpoint in it — "
                + breadcrumb.crumbDescription("endpoint")
        )
    }

    /// BREAD-05, INSPOV-13.
    @MainActor
    func testScenarioCrumbSwitchesTheActiveScenario() throws {
        launchShell()
        createProjectViaUI(name: "Scenarios")
        createEndpointViaUI(name: "Get users", path: "/api/users")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("scenario", toRead: "Default"),
            "A new endpoint answers with its default scenario — "
                + breadcrumb.crumbDescription("scenario")
        )

        // INSPOV-13 — the inspector header's "+", by label. Its identifier
        // (`inspector.addScenarioButton`) sits in a `DSPanelHeader` accessory slot, which stamps
        // `ds.panelheader.inspector` over its descendants. Queried before the sheet opens on
        // purpose: the sheet's confirm button answers to the same words.
        let addScenario = app.buttons["Add scenario"].firstMatch
        XCTAssertTrue(
            addScenario.waitForExistence(timeout: 5),
            "The Scenarios header should offer a way to add one"
        )
        addScenario.click()

        XCTAssertTrue(
            newScenarioSheet.nameField.waitForExistence(timeout: 5),
            "Adding a scenario should ask for its name first"
        )
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText("Unauthorized")
        newScenarioSheet.createButton.click()

        let addedRow = inspector.scenarioRow(named: "Unauthorized")
        XCTAssertTrue(
            addedRow.waitForExistence(timeout: 5),
            "The new scenario should be listed in the inspector"
        )
        // Adding one does not activate it — the endpoint already had an active scenario — so the
        // crumb is still on the default, and the jump below is a real switch rather than a no-op.
        XCTAssertTrue(
            breadcrumb.waitForCrumb("scenario", toRead: "Default"),
            "Adding a scenario should not switch to it — \(breadcrumb.crumbDescription("scenario"))"
        )

        breadcrumb.jump(from: "scenario", to: "Unauthorized")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("scenario", toRead: "Unauthorized"),
            "The scenario crumb should name the scenario now answering — "
                + breadcrumb.crumbDescription("scenario")
        )
        // `, active` rather than `active`: the row's *value* is "inactive" when it is not, which
        // contains the shorter string. The spoken label is the half that only says it when true.
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                addedRow.label.localizedCaseInsensitiveContains(", active")
            },
            "The inspector should agree that the scenario is the active one"
        )
    }

    /// BREAD-06.
    @MainActor
    func testJourneyCrumbJumpsToAnotherJourney() throws {
        launchShell()
        createProjectViaUI(name: "Journey Jump")
        showJourneysNavigator()

        addTemplate("retry-after-failure", activate: false)
        XCTAssertTrue(journeys.editorName.waitForExistence(timeout: 10), "The first journey should open")
        addTemplate("payment-retry", activate: false)

        XCTAssertTrue(
            breadcrumb.waitForCrumb("journey", toRead: "Payment succeeds on retry"),
            "On the Journeys tab the path names the selected journey — "
                + breadcrumb.crumbDescription("journey")
        )

        breadcrumb.jump(from: "journey", to: "Retry after failure")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("journey", toRead: "Retry after failure"),
            "The journey crumb should move the selection — \(breadcrumb.crumbDescription("journey"))"
        )
        let editorName = journeys.editorName
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) {
                editorName.label.contains("Retry after failure")
                    || (editorName.value as? String)?.contains("Retry after failure") == true
            },
            "The centre pane should be editing the journey the crumb jumped to"
        )
    }

    /// BREAD-07, BREAD-08.
    @MainActor
    func testJumpBarHistoryWalksBackAndForward() throws {
        launchShell()
        createProjectViaUI(name: "History")
        createEndpointViaUI(name: "First", path: "/api/first")
        createEndpointViaUI(name: "Second", path: "/api/second")

        let back = breadcrumb.back
        let forward = breadcrumb.forward

        XCTAssertTrue(breadcrumb.waitForCrumb("endpoint", toRead: "Second"), "The second endpoint is current")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { back.isEnabled },
            "Two endpoints visited is a history worth walking"
        )
        XCTAssertFalse(forward.isEnabled, "Nothing has been walked back from yet")

        back.click()
        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "First"),
            "Back should return to the endpoint viewed before — "
                + breadcrumb.crumbDescription("endpoint")
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { forward.isEnabled },
            "Having gone back, forward should now be available"
        )

        forward.click()
        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "Second"),
            "Forward should return to the endpoint that was left — "
                + breadcrumb.crumbDescription("endpoint")
        )
    }

    /// BREAD-10.
    @MainActor
    func testSelectingAfterGoingBackDiscardsTheForwardStack() throws {
        launchShell()
        createProjectViaUI(name: "Forward Stack")
        createEndpointViaUI(name: "First", path: "/api/first")
        createEndpointViaUI(name: "Second", path: "/api/second")
        createEndpointViaUI(name: "Third", path: "/api/third")

        let back = breadcrumb.back
        let forward = breadcrumb.forward

        XCTAssertTrue(breadcrumb.waitForCrumb("endpoint", toRead: "Third"), "The third endpoint is current")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { back.isEnabled }, "There is history to walk")

        back.click()
        XCTAssertTrue(breadcrumb.waitForCrumb("endpoint", toRead: "Second"), "Back should land on the second")
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { forward.isEnabled },
            "Forward should be available before a new visit discards it"
        )

        breadcrumb.jump(from: "endpoint", to: "First")

        XCTAssertTrue(
            breadcrumb.waitForCrumb("endpoint", toRead: "First"),
            "The jump should move the selection — \(breadcrumb.crumbDescription("endpoint"))"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { !forward.isEnabled },
            "A new visit should throw away everything ahead of the cursor"
        )
        XCTAssertTrue(back.isEnabled, "The way back should survive the truncation")
    }

    /// BREAD-11.
    @MainActor
    func testReselectingTheSameEndpointStacksNoHistory() throws {
        launchShell()
        createProjectViaUI(name: "No Duplicates")
        createEndpointViaUI(name: "Only", path: "/api/only")

        let back = breadcrumb.back
        XCTAssertTrue(back.waitForExistence(timeout: 5), "The jump bar should offer a back arrow")
        XCTAssertFalse(back.isEnabled, "One endpoint visited is not a history")

        // Re-picking the endpoint you are already on, twice. Its own option is the only one the
        // crumb offers, and it reads "<name>, selected".
        breadcrumb.jump(from: "endpoint", to: "Only")
        XCTAssertTrue(breadcrumb.waitForCrumb("endpoint", toRead: "Only"), "The selection should not move")
        breadcrumb.jump(from: "endpoint", to: "Only")

        XCTAssertFalse(
            back.isEnabled,
            "Re-selecting the endpoint you are on must not stack a duplicate history entry"
        )
    }

    // MARK: - 3. The inspector's overview

    /// INSPOV-01, INSPOV-02, INSPOV-03, INSPOV-04.
    @MainActor
    func testInspectorOverviewAnswersForTheProject() throws {
        launchShell()
        createProjectViaUI(name: "Overview", port: 62111)

        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "With nothing selected the inspector should show the project overview"
        )
        XCTAssertTrue(
            overview.container.waitForExistence(timeout: 5),
            "The overview's body should be addressable"
        )

        XCTAssertTrue(
            overview.waitForRow("status", toContain: "Stopped"),
            "The Server section should report the state — \(overview.rowDescription("status"))"
        )
        XCTAssertTrue(
            overview.waitForRow("port", toContain: "62111"),
            "…and the port it would answer on — \(overview.rowDescription("port"))"
        )
        XCTAssertTrue(
            overview.waitForRow("endpoints", toContain: "0"),
            "A new project has no endpoints — \(overview.rowDescription("endpoints"))"
        )
        XCTAssertTrue(
            overview.waitForRow("scenarios", toContain: "0"),
            "…no scenarios — \(overview.rowDescription("scenarios"))"
        )
        XCTAssertTrue(
            overview.waitForRow("journeys", toContain: "0"),
            "…and no journeys — \(overview.rowDescription("journeys"))"
        )

        XCTAssertTrue(
            overview.noActiveJourneyNote.waitForExistence(timeout: 5),
            "With no journey running the overview should say endpoints answer directly"
        )
    }

    /// INSPOV-07, INSPOV-16, INSPOV-17, SRVWELL-08, SRVWELL-09.
    ///
    /// A project with no endpoints at all, so every request is unmatched *and* nothing is selected —
    /// which is the only state in which the inspector's multi-selection fallback is observable. With
    /// an endpoint selected the panel falls back to that endpoint's scenarios instead, and a test
    /// that asserted "Overview" there would be asserting the wrong rule.
    @MainActor
    func testOverviewReportsUnmatchedTrafficAndSurvivesAMultiRowSelection() async throws {
        let port = 62112

        launchShell()
        createProjectViaUI(name: "Unmatched", port: port)
        startServer(onPort: port)

        await sendRequest(port: port, path: "/api/missing", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/other", method: "GET", body: nil)

        XCTAssertTrue(
            requestLogDrawer.waitForRowCount(2, timeout: 15),
            "Both requests should reach the log"
        )

        // SRVWELL-08 / SRVWELL-09 — the well counts what arrived and warns about what nothing
        // answered. Both state their meaning in their accessibility label rather than in the digit
        // they draw.
        XCTAssertTrue(well.requestCount.waitForExistence(timeout: 5), "The well should show a request count")
        XCTAssertTrue(
            waitForLabel(well.requestCount, toContain: "2 requests logged"),
            "The count should follow the traffic — \(well.spoken(well.requestCount))"
        )
        XCTAssertTrue(
            well.unmatchedBadge.waitForExistence(timeout: 5),
            "Requests nothing answered should raise the unmatched badge"
        )
        XCTAssertTrue(
            waitForLabel(well.unmatchedBadge, toContain: "2 unmatched requests"),
            "The badge should say how many — \(well.spoken(well.unmatchedBadge))"
        )

        // INSPOV-07 — and the overview says the same thing in words.
        XCTAssertTrue(
            overview.waitForRow("unmatched", toContain: "2"),
            "The overview should count the unmatched calls — \(overview.rowDescription("unmatched"))"
        )
        XCTAssertTrue(
            overview.unmatchedNote.waitForExistence(timeout: 5),
            "…and explain what an unmatched call is"
        )

        // INSPOV-16 — one row is a request to inspect; several are not.
        let rows = requestLogDrawer.distinctRows(limit: 2)
        XCTAssertEqual(rows.count, 2, "Both requests should be listed as separate rows")
        rows[0].click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Selecting one row should show it in the inspector"
        )
        XCUIElement.perform(withKeyModifiers: .command) {
            rows[1].click()
        }
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "A selection of several requests is not one request, so the panel falls back"
        )

        // INSPOV-17 — clearing the log takes the detail with it.
        rows[0].click()
        XCTAssertTrue(requestDetail.waitForPanelTitle("Request"), "Back to a single selection")

        // By label: the clear button lives in the drawer's `DSPanelHeader`, which stamps its own
        // identifier over its accessory's.
        let clearLog = app.buttons["Clear request log"].firstMatch
        XCTAssertTrue(clearLog.waitForExistence(timeout: 5), "The log should offer a way to clear it")
        clearLog.click()

        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "A cleared log should not leave the inspector showing a request that is gone"
        )
    }

    /// INSPOV-05, INSPOV-06, SHELL-09.
    @MainActor
    func testOverviewShowsTheActiveJourneyAndSwitchesTheNavigator() throws {
        launchShell()
        createProjectViaUI(name: "Active Journey")
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: true)

        // Nothing is selected in the endpoints navigator, so the inspector is still the overview —
        // the mode the active-journey rows live in.
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Overview"),
            "The inspector should still be showing the project overview"
        )
        XCTAssertTrue(
            overview.waitForRow("name", toContain: "Retry after failure"),
            "The overview should name the journey that is overriding the endpoints — "
                + overview.rowDescription("name")
        )
        XCTAssertTrue(
            overview.waitForRow("progress", toContain: "Step 1 of 4"),
            "…and where the run has got to — \(overview.rowDescription("progress"))"
        )
        XCTAssertTrue(
            overview.waitForRow("journeys", toContain: "1"),
            "…and count the journeys the project now has — \(overview.rowDescription("journeys"))"
        )

        // SHELL-09 — the tab badges the running journey. `DSTabStrip` puts the count in the button's
        // accessibility value, not in a separate element.
        let journeysTab = shell.journeysTab
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 8) { (journeysTab.value as? String) == "1" },
            "The Journeys tab should badge the active journey"
        )

        // INSPOV-06 — from the other tab, the overview's button is the way back.
        shell.endpointsTab.click()
        XCTAssertTrue(
            workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
            "The navigator should be showing endpoints again"
        )

        let showJourneys = overview.showJourneysButton
        XCTAssertTrue(
            showJourneys.waitForExistence(timeout: 5),
            "The overview should offer a way to reach the running journey"
        )
        showJourneys.click()

        XCTAssertTrue(
            journeys.waitUntilVisible(),
            "Show journeys should switch the navigator to its Journeys tab"
        )
    }

    /// INSPOV-10, INSPOV-11, INSPOV-12.
    @MainActor
    func testInspectorTrafficTabListsTheEndpointsRequests() async throws {
        let port = 62113

        launchShell()
        createProjectViaUI(name: "Endpoint Traffic", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")
        startServer(onPort: port)

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)

        XCTAssertTrue(
            requestLogDrawer.waitForRowCount(2, timeout: 15),
            "Both requests should reach the log"
        )

        // The tab is a leaf inside a `DSTabStrip` nested in a `DSPanelHeader` — two containers, each
        // of which stamps its own identifier over its children — so the label is the only handle.
        let trafficTab = app.buttons["Show the requests this endpoint answered"].firstMatch
        XCTAssertTrue(
            trafficTab.waitForExistence(timeout: 5),
            "The inspector should offer a Traffic tab for the selected endpoint"
        )
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { (trafficTab.value as? String) == "2" },
            "The tab should badge how many requests this endpoint answered"
        )

        trafficTab.click()
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Traffic"),
            "The header should follow the tab"
        )

        let trafficRow = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "endpointTraffic.row."))
            .firstMatch
        XCTAssertTrue(
            trafficRow.waitForExistence(timeout: 5),
            "The traffic list should show the requests this endpoint answered"
        )
        trafficRow.click()

        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "Clicking a traffic row should open it in the request detail"
        )
    }

    // MARK: - 4. The toolbar's server well

    /// SRVWELL-01, SRVWELL-04.
    @MainActor
    func testServerWellReportsItsStateAndCopiesTheAddress() throws {
        let port = 62114
        let expected = "http://localhost:\(port)"

        launchShell()
        createProjectViaUI(name: "Status Well", port: port)

        XCTAssertTrue(well.address.waitForExistence(timeout: 5), "The well should be showing something")
        XCTAssertTrue(
            waitForLabel(well.address, toContain: "server stopped"),
            "Before anything is started the well should say so — \(well.spoken(well.address))"
        )

        _ = NSPasteboard.general.clearContents()
        startServer(onPort: port)
        well.address.click()

        // Polled rather than read once: the copy happens on the app's main actor and the pasteboard
        // is a system-wide handoff, so the runner can observe it a moment later. The bounded
        // `waitForExistence` is the same poll-pause `RequestLogDrawerPage.waitForRowCount` uses.
        var copied = NSPasteboard.general.string(forType: .string)
        let deadline = Date().addingTimeInterval(5)
        while copied != expected, Date() < deadline {
            _ = well.address.waitForExistence(timeout: 0.2)
            copied = NSPasteboard.general.string(forType: .string)
        }
        XCTAssertEqual(
            copied,
            expected,
            "Clicking the address should copy the base URL, scheme and all"
        )
    }

    /// SRVWELL-10.
    @MainActor
    func testUnmatchedBadgeOpensTheLogFilteredToUnmatched() async throws {
        let port = 62115

        launchShell()
        createProjectViaUI(name: "Unmatched Badge", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")
        startServer(onPort: port)

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        await sendRequest(port: port, path: "/api/nothing-answers-this", method: "GET", body: nil)

        XCTAssertTrue(
            requestLogDrawer.waitForRowCount(2, timeout: 15),
            "One matched and one unmatched request should both be logged"
        )

        // Collapsed first, so the badge has to open the panel as well as filter it.
        workspace.toggleDrawerButton.click()
        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForNonExistence(timeout: 5),
            "The request log should be hidden before the badge is clicked"
        )

        XCTAssertTrue(well.unmatchedBadge.waitForExistence(timeout: 5), "The badge should be in the well")
        well.unmatchedBadge.click()

        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForExistence(timeout: 5),
            "The badge should reopen the request log"
        )
        XCTAssertEqual(
            waitForDistinctRowCount(1),
            1,
            "…showing only the request that nothing answered"
        )
    }

    /// SRVRUN-04, SRVRUN-05, SRVRUN-06, SRVWELL-07.
    ///
    /// Both alert buttons are matched by identifier *or* label. The identifier is the stable handle
    /// the window deliberately added — "Try port 62117" interpolates the arithmetic under test — and
    /// the label is kept as a fallback so a query cannot silently find nothing.
    @MainActor
    func testStartingOnAnOccupiedPortOffersTheNextPort() throws {
        let port = 62116
        let listener = try occupyPort(port)
        defer { listener.cancel() }

        launchShell()
        createProjectViaUI(name: "Occupied", port: port)

        let keepStopped = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "portConflict.keepStoppedButton",
                "Keep server stopped"
            )
        ).firstMatch
        let tryNextPort = app.buttons.matching(
            NSPredicate(
                format: "identifier == %@ OR label == %@",
                "portConflict.tryPortButton",
                "Try port \(port + 1)"
            )
        ).firstMatch

        workspace.serverToggleButton.click()

        XCTAssertTrue(
            UITestApp.waitForAny([keepStopped, tryNextPort], timeout: 20),
            "A port already in use should be reported, not silently swallowed"
        )
        XCTAssertTrue(tryNextPort.exists, "The alert should offer the next port along")

        // SRVRUN-06 — declining leaves the server where it is, with the failure still stated.
        keepStopped.click()
        XCTAssertTrue(
            waitForLabel(well.address, toContain: "server error"),
            "Declining should leave the well reporting the failed start — \(well.spoken(well.address))"
        )

        // SRVRUN-05 — accepting the suggestion starts it one port along.
        workspace.serverToggleButton.click()
        XCTAssertTrue(
            tryNextPort.waitForExistence(timeout: 20),
            "The conflict should be reported again on the second attempt"
        )
        tryNextPort.click()

        XCTAssertTrue(
            workspace.waitForServerURL(port: port + 1),
            "Accepting the suggestion should start the server on the next port"
        )
    }

    // MARK: - 5. Menu-bar commands

    /// MENUBAR-06, MENUBAR-07, MENUBAR-08, SRVRUN-08, SRVRUN-10.
    @MainActor
    func testServerMenuStartsStopsAndFlipsItsTitle() throws {
        let port = 62117

        launchShell()
        createProjectViaUI(name: "Server Menu", port: port)

        let toggle = workspace.serverToggleButton
        XCTAssertTrue(toggle.waitForExistence(timeout: 5), "The toolbar should offer the power button")
        XCTAssertTrue(
            waitForLabel(toggle, toRead: "Start server"),
            "Stopped, the power button offers to start — label: \(toggle.label)"
        )

        menuBar.open("Server")
        let startItem = app.menuItems["Start Server"]
        XCTAssertTrue(startItem.waitForExistence(timeout: 5), "Server ▸ Start Server should be listed")
        startItem.click()

        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "Server ▸ Start Server should start the mock"
        )
        XCTAssertTrue(
            waitForLabel(toggle, toRead: "Stop server, running"),
            "Running, the power button announces the other action — label: \(toggle.label)"
        )

        menuBar.open("Server")
        let stopItem = app.menuItems["Stop Server"]
        XCTAssertTrue(
            stopItem.waitForExistence(timeout: 5),
            "The item should read Stop Server while the server is running"
        )
        XCTAssertFalse(
            app.menuItems["Start Server"].exists,
            "The one item flips its title rather than there being two"
        )
        stopItem.click()

        XCTAssertTrue(
            waitForLabel(well.address, toContain: "server stopped"),
            "The menu item should stop the server — \(well.spoken(well.address))"
        )

        // MENUBAR-08 — the accelerator, which no test has ever pressed.
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "⇧⌘R should start the server"
        )
        app.typeKey("r", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            waitForLabel(well.address, toContain: "server stopped"),
            "⇧⌘R again should stop it — \(well.spoken(well.address))"
        )
    }

    /// MENUBAR-02, MENUBAR-04, MENUBAR-05, MENUBAR-09.
    @MainActor
    func testMenuBarGuardsTheCommandsThatNeedAProject() throws {
        launchShell()

        menuBar.open("File")
        let closeProject = app.menuItems["Close Project"]
        XCTAssertTrue(closeProject.waitForExistence(timeout: 5), "File ▸ Close Project should be listed")
        XCTAssertFalse(
            closeProject.isEnabled,
            "Close Project has nothing to close at the welcome window"
        )
        menuBar.close()

        menuBar.open("Server")
        let startServer = app.menuItems["Start Server"]
        XCTAssertTrue(startServer.waitForExistence(timeout: 5), "The Server menu should be listed")
        XCTAssertFalse(
            startServer.isEnabled,
            "There is no server to start until a project is open"
        )
        menuBar.close()

        // MENUBAR-02 — ⌘N, which the suite has only ever reached by clicking the item.
        app.typeKey("n", modifierFlags: .command)
        XCTAssertTrue(
            newProjectSheet.nameField.waitForExistence(timeout: 5),
            "⌘N should open the new-project sheet"
        )
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText("Keyboard Driven")
        newProjectSheet.createButton.click()
        XCTAssertTrue(workspace.assertVisible(), "The project should open")

        // MENUBAR-04 — ⇧⌘W, deliberately not ⌘W, which is AppKit's close-the-window.
        app.typeKey("w", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            welcome.assertVisible(),
            "⇧⌘W should close the project and return to the welcome window"
        )
    }

    /// MENUBAR-10, MENUBAR-11, MENUBAR-13.
    @MainActor
    func testViewMenuAndShortcutSwitchNavigators() throws {
        launchShell()
        createProjectViaUI(name: "Navigators")

        menuBar.open("View")
        let journeysItem = menuBar.item("Journeys", in: "View")
        XCTAssertTrue(
            journeysItem.waitForExistence(timeout: 5),
            "View should offer the Journeys navigator"
        )
        journeysItem.click()
        XCTAssertTrue(
            journeys.waitUntilVisible(),
            "View ▸ Journeys should switch the navigator"
        )

        menuBar.open("View")
        let endpointsItem = menuBar.item("Endpoints", in: "View")
        XCTAssertTrue(
            endpointsItem.waitForExistence(timeout: 5),
            "View should offer the Endpoints navigator"
        )
        endpointsItem.click()
        XCTAssertTrue(
            workspace.sidebarEmptyHeading.waitForExistence(timeout: 5),
            "View ▸ Endpoints should switch back"
        )

        // MENUBAR-13 — ⇧⌘J, the second accelerator for the same destination, which must not have
        // been swallowed by ⌘2.
        app.typeKey("j", modifierFlags: [.command, .shift])
        XCTAssertTrue(
            journeys.waitUntilVisible(),
            "⇧⌘J should show the journeys navigator"
        )
    }

    /// MENUBAR-14, MENUBAR-15, MENUBAR-16.
    ///
    /// The panel's own run controls are covered by `JourneyUITests`; these are the menu items beside
    /// them, which nothing has ever driven.
    @MainActor
    func testJourneysMenuDrivesTheActiveJourney() throws {
        launchShell()
        createProjectViaUI(name: "Journey Commands")
        showJourneysNavigator()
        addTemplate("retry-after-failure", activate: true)

        let progress = app.descendants(matching: .any)
            .matching(identifier: "journeyRun.progress")
            .firstMatch
        XCTAssertTrue(
            progress.waitForExistence(timeout: 10),
            "The run strip should report where the journey has got to"
        )
        XCTAssertTrue(
            waitForLabel(progress, toContain: "Step 1 of 4"),
            "A freshly activated journey starts at its first step — label: \(progress.label)"
        )

        menuBar.open("Journeys")
        let advance = app.menuItems["Advance Active Journey"]
        XCTAssertTrue(advance.waitForExistence(timeout: 5), "Journeys ▸ Advance should be listed")
        advance.click()
        XCTAssertTrue(
            waitForLabel(progress, toContain: "Step 2 of 4"),
            "Advancing should retire the current step — label: \(progress.label)"
        )

        menuBar.open("Journeys")
        let restart = app.menuItems["Restart Active Journey"]
        XCTAssertTrue(restart.waitForExistence(timeout: 5), "Journeys ▸ Restart should be listed")
        restart.click()
        XCTAssertTrue(
            waitForLabel(progress, toContain: "Step 1 of 4"),
            "Restarting should rewind the run to the first step — label: \(progress.label)"
        )

        menuBar.open("Journeys")
        let deactivate = app.menuItems["Deactivate Journey"]
        XCTAssertTrue(deactivate.waitForExistence(timeout: 5), "Journeys ▸ Deactivate should be listed")
        deactivate.click()
        XCTAssertTrue(
            journeys.activateButton.waitForExistence(timeout: 10),
            "Deactivating should offer to activate again"
        )
    }

    /// MENUBAR-17.
    @MainActor
    func testJourneyRunCommandsAreDisabledWithoutAnActiveJourney() throws {
        launchShell()
        createProjectViaUI(name: "No Active Journey")

        menuBar.open("Journeys")
        for title in ["Restart Active Journey", "Advance Active Journey", "Deactivate Journey"] {
            let item = app.menuItems[title]
            XCTAssertTrue(item.waitForExistence(timeout: 5), "\(title) should be listed")
            XCTAssertFalse(item.isEnabled, "\(title) should be disabled while nothing is running")
        }
        menuBar.close()
    }

    // MARK: - 6. Panels

    /// PANEL-03, PANEL-04, PANEL-05.
    ///
    /// Both chords appear in no menu — they are bound on the toolbar buttons themselves — so a test
    /// pressing them is the only thing standing between ⌥⌘L/⌥⌘I and being silently unbound.
    @MainActor
    func testPanelChordsTogglePanelsAndFlipTheirLabels() throws {
        launchShell()
        createProjectViaUI(name: "Panel Chords")

        let drawerToggle = workspace.toggleDrawerButton
        let inspectorToggle = workspace.toggleInspectorButton
        XCTAssertTrue(drawerToggle.waitForExistence(timeout: 5), "The toolbar should offer both toggles")
        XCTAssertTrue(inspectorToggle.exists, "The toolbar should offer both toggles")

        // PANEL-05 — the label says which way the toggle goes, and both panels start open.
        XCTAssertTrue(
            waitForLabel(drawerToggle, toRead: "Hide request log"),
            "The log starts open, so its toggle offers to hide it — label: \(drawerToggle.label)"
        )
        XCTAssertTrue(
            waitForLabel(inspectorToggle, toRead: "Hide inspector"),
            "The inspector starts open too — label: \(inspectorToggle.label)"
        )

        // PANEL-03 — ⌥⌘L.
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(
            workspace.drawerEmptyHeading.waitForNonExistence(timeout: 5),
            "⌥⌘L should hide the request log"
        )
        XCTAssertTrue(
            waitForLabel(drawerToggle, toRead: "Show request log"),
            "…and the toggle should flip to offer the other direction — label: \(drawerToggle.label)"
        )
        app.typeKey("l", modifierFlags: [.command, .option])
        XCTAssertTrue(
            workspace.drawerEmptyHeading.waitForExistence(timeout: 5),
            "⌥⌘L again should bring the request log back"
        )

        // PANEL-04 — ⌥⌘I. Asserted through the toggle's label, which is a direct reading of
        // `showInspector`; the collapsed column's own contents are not a reliable witness.
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForLabel(inspectorToggle, toRead: "Show inspector"),
            "⌥⌘I should hide the inspector — label: \(inspectorToggle.label)"
        )
        app.typeKey("i", modifierFlags: [.command, .option])
        XCTAssertTrue(
            waitForLabel(inspectorToggle, toRead: "Hide inspector"),
            "⌥⌘I again should bring it back — label: \(inspectorToggle.label)"
        )
    }

    /// PANEL-09.
    ///
    /// Closing and reopening the project rather than relaunching the app: every launch in this suite
    /// carries `-MimicResetForTesting`, which clears the defaults suite the layout is stored in, so a
    /// relaunch would be asserting against a store the run had just emptied.
    @MainActor
    func testPanelArrangementSurvivesClosingAndReopeningTheProject() throws {
        launchShell()
        createProjectViaUI(name: "Layout Memory")

        workspace.toggleDrawerButton.click()
        XCTAssertTrue(
            workspace.drawerEmptyHeading.waitForNonExistence(timeout: 5),
            "The request log should be hidden before the project is closed"
        )

        closeProjectViaMenu()
        XCTAssertTrue(welcome.assertVisible(), "Closing should return to the welcome window")

        let row = welcome.findRecentProject(named: "Layout Memory")
        XCTAssertNotNil(row, "The project should be listed in recents")
        row?.click()
        XCTAssertTrue(workspace.assertVisible(), "The project should reopen")

        XCTAssertTrue(
            waitForLabel(workspace.toggleDrawerButton, toRead: "Show request log"),
            "The arrangement left behind should be the one restored"
        )
        XCTAssertFalse(
            workspace.drawerEmptyHeading.exists,
            "The request log should still be hidden"
        )
    }

    /// PANEL-11.
    @MainActor
    func testClickingALoggedRequestOpensTheCollapsedInspector() async throws {
        let port = 62118

        launchShell()
        createProjectViaUI(name: "Auto Open", port: port)
        createEndpointViaUI(name: "Users", path: "/api/users")
        startServer(onPort: port)

        await sendRequest(port: port, path: "/api/users", method: "GET", body: nil)
        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForExistence(timeout: 15),
            "The request should reach the log"
        )

        let inspectorToggle = workspace.toggleInspectorButton
        inspectorToggle.click()
        XCTAssertTrue(
            waitForLabel(inspectorToggle, toRead: "Show inspector"),
            "The inspector should be collapsed before the row is clicked"
        )

        requestLogDrawer.firstLogRow.click()

        XCTAssertTrue(
            waitForLabel(inspectorToggle, toRead: "Hide inspector"),
            "Selecting a request should open the inspector rather than looking like it did nothing"
        )
        XCTAssertTrue(
            requestDetail.waitForPanelTitle("Request"),
            "…and show the request that was clicked"
        )
    }

    // MARK: - 7. Autosave

    /// AUTOSAVE-04.
    @MainActor
    func testAutosaveIndicatorClearsOnceTheSaveSettles() throws {
        launchShell()
        createProjectViaUI(name: "Autosave Idle")
        createEndpointViaUI(name: "Users", path: "/api/users")

        // Polled together: `.saving` lasts only as long as a SQLite write and `.saved` clears after
        // two seconds, so waiting out one before looking at the other can miss both.
        XCTAssertTrue(
            UITestApp.waitForAny(
                [workspace.autosaveSavingIndicator, workspace.autosaveSavedIndicator],
                timeout: 10
            ),
            "Adding an endpoint should be saved, and the toolbar should say so"
        )

        XCTAssertTrue(
            workspace.autosaveSavingIndicator.waitForNonExistence(timeout: 10),
            "The saving state should not outlive the write"
        )
        XCTAssertTrue(
            workspace.autosaveSavedIndicator.waitForNonExistence(timeout: 10),
            "The indicator should clear itself once the save has settled"
        )
    }

    /// AUTOSAVE-05.
    ///
    /// The `.failed` arm is the one that reports lost work, and no sequence of clicks can produce it:
    /// every store the app can open is a GRDB queue that succeeds. `MIMIC_FAIL_PROJECT_WRITES` is the
    /// seam that exists for exactly this, and it forwards reads, so the project still opens.
    @MainActor
    func testAutosaveReportsAStoreThatRefusesTheWrite() throws {
        failsProjectWrites = true

        launchShell()
        createProjectViaUI(name: "Refused Writes")

        let failed = app.descendants(matching: .any)
            .matching(identifier: "autosaveStatus.failed")
            .firstMatch
        XCTAssertTrue(
            failed.waitForExistence(timeout: 15),
            "A write the store refused must be reported, not swallowed"
        )
        XCTAssertEqual(
            failed.label,
            "Could not save changes",
            "The indicator should say what happened in words, not only in colour"
        )
    }
}
