import XCTest
import AppKit
import Foundation

// MARK: - Page objects

/// Page object for the Welcome screen — centralizes element queries.
@MainActor
struct WelcomePage {
    let app: XCUIApplication

    private var heroTitleByIdentifier: XCUIElement { app.staticTexts["welcomeHeroTitle"] }
    private var heroTitleByLabel: XCUIElement { app.staticTexts["Mimic"].firstMatch }
    var newProjectButton: XCUIElement { app.buttons["newProjectButton"] }
    private var noRecentProjectsLabelByIdentifier: XCUIElement {
        app.staticTexts["ds.empty.welcome.recents.heading"]
    }
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
            NSPredicate(format: "value == %@ OR label == %@", name, name)
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
    var portValidationError: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newProject.port.error").firstMatch
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
    var centerAddEndpointMessage: XCUIElement {
        app.staticTexts["Add an endpoint or import a HAR file or OpenAPI spec to get started."]
    }
    var centerSelectEndpointMessage: XCUIElement {
        app.staticTexts["Select an endpoint from the sidebar to view and edit its configuration."]
    }

    // Toolbar
    var serverToggleButton: XCUIElement { app.buttons["serverToggleButton"].firstMatch }
    var legacyServerStartButton: XCUIElement { app.buttons["serverStartButton"].firstMatch }
    var legacyServerStopButton: XCUIElement { app.buttons["serverStopButton"].firstMatch }
    var serverSettingsToolbarButton: XCUIElement { app.toolbars.buttons["backend.settingsButton"].firstMatch }
    /// Both the navigator header and the empty state offer the same creation action.
    var addEndpointButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "label == %@", "Add endpoint")).firstMatch
    }
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
        toolbarAction("importMenuButton")
    }
    // AppKit replaces identifiers with menuAction: for nested SwiftUI Menu items. Match the
    // exact native title as a fallback; both branches still identify the same single action.
    var importHARMenuItem: XCUIElement {
        let named = app.menuItems["importHARMenuItem"].firstMatch
        return named.exists ? named : app.menuItems["Import HAR file…"].firstMatch
    }
    var importOpenAPIMenuItem: XCUIElement {
        let named = app.menuItems["importOpenAPIMenuItem"].firstMatch
        return named.exists ? named : app.menuItems["Import OpenAPI spec…"].firstMatch
    }
    var toggleInspectorButton: XCUIElement { toolbarAction("toggleInspectorButton") }
    var toggleDrawerButton: XCUIElement { toolbarAction("toggleDrawerButton") }
    var projectTitle: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectName").firstMatch
    }
    var projectIdentity: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectIdentity").firstMatch
    }
    var projectKind: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectKind").firstMatch
    }
    func inlineToolbarAction(_ identifier: String) -> XCUIElement {
        app.toolbars.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    func overflowAction(_ identifier: String) -> XCUIElement {
        app.menuItems.matching(identifier: identifier).firstMatch
    }
    var overflowMenu: XCUIElement {
        app.toolbars.descendants(matching: .any).matching(identifier: "toolbar.overflow").firstMatch
    }

    /// Actions stay addressable whether inline or inside the narrow-window menu.
    func toolbarAction(_ identifier: String) -> XCUIElement {
        let action = app.descendants(matching: .any).matching(identifier: identifier).firstMatch
        if action.exists { return action }
        if overflowMenu.waitForExistence(timeout: 3) { overflowMenu.click() }
        return action
    }

    func closeToolbarMenu() {
        UITestApp.dismissAnyOpenMenu(in: app)
    }

    func fillWindow() {
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Fill"].click()
        _ = UITestApp.waitUntil(timeout: 5) { app.windows.firstMatch.frame.width >= 1180 }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
    }

    func showSidebarIfNeeded() {
        if addEndpointButton.exists { return }
        let show = app.toolbars.buttons["Show Sidebar"].firstMatch
        if show.isHittable { show.click() }
        _ = addEndpointButton.waitForExistence(timeout: 5)
    }

    func compactWindow() {
        app.menuBars.menuBarItems["Window"].click()
        app.menuItems["Move & Resize"].click()
        // Right edge keeps the native overflow popup inside the window screenshot.
        app.menuItems["Top Right"].click()
        _ = UITestApp.waitUntil(timeout: 5) { app.windows.firstMatch.frame.width < 1180 }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
    }

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
    var drawerStoppedMessage: XCUIElement {
        app.staticTexts["Start the server and send a request to see it appear here."]
    }
    var drawerRunningMessage: XCUIElement {
        app.staticTexts["Send a request to see it appear here."]
    }

    func endpointPathText(_ path: String) -> XCUIElement {
        // Navigator rows expose method, path and name as one accessible element.
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "endpoint-", " \(path), "
        )).firstMatch
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
        // AppKit can move the whole status group into native toolbar overflow on small displays.
        // Expand before asserting its visible, two-line presentation.
        if !element.exists { fillWindow() }
        guard element.waitForExistence(timeout: timeout) else { return false }
        return UITestApp.waitUntil(timeout: timeout) {
            let shown = ((element.value as? String) ?? "") + " " + element.label
            return shown.contains("localhost:\(port)") && shown.contains("server running")
        }
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
    var pathError: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.path.error").firstMatch
    }
}

/// Page object for the Endpoint Editor (center pane).
@MainActor
struct EndpointEditorPage {
    let app: XCUIApplication

    var statusCodeField: XCUIElement { app.textFields["endpointEditor.statusCode"] }
    var optionsToggle: XCUIElement { app.buttons["endpointEditor.toggleOptions"] }
    var headersToggle: XCUIElement { app.buttons["endpointEditor.toggleHeaders"] }
    var statusDescription: XCUIElement { app.staticTexts["endpointEditor.statusDescription"] }
    var globalDelayNote: XCUIElement { app.staticTexts["endpointEditor.globalDelay.note"] }
    /// The visible scroll viewport; the inner text view keeps the unsuffixed identifier.
    var bodyEditor: XCUIElement {
        app.scrollViews.matching(identifier: "ds.jsoneditor.editor.body.viewport").firstMatch
    }

    /// The form's scroll surface, outside the nested response-body editor.
    var formScrollView: XCUIElement {
        let pane = app.descendants(matching: .any).matching(identifier: "centerPane").firstMatch.frame
        let form = app.scrollViews.allElementsBoundByIndex
            .filter { scrollView in
                let center = CGPoint(x: scrollView.frame.midX, y: scrollView.frame.midY)
                return pane.contains(center)
                    && scrollView.identifier != "ds.jsoneditor.editor.body.viewport"
            }
            .max { $0.frame.height < $1.frame.height }
        if let form { return form }
        XCTFail("No endpoint form scroll view was found inside the center pane")
        return app.scrollViews.firstMatch
    }

    /// Short windows can place options below the clip even though the controls exist in the tree.
    func reveal(_ control: XCUIElement) -> Bool {
        if control.isHittable { return true }
        let scroller = formScrollView
        guard scroller.exists else { return control.isHittable }
        for delta in [-90.0, -90.0, -90.0, -90.0, 90.0, 90.0, 90.0, 90.0,
                      90.0, 90.0, 90.0, 90.0] {
            scroller.scroll(byDeltaX: 0, deltaY: CGFloat(delta))
            if control.isHittable { return true }
        }
        return control.isHittable
    }

    func showOptions(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(optionsToggle.waitForExistence(timeout: 5), file: file, line: line)
        if optionsToggle.value as? String == "Collapsed" { optionsToggle.click() }
    }

    var delayField: XCUIElement { app.textFields["endpointEditor.delay"] }
    var groupTagField: XCUIElement { app.textFields["endpointEditor.groupTag"] }
    var moreMenu: XCUIElement {
        let byMenuButton = app.menuButtons["endpointEditor.moreMenu"].firstMatch
        if byMenuButton.exists { return byMenuButton }
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

    /// At the drawer's minimum height, rows can exist in accessibility outside the clipped table.
    /// Scroll the table itself until the row's click point is inside its viewport.
    func reveal(_ row: XCUIElement) -> Bool {
        let drawer = app.descendants(matching: .any).matching(identifier: "drawer").firstMatch
        guard drawer.exists, row.exists else { return false }
        guard let table = drawer.scrollViews.allElementsBoundByIndex
            .filter({ $0.frame.height > 0 })
            .min(by: { $0.frame.height < $1.frame.height }) else { return false }
        for _ in 0..<4 {
            let viewport = table.frame
            let center = CGPoint(x: row.frame.midX, y: row.frame.midY)
            if viewport.contains(center) && row.isHittable { return true }
            table.scroll(byDeltaX: 0, deltaY: center.y < viewport.minY ? -30 : 30)
        }
        let center = CGPoint(x: row.frame.midX, y: row.frame.midY)
        return table.frame.contains(center) && row.isHittable
    }

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
    ///
    /// Resolved through `allElementsBoundByIndex`, which takes ONE snapshot, rather than reading
    /// `allRowCells.count` and then indexing back into the query. That older shape asked the app two
    /// separate questions, and anything that rebuilds the table between them — a filter change, a
    /// sort, traffic still arriving — leaves the second one indexing rows the first one counted and
    /// the runner raises "Failed to get matching snapshot". It is not hypothetical: it is how
    /// `testFilteringTheRequestLogByTextAndMethod` died on CI, inside this helper rather than on any
    /// assertion of its own, which is the worst way for a shared query to fail because the message
    /// names neither the filter nor the row.
    ///
    /// Each row is still guarded with `exists` before its identifier is read, so a row that goes
    /// away mid-walk truncates the list instead of taking the test down with it.
    func distinctRows(limit: Int) -> [XCUIElement] {
        guard limit > 0 else { return [] }
        var seen: Set<String> = []
        var rows: [XCUIElement] = []
        for cell in allRowCells.allElementsBoundByIndex {
            guard cell.exists else { break }
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

    /// Endpoint modes use selected segments; the other modes have a named text title.
    func panelTitle(_ title: String) -> XCUIElement {
        if title == "Scenarios" || title == "Traffic" {
            return InspectorPage(app: app).tab(title.lowercased())
        }
        return app.staticTexts.matching(
            NSPredicate(
                format: "identifier == %@ AND (value == %@ OR label == %@)",
                "ds.panelheader.title.inspector", title, title
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
    /// The inspector's back action returns to the previous selection context.
    var closeButton: XCUIElement {
        app.buttons["inspector.closeRequestDetailButton"].firstMatch
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
        let element = panelTitle(title)
        if title == "Scenarios" || title == "Traffic" {
            return UITestApp.waitUntil(timeout: timeout) {
                element.exists && (element.isSelected || element.value.map { String(describing: $0) } == "1")
            }
        }
        return element.waitForExistence(timeout: timeout)
    }
}

/// Page object for the Inspector panel (scenarios).
@MainActor
struct InspectorPage {
    let app: XCUIApplication

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    var header: XCUIElement { element("inspector.header") }
    func tab(_ name: String) -> XCUIElement {
        let identified = element("inspector.tab.\(name)")
        if identified.exists { return identified }
        let label = name == "traffic" ? "Show the requests this endpoint answered" : "Show this endpoint's scenarios"
        return app.radioButtons.matching(NSPredicate(format: "label BEGINSWITH %@", label)).firstMatch
    }
    var trafficList: XCUIElement { element("endpointTraffic.list") }
    var trafficRows: XCUIElementQuery {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "endpointTraffic.row."))
    }
    func journeyRow(_ name: String) -> XCUIElement { element("inspector.journey.\(name)") }
    func spoken(_ element: XCUIElement) -> String {
        guard element.exists else { return "" }
        return "\(element.label) \(element.value.map(String.init(describing:)) ?? "")"
    }

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
