import XCTest
import AppKit
import Foundation

// MARK: - Page Objects (xcuitest-pro pattern)

/// Page object for the Welcome screen — centralizes element queries.
@MainActor
struct WelcomePage {
    let app: XCUIApplication

    private var heroTitleByIdentifier: XCUIElement { app.staticTexts["welcomeHeroTitle"] }
    private var heroTitleByLabel: XCUIElement { app.staticTexts["Mimic"].firstMatch }
    private var windowByTitle: XCUIElement { app.windows["Mimic"].firstMatch }
    var newProjectButton: XCUIElement { app.buttons["newProjectButton"] }
    private var noRecentProjectsLabelByIdentifier: XCUIElement { app.staticTexts["noRecentProjectsLabel"] }
    private var noRecentProjectsLabelByLabel: XCUIElement { app.staticTexts["No projects yet"].firstMatch }

    /// All three of these poll their candidates together rather than chaining
    /// `a.waitForExistence(t) || b.waitForExistence(t)`, which is the form rule 9 of the skill
    /// `mimic-ui-tests` forbids.
    ///
    /// It matters most here, because `assertVisible` is the readiness closure every test's launch
    /// runs — up to five times, once per activation attempt. Chained, its three candidates each
    /// waited out the full timeout in turn before the next was so much as queried, so a launch that
    /// came up showing the recent-projects list rather than the new-project button paid three
    /// timeouts per attempt to discover something the second query knew immediately.
    @discardableResult
    func waitForHeroTitle(timeout: TimeInterval) -> Bool {
        UITestApp.waitForAny([heroTitleByIdentifier, heroTitleByLabel], timeout: timeout)
    }

    @discardableResult
    func assertVisible(timeout: TimeInterval = 5) -> Bool {
        UITestApp.waitForAny(
            [
                newProjectButton,
                noRecentProjectsLabelByIdentifier,
                noRecentProjectsLabelByLabel,
                windowByTitle,
            ],
            timeout: timeout
        )
    }

    @discardableResult
    func waitForNoRecentProjectsLabel(timeout: TimeInterval) -> Bool {
        UITestApp.waitForAny(
            [noRecentProjectsLabelByIdentifier, noRecentProjectsLabelByLabel],
            timeout: timeout
        )
    }

    /// Matched by the row's spoken label, not by `recentProject-<name>`.
    ///
    /// That identifier is set on `RecentProjectRow`, and it is not in the tree: the `List` above it
    /// carries `welcome.recents.list`, and while the paired `.contain` keeps each row as its own
    /// element with its own **label and value**, it does not keep its own **identifier** — the
    /// distinction `references/accessibility-tree.md` was written about. Dropping the list's
    /// identifier is not an option either, because focusing the list for the arrow-key tests needs it.
    ///
    /// This mattered beyond a failed lookup. A negative assertion on the old query —
    /// `waitForNonExistence` — passed whether or not the row had gone, because the query could never
    /// match anything. One test was proving nothing for exactly that reason.
    ///
    /// The comma is load-bearing twice: it keeps "Twin" from matching "Twin (Copy)", and it keeps the
    /// match off the row's bare name `Text`, whose label is the name alone and which has no children
    /// for a scoped `staticTexts` query to find.
    func recentProjectRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@", "\(name), last opened"))
            .firstMatch
    }

    func recentProjectText(named name: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(format: "value CONTAINS %@ OR label CONTAINS %@", name, name)
        ).firstMatch
    }

    /// Finds a recent project element by name, trying identifier then text fallback.
    func findRecentProject(named name: String) -> XCUIElement? {
        let byId = recentProjectRow(named: name)
        if byId.waitForExistence(timeout: 5) { return byId }

        let byText = recentProjectText(named: name)
        if byText.waitForExistence(timeout: 3) { return byText }

        return nil
    }
}

/// Page object for the New Project sheet.
@MainActor
struct NewProjectSheetPage {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["projectNameField"] }
    var portField: XCUIElement { app.textFields["serverPortField"] }
    var createButton: XCUIElement { app.buttons["createProjectButton"] }
    var cancelButton: XCUIElement { app.buttons["cancelCreateButton"] }
    /// Matched by the sentence, not by `ds.textfield.newProject.port.error`.
    ///
    /// That identifier is built by `DSTextField.validationRow` and is never in the tree at this call
    /// site, or any other: `NewProjectSheet` names the whole `DSTextField` `serverPortField`, and that
    /// propagation is the point — it is why `app.textFields["serverPortField"]` matches the input at
    /// all. It reaches the validation row too and overwrites the row's own name. The row does set
    /// `.accessibilityElement()` and `.accessibilityLabel(message)`, so the message itself survives,
    /// and the message is what a test wants to assert anyway.
    ///
    /// Making the identifier reachable would mean moving the caller's name onto the inner `TextField`,
    /// which would break `app.textFields["serverPortField"]` and most of this suite's sheet coverage.
    /// That is a trade, not an oversight — hence matching by label rather than "fixing" the field.
    var portValidationError: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                  "Port must be", "Port must be"))
            .firstMatch
    }
}

/// Page object for the Workspace view (4-panel layout — Phase 5).
@MainActor
struct WorkspacePage {
    let app: XCUIApplication

    // Panels
    var sidebar: XCUIElement { app.otherElements["sidebar"] }
    var centerPane: XCUIElement { app.otherElements["centerPane"] }
    var inspector: XCUIElement { app.otherElements["inspector"] }
    var drawer: XCUIElement { app.otherElements["drawer"] }

    // Sidebar empty state — query by text content since accessibility identifiers
    // on Text views inside NavigationSplitView sidebar may not propagate on macOS
    var sidebarEmptyHeading: XCUIElement { app.staticTexts["No endpoints"] }

    // Center pane empty state
    var centerEmptyHeading: XCUIElement { app.staticTexts["No endpoint selected"] }

    // Toolbar
    var serverToggleButton: XCUIElement { app.buttons["serverToggleButton"].firstMatch }
    /// The navigator's add action — matched by **label**, because its identifier does not survive.
    ///
    /// `sidebar.addEndpointButton` is set on the button and never reaches the tree: it lives in
    /// `DSTabStrip`'s accessory slot, and the strip's own `ds.tabstrip.navigator` is stamped over
    /// every descendant. Pairing the container's identifier with `.accessibilityElement(children:
    /// .contain)` does *not* prevent that for a leaf control — it keeps the child as its own element
    /// with its own label and value, which is a different thing, and the distinction is what the
    /// suite kept getting wrong. Dumped from `app.debugDescription`, all three of the strip's buttons
    /// report `ds.tabstrip.navigator` and differ only by label.
    ///
    /// `firstMatch` across both copies is deliberate. When the project is empty, `DSEmptyState` also
    /// offers "Add endpoint" and both call the same action, so either is a correct answer to "open
    /// the new-endpoint sheet". Pinning this to the strip's copy would make every test that adds the
    /// *first* endpoint depend on which of two identical buttons the tree happened to list first.
    var addEndpointButton: XCUIElement { app.buttons["Add endpoint"].firstMatch }
    /// Asserts the removal, so the duplicate cannot come back unnoticed.
    var toolbarAddEndpointButton: XCUIElement {
        app.toolbars.buttons["addEndpointButton"].firstMatch
    }
    /// Likewise: the toolbar's journeys button is gone, the sidebar's Journeys tab replaced it.
    var toolbarJourneysButton: XCUIElement {
        app.toolbars.buttons["journeysToolbarButton"].firstMatch
    }
    /// The Import menu.
    ///
    /// Matched by identifier across element types, because a SwiftUI `Menu` in a toolbar realizes as
    /// a `MenuButton` or a `PopUpButton` depending on how it is placed and `app.buttons[…]` matches
    /// neither. The fallback is app-wide rather than toolbar-scoped for the same reason: this item is
    /// a member of a `ToolbarItemGroup` now, and a grouped item can surface as a child of the group
    /// element rather than as a direct descendant of the toolbar — at which point every query here
    /// would miss it and the failure would read as "Import does nothing".
    var importMenuButton: XCUIElement {
        let inToolbar = app.toolbars.descendants(matching: .any)
            .matching(identifier: "importMenuButton").firstMatch
        if inToolbar.exists { return inToolbar }
        return app.descendants(matching: .any).matching(identifier: "importMenuButton").firstMatch
    }
    var toggleInspectorButton: XCUIElement { app.toolbars.buttons["toggleInspectorButton"].firstMatch }
    var toggleDrawerButton: XCUIElement { app.toolbars.buttons["toggleDrawerButton"].firstMatch }

    // Autosave
    //
    // There is no `autosaveStatusIndicator`. A property of that name used to sit here, querying an
    // identifier that exists nowhere in `Sources` and that no test ever referenced — a dead query,
    // not a missing identifier. The temptation it created was to name the reserved toolbar slot in
    // `WorkspaceView` to make it resolve, which would have been two bugs: a container's identifier
    // overrides its descendants', so the three real names below would have stopped landing, and the
    // slot renders `EmptyView` while idle, so the element would not exist for most of a run. The
    // addressable surface is the state-specific identifiers, one per arm.
    var autosaveSavedIndicator: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "autosaveStatus.saved").firstMatch
    }
    var autosaveSavingIndicator: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "autosaveStatus.saving").firstMatch
    }

    // Drawer empty state
    var drawerEmptyHeading: XCUIElement { app.staticTexts["No requests yet"] }

    func endpointPathText(_ path: String) -> XCUIElement {
        app.staticTexts[path].firstMatch
    }

    /// The base URL element in the toolbar's status well.
    ///
    /// Matched by identifier, not by content. A `CONTAINS` predicate over `descendants(matching:
    /// .any)` scans the whole window and times the query engine out; scoping it to `staticTexts`
    /// then missed it entirely, because while the server is running the text sits inside a
    /// copy-to-clipboard `Button`. Identifier matching is both cheap and indifferent to which.
    func serverURLText(port: Int) -> XCUIElement {
        app.descendants(matching: .any)
            .matching(identifier: "serverStatusWell.url")
            .firstMatch
    }

    func serverURLButton(port: Int) -> XCUIElement {
        serverURLText(port: port)
    }

    /// Waits for the well to report the given port. The port check is a separate step from finding
    /// the element, so a well showing the *wrong* port fails loudly rather than timing out.
    @discardableResult
    func waitForServerURL(port: Int, timeout: TimeInterval = 10) -> Bool {
        let element = serverURLText(port: port)
        guard element.waitForExistence(timeout: timeout) else { return false }
        let shown = ((element.value as? String) ?? "") + " " + element.label
        return shown.contains("localhost:\(port)")
    }

    /// Waits for the workspace to be visible — by its empty state if the project has no endpoints, by
    /// the navigator's add button if it has some.
    ///
    /// Polled together, never `a.waitForExistence(t) || b.waitForExistence(t)`. That form waits out
    /// `a`'s entire timeout before it so much as looks at `b`, so reopening a project that *has* an
    /// endpoint — where the empty heading never appears — burned the full 10s on every call before
    /// succeeding on the second query.
    @discardableResult
    func assertVisible(timeout: TimeInterval = 10) -> Bool {
        UITestApp.waitForAny([sidebarEmptyHeading, addEndpointButton], timeout: timeout)
    }
}

/// Page object for the New Endpoint sheet.
@MainActor
struct NewEndpointSheetPage {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["newEndpoint.nameField"] }
    var methodPicker: XCUIElement { app.popUpButtons["newEndpoint.methodPicker"] }
    var pathField: XCUIElement { app.textFields["newEndpoint.pathField"] }
    var createButton: XCUIElement { app.buttons["newEndpoint.createButton"] }
    var cancelButton: XCUIElement { app.buttons["newEndpoint.cancelButton"] }
    /// The path field's inline validation message.
    ///
    /// Matched by the sentence. Two identifiers have now been wrong here, for different reasons.
    ///
    /// `newEndpoint.pathError` never existed at all. Its replacement,
    /// `ds.textfield.newEndpoint.path.error`, is the name `DSTextField.validationRow` really builds —
    /// and it is still not in the tree, because `NewEndpointSheet` stamps its own identifier on the
    /// whole field and that overwrites the row beneath it. CI proved it: the corrected identifier
    /// found nothing either. What survives is the row's `.accessibilityLabel(message)`, so match that.
    var pathError: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@",
                                  "Path must", "Path must"))
            .firstMatch
    }
}

/// Page object for the Endpoint Editor (center pane).
@MainActor
struct EndpointEditorPage {
    let app: XCUIApplication

    var statusCodeField: XCUIElement { app.textFields["endpointEditor.statusCode"] }
    var delayField: XCUIElement { app.textFields["endpointEditor.delay"] }
    var groupTagField: XCUIElement { app.textFields["endpointEditor.groupTag"] }
    var moreMenu: XCUIElement {
        let byButton = app.buttons["endpointEditor.moreMenu"].firstMatch
        if byButton.exists { return byButton }
        let byPopUp = app.popUpButtons["endpointEditor.moreMenu"].firstMatch
        if byPopUp.exists { return byPopUp }
        return app.descendants(matching: .any).matching(identifier: "endpointEditor.moreMenu").firstMatch
    }
    var addHeaderButton: XCUIElement { app.buttons["endpointEditor.addHeaderButton"] }
    var prettyPrintButton: XCUIElement { app.buttons["endpointEditor.prettyPrintButton"] }
    var pathLabel: XCUIElement {
        let byStaticText = app.staticTexts["endpointEditor.path"].firstMatch
        if byStaticText.exists { return byStaticText }
        return app.descendants(matching: .any).matching(identifier: "endpointEditor.path").firstMatch
    }

    func headerKeyField(at index: Int) -> XCUIElement {
        app.textFields["endpointEditor.headerKey.\(index)"]
    }
    func headerValueField(at index: Int) -> XCUIElement {
        app.textFields["endpointEditor.headerValue.\(index)"]
    }

    @discardableResult
    func waitForStatusCodeValue(_ value: String, timeout: TimeInterval = 5) -> Bool {
        let predicate = NSPredicate(format: "value == %@", value)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: statusCodeField)
        return XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed
    }
}

/// Page object for the Request Log Drawer (Phase 8).
@MainActor
struct RequestLogDrawerPage {
    let app: XCUIApplication

    var filterField: XCUIElement {
        app.descendants(matching: .textField).matching(identifier: "drawer.filterField").firstMatch
    }
    var methodFilter: XCUIElement {
        app.descendants(matching: .popUpButton).matching(identifier: "drawer.methodFilter").firstMatch
    }
    var clearButton: XCUIElement { app.buttons["clearRequestLogButton"] }
    var emptyHeading: XCUIElement { app.staticTexts["No requests yet"] }
    var noMatchesHeading: XCUIElement { app.staticTexts["No matching requests"] }

    func logRow(id: String) -> XCUIElement {
        app.otherElements["requestLog-\(id)"].firstMatch
    }

    /// Any logged row, matched on the identifier prefix.
    ///
    /// A test cannot know a log entry's UUID — the server mints it when the request arrives — and
    /// matching on the rendered path instead would also match the sidebar and the editor, which show
    /// the same string. The prefix is the only unambiguous handle.
    var firstLogRow: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "requestLog-"))
            .firstMatch
    }

    /// Every element carrying a row's identifier — **several per row**, not one.
    ///
    /// A row's `.accessibilityIdentifier` does not stay on the row: SwiftUI flattens it onto each
    /// cell, so this returns six elements for every logged request (method, path, endpoint, scenario,
    /// status, time), all reporting the same `requestLog-<uuid>`. Dumped from `app.debugDescription`:
    ///
    /// ```
    /// Button, identifier: 'requestLog-110693C9…', label: 'GET method'
    /// Button, identifier: 'requestLog-110693C9…', label: '/api/orders'
    /// Button, identifier: 'requestLog-110693C9…', label: 'Unmatched'
    /// ```
    ///
    /// One composed element per logged row. `RequestLogDrawerView` collapses each row with
    /// `.accessibilityElement(children: .ignore)` and a composed spoken label ("GET /api/orders,
    /// status 200"), so a row is a single element carrying the `requestLog-<uuid>` identifier —
    /// which may realize as a Button, hence `.any` rather than a cell query. This used to say the
    /// opposite ("several per row … six elements for every logged request"), from before the rows
    /// composed their labels; ``distinctRows(limit:)``'s dedupe is a no-op now and kept only as
    /// safety against the realization changing again.
    var allRowCells: XCUIElementQuery {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "requestLog-"))
    }

    /// One element per logged row, in the order the table draws them.
    func distinctRows(limit: Int) -> [XCUIElement] {
        var seen: Set<String> = []
        var rows: [XCUIElement] = []
        for index in 0..<allRowCells.count {
            let cell = allRowCells.element(boundBy: index)
            guard seen.insert(cell.identifier).inserted else { continue }
            rows.append(cell)
            if rows.count == limit { break }
        }
        return rows
    }

    /// Waits for the log to hold at least `count` distinct rows.
    ///
    /// Counts distinct identifiers rather than raw elements. With the rows composed into one element
    /// each the two counts agree today, but this helper predates that — rows used to fan out into
    /// several elements, and a single request satisfied `allRowCells.count >= 2` — and counting
    /// distinct ids is the version that stays correct whichever way the realization goes.
    func waitForRowCount(_ count: Int, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if distinctRows(limit: count).count >= count { return true }
            _ = firstLogRow.waitForExistence(timeout: 0.3)
        }
        return distinctRows(limit: count).count >= count
    }
}

/// Page object for the sheet that names a journey captured from traffic.
@MainActor
struct CaptureJourneySheetPage {
    let app: XCUIApplication

    /// `DSTextField` lends its wrapper's identifier to the single field inside it, which is why this
    /// matches a text field rather than a container — the same reason `newJourney.nameField` does.
    var nameField: XCUIElement { app.textFields["captureJourney.nameField"] }
    var createButton: XCUIElement { app.buttons["captureJourney.createButton"] }
    var cancelButton: XCUIElement { app.buttons["captureJourney.cancelButton"] }
}

/// Page object for the request detail shown in the inspector.
@MainActor
struct RequestDetailPage {
    let app: XCUIApplication

    /// The inspector's header title, matched by the container's identifier and the text it carries.
    ///
    /// `DSPanelHeader` sets `ds.panelheader.title.inspector` on the title `Text` and
    /// `ds.panelheader.inspector` on the row around it, and the row's name wins: dumped from
    /// `app.debugDescription`, the header arrives as a single `StaticText` with
    /// `identifier: 'ds.panelheader.inspector', value: Overview`. Pairing the container identifier
    /// with `.accessibilityElement(children: .contain)` does not stop that for a leaf `Text` — it
    /// keeps children as their own elements carrying their own labels and values, which is not the
    /// same as keeping their identifiers. The title's own name never reaches the tree, so a query for
    /// it has no candidates at all. Both are matched anyway, because which one lands is a SwiftUI
    /// implementation detail that has already changed once.
    ///
    /// The text has to be checked as well as the identifier: the identifier is fixed, but this waits
    /// for the panel to *change modes*, and the only thing that distinguishes "Request" from
    /// "Scenarios" is the string.
    func panelTitle(_ title: String) -> XCUIElement {
        app.staticTexts.matching(
            NSPredicate(
                format: "(identifier == %@ OR identifier == %@) AND (value == %@ OR label == %@)",
                "ds.panelheader.inspector", "ds.panelheader.title.inspector", title, title
            )
        ).firstMatch
    }
    var path: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestDetail.path").firstMatch
    }

    /// The path the inspector is currently showing, as one string, for comparing two moments.
    ///
    /// Label *and* value, because which of the two a `StaticText` carries its text in depends on
    /// how SwiftUI realized it — the rule this suite learned from `DSEmptyState`, whose text
    /// arrives as the value. Returns empty when the element is absent, so a caller polling for a
    /// change cannot mistake "gone" for "unchanged".
    func shownPath() -> String {
        let element = path
        guard element.exists else { return "" }
        let value = element.value.map { String(describing: $0) } ?? ""
        return "\(element.label)|\(value)"
    }

    var status: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestDetail.status").firstMatch
    }
    /// Targeted by label, not identifier: the button lives inside `DSPanelHeader`, which stamps its
    /// own identifier over its children's, so `inspector.closeRequestDetailButton` never reaches the
    /// accessibility tree. The label is the stable handle here.
    var closeButton: XCUIElement {
        app.buttons["Back to the endpoint inspector"].firstMatch
    }
    var bodySearchField: XCUIElement {
        app.descendants(matching: .textField).matching(identifier: "requestDetail.bodySearchField").firstMatch
    }
    var copyCurlButton: XCUIElement {
        app.descendants(matching: .button).matching(identifier: "requestDetail.copy.curl").firstMatch
    }
    var copyConfirmation: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestDetail.copyConfirmation").firstMatch
    }
    var responseBody: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestLog.body.response").firstMatch
    }
    var responseBodyMatches: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestLog.body.response.matches").firstMatch
    }

    /// A segment of the Summary/Headers/Body picker.
    ///
    /// A SwiftUI `.segmented` picker realizes as a radio group on macOS, so the segments are
    /// `radioButton`s rather than `button`s — the element type a `app.buttons[…]` query would never
    /// match. Both are tried so a future style change does not silently break every selection.
    func tab(_ title: String) -> XCUIElement {
        let byRadio = app.radioButtons[title].firstMatch
        if byRadio.exists { return byRadio }
        let byButton = app.buttons[title].firstMatch
        if byButton.exists { return byButton }
        return app.descendants(matching: .any).matching(identifier: title).firstMatch
    }

    /// Waits for the inspector's header to read `title` — the signal that the panel switched modes.
    @discardableResult
    func waitForPanelTitle(_ title: String, timeout: TimeInterval = 5) -> Bool {
        panelTitle(title).waitForExistence(timeout: timeout)
    }
}

/// Page object for the Inspector panel (scenarios).
@MainActor
struct InspectorPage {
    let app: XCUIApplication

    var addScenarioButton: XCUIElement {
        // Inspector content on macOS may be in a separate accessibility container.
        // Use descendants query to find the button anywhere.
        app.descendants(matching: .button).matching(identifier: "inspector.addScenarioButton").firstMatch
    }

    func scenarioRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "inspector.scenario.\(name)").firstMatch
    }

    /// Finds scenario row by looking for the text content as fallback.
    func findScenario(named name: String) -> XCUIElement {
        let byId = scenarioRow(named: name)
        if byId.exists { return byId }
        return app.staticTexts[name].firstMatch
    }

    /// Checks if a scenario row's accessibility label contains "active".
    func isScenarioActive(named name: String) -> Bool {
        let row = scenarioRow(named: name)
        guard row.waitForExistence(timeout: 5) else { return false }

        // Compared exactly, not with `contains`. `ScenarioRow` sets its value to "active" or
        // "inactive" and appends ", active" to the spoken label only when the scenario is active —
        // and "inactive" contains "active", so the `contains` pair this replaces returned true for
        // every row it was ever handed. Both call sites assert `XCTAssertTrue`, so the helper could
        // not fail and its two tests were green by construction rather than by evidence.
        let value = (row.value as? String) ?? ""
        return value.caseInsensitiveCompare("active") == .orderedSame
            || row.label.hasSuffix(", active")
    }
}

/// Page object for the New Scenario sheet.
@MainActor
struct NewScenarioSheetPage {
    let app: XCUIApplication

    var nameField: XCUIElement { app.textFields["newScenario.nameField"] }
    var createButton: XCUIElement { app.buttons["newScenario.createButton"] }
    var cancelButton: XCUIElement { app.buttons["newScenario.cancelButton"] }
}

/// Page object for the OpenAPI Import sheet (Phase 10).
@MainActor
struct OpenAPIImportPage {
    let app: XCUIApplication

    var emptyHeading: XCUIElement {
        app.staticTexts["No OpenAPI spec loaded"]
    }
}

/// Page object for the HAR Import sheet (Phase 9).
@MainActor
struct HARImportPage {
    let app: XCUIApplication

    var cancelButton: XCUIElement {
        app.descendants(matching: .button).matching(identifier: "harImport.cancelButton").firstMatch
    }
    var emptyHeading: XCUIElement {
        app.staticTexts["No HAR file loaded"]
    }
    var chooseFileButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Choose HAR file")).firstMatch
    }
    var importButton: XCUIElement {
        app.descendants(matching: .button).matching(identifier: "import.importButton").firstMatch
    }
}

/// Page object for delete confirmation dialog.
@MainActor
struct DeleteConfirmationPage {
    let app: XCUIApplication

    var deleteButton: XCUIElement { app.sheets.firstMatch.buttons["Delete project"] }
    var keepButton: XCUIElement { app.sheets.firstMatch.buttons["Keep project"] }
}

// MARK: - Tests

/// Full end-to-end UI journey tests for Project Management (Phase 3) and Workspace Layout (Phase 5).
///
/// Each test resets state by passing `-MimicResetForTesting` launch argument, which wipes
/// the database and UserDefaults from within the sandboxed app.
final class MimicUITests: XCTestCase {

    private var app: XCUIApplication!
    private var welcome: WelcomePage!
    private var newProjectSheet: NewProjectSheetPage!
    private var workspace: WorkspacePage!
    private var newEndpointSheet: NewEndpointSheetPage!
    private var endpointEditor: EndpointEditorPage!
    private var inspector: InspectorPage!
    private var newScenarioSheet: NewScenarioSheetPage!
    private var deleteConfirmation: DeleteConfirmationPage!
    private var requestLogDrawer: RequestLogDrawerPage!
    private var requestDetail: RequestDetailPage!
    private var harImportPage: HARImportPage!
    private var openAPIImportPage: OpenAPIImportPage!
    private var captureSheet: CaptureJourneySheetPage!

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
        newEndpointSheet = nil
        endpointEditor = nil
        inspector = nil
        newScenarioSheet = nil
        deleteConfirmation = nil
        requestLogDrawer = nil
        requestDetail = nil
        harImportPage = nil
        openAPIImportPage = nil
        captureSheet = nil
    }

    @MainActor
    private func prepareApp() {
        guard app == nil else { return }

        let application = XCUIApplication()
        application.launchArguments = [
            "-MimicResetForTesting",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        application.launchEnvironment["MIMIC_DEFAULTS_SUITE"] = Self.testSuite

        app = application
        welcome = WelcomePage(app: application)
        newProjectSheet = NewProjectSheetPage(app: application)
        workspace = WorkspacePage(app: application)
        newEndpointSheet = NewEndpointSheetPage(app: application)
        endpointEditor = EndpointEditorPage(app: application)
        inspector = InspectorPage(app: application)
        newScenarioSheet = NewScenarioSheetPage(app: application)
        deleteConfirmation = DeleteConfirmationPage(app: application)
        requestLogDrawer = RequestLogDrawerPage(app: application)
        requestDetail = RequestDetailPage(app: application)
        harImportPage = HARImportPage(app: application)
        openAPIImportPage = OpenAPIImportPage(app: application)
        captureSheet = CaptureJourneySheetPage(app: application)
    }

    /// Launches the app and brings it to the foreground.
    ///
    /// The activation retry lives in `UITestApp` so every suite gets it — the journeys suite was
    /// written without it and failed every test on a window that had launched but was not frontmost.
    @MainActor
    private func launchApp() {
        prepareApp()
        XCTAssertTrue(
            UITestApp.launchAndBringToForeground(app) { self.welcome.assertVisible(timeout: 1) },
            "Welcome screen should be accessible after repeated activation attempts"
        )
    }

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
        // Click toggle to hide
        workspace.toggleInspectorButton.click()

        // Click toggle to show again
        workspace.toggleInspectorButton.click()
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

        // Sidebar should NOT show empty state — the endpoint should be there
        let sidebarEmpty = workspace.sidebarEmptyHeading.waitForExistence(timeout: 3)
        XCTAssertFalse(sidebarEmpty, "Sidebar should have the endpoint, not empty state")
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

        // Both endpoints should exist — count matching path texts (sidebar + editor may both show)
        let usersPath = app.staticTexts["/api/users"]
        let postsPath = app.staticTexts["/api/posts"]
        XCTAssertTrue(usersPath.waitForExistence(timeout: 5),
                      "Get Users endpoint should be visible")
        XCTAssertTrue(postsPath.waitForExistence(timeout: 5),
                      "Get Posts endpoint should be visible")

        // The search field is pinned above the list, not a row inside it.
        // `ds.filterfield.sidebar.filter`, not `sidebar.filter.field`. `DSFilterField` wraps a single
        // text field, and AppKit hands that field the container's identifier — `.contain` does not
        // prevent it. The element type is what separates the field from the scope menu beside it,
        // which reports the same name. Confirmed against `app.debugDescription`, not assumed.
        let searchField = app.textFields["ds.filterfield.sidebar.filter"]
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "Search field should be available in sidebar")
        searchField.click()
        searchField.typeText("users")

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
        captureMenu.click()

        let newJourneyItem = app.menuItems["New journey from these 2 requests\u{2026}"]
        XCTAssertTrue(
            newJourneyItem.waitForExistence(timeout: 5),
            "The submenu should offer a new journey for the selection"
        )
        newJourneyItem.click()

        // The ellipsis promises a dialog, and now there is one.
        XCTAssertTrue(
            captureSheet.nameField.waitForExistence(timeout: 5),
            "Capturing into a new journey should ask for a name first"
        )
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

        workspace.serverToggleButton.click()
        XCTAssertTrue(
            workspace.waitForServerURL(port: port),
            "Server should report its base URL once running"
        )

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

        // Import menu button should exist in toolbar
        XCTAssertTrue(workspace.importMenuButton.waitForExistence(timeout: 5),
                      "Import menu button should exist in toolbar")

        workspace.importMenuButton.click()

        // Click HAR import menu item
        let harMenuItem = app.menuItems["importHARMenuItem"]
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

        workspace.importMenuButton.click()

        // Click OpenAPI import menu item
        let openAPIMenuItem = app.menuItems["importOpenAPIMenuItem"]
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

    // MARK: - 29. Evidence Screenshots

    /// Walks the core journey and captures labelled screenshots as verification evidence.
    /// PNGs are written under `<home>/Desktop/Mimic/.artifacts/screenshots` and attached to the xcresult.
    @MainActor
    func testCaptureEvidenceScreenshots() throws {
        launchApp()
        captureScreenshot("01-welcome")

        createProjectViaUI(name: "Mimic Demo", port: 8472)
        XCTAssertTrue(workspace.assertVisible())
        captureScreenshot("02-empty-workspace")

        // Editor + inspector (default scenario shown on the right) in one populated view.
        createEndpointViaUI(name: "List Users", path: "/api/v1/users")
        captureScreenshot("03-endpoint-and-inspector")

        endpointEditor.statusCodeField.click()
        endpointEditor.statusCodeField.typeKey("a", modifierFlags: .command)
        endpointEditor.statusCodeField.typeText("200")
        _ = endpointEditor.waitForStatusCodeValue("200", timeout: 3)
        captureScreenshot("04-response-configured")

        if workspace.serverToggleButton.waitForExistence(timeout: 5) {
            workspace.serverToggleButton.click()
            _ = workspace.waitForServerURL(port: 8472, timeout: 8)
        }
        captureScreenshot("05-server-running")

        if workspace.serverToggleButton.exists {
            workspace.serverToggleButton.click()
        }
    }

    /// Captures a screenshot to the xcresult (always works) and to a guaranteed-writable temp
    /// directory, printing each path to the test log so it can be collected after the run.
    @MainActor
    private func captureScreenshot(_ name: String) {
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

    // MARK: - Helpers

    /// Closes the open project via File ▸ Close Project, returning to the welcome window.
    ///
    /// These call sites used to click "New Project", because that item was wired to `closeProject`
    /// and closing was the only thing it did. It creates a project now, so the tests that wanted the
    /// welcome window ask for it by its own name.
    @MainActor
    private func closeProjectViaMenu() {
        let item = app.menuItems["Close Project"]
        XCTAssertTrue(item.waitForExistence(timeout: 5), "File ▸ Close Project should exist")
        item.click()
    }

    /// Creates a project via the UI and waits for the workspace to appear.
    @MainActor
    private func createProjectViaUI(name: String, port: Int? = nil) {
        welcome.newProjectButton.click()
        _ = newProjectSheet.nameField.waitForExistence(timeout: 3)
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText(name)
        if let port {
            _ = newProjectSheet.portField.waitForExistence(timeout: 2)
            newProjectSheet.portField.click()
            newProjectSheet.portField.typeKey("a", modifierFlags: .command)
            newProjectSheet.portField.typeText(String(port))
        }
        _ = newProjectSheet.createButton.waitForExistence(timeout: 2)
        newProjectSheet.createButton.click()
        _ = workspace.assertVisible()
    }

    /// Creates an endpoint via the UI and waits for the editor to appear.
    @MainActor
    private func createEndpointViaUI(name: String, path: String, method: String = "GET") {
        workspace.addEndpointButton.click()
        _ = newEndpointSheet.nameField.waitForExistence(timeout: 3)
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText(name)
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText(path)
        newEndpointSheet.createButton.click()
        _ = endpointEditor.pathLabel.waitForExistence(timeout: 5)
    }

    /// Sends a real HTTP request to the running mock so the log has something in it.
    ///
    /// Driving traffic from the test process rather than seeding the log through a launch hook keeps
    /// the test honest: it exercises the same path a client would, so what lands in the inspector is
    /// what the engine actually recorded.
    private func sendRequest(port: Int, path: String, method: String, body: String?) async {
        guard let url = URL(string: "http://localhost:\(port)\(path)") else {
            XCTFail("Could not build a request URL for \(path)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        request.timeoutInterval = 10

        // The response itself is not asserted on — an unmatched route answering with a fallback is a
        // perfectly good log entry, and this test is about what the window does with it.
        _ = try? await URLSession.shared.data(for: request)
    }

    /// Waits for the debounced autosave to settle before the test proceeds.
    ///
    /// The autosave status indicator is transient (saving → saved → idle in ~2s), so this does NOT
    /// assert on catching it — that race is exactly what made these long-run tests flaky. It settles
    /// when the cycle is observable and otherwise returns; the downstream recents/persistence checks
    /// (which poll the store) are the authoritative verification of the save.
    @MainActor
    private func waitForAsyncSave() {
        if UITestApp.waitForAny(
            [workspace.autosaveSavingIndicator, workspace.autosaveSavedIndicator],
            timeout: 4
        ) {
            _ = workspace.autosaveSavedIndicator.waitForExistence(timeout: 4)
            _ = workspace.autosaveSavingIndicator.waitForNonExistence(timeout: 4)
        }
    }
}

// MARK: - XCUIElement Helpers

@MainActor
extension XCUIElement {
    /// Waits for the element to no longer exist within the given timeout.
    func waitForNonExistence(timeout: TimeInterval) -> Bool {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: self)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        return result == .completed
    }
}
