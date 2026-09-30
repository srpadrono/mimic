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
    var openExportButton: XCUIElement { app.buttons["welcome.openExport"] }
    /// A menu button (HAR file… / OpenAPI spec…), so matched across element types.
    var importMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "welcome.import").firstMatch
    }
    /// The Import menu's items. Their spoken names ("Import HAR file") differ from the titles shown
    /// ("HAR file…"), and a subscript by title misses an item once its label is overridden, so each
    /// is matched by identifier, title or label.
    var importHARMenuItem: XCUIElement {
        menuItem(identifier: "welcome.import.har", title: "HAR file\u{2026}", label: "Import HAR file")
    }
    var importOpenAPIMenuItem: XCUIElement {
        menuItem(identifier: "welcome.import.openAPI", title: "OpenAPI spec\u{2026}", label: "Import OpenAPI spec")
    }
    private func menuItem(identifier: String, title: String, label: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title == %@ OR label == %@", identifier, title, label
        )).firstMatch
    }
    var sampleProjectButton: XCUIElement { app.buttons["welcome.sampleProject"] }
    var showOnLaunchCheckbox: XCUIElement { app.checkBoxes["welcome.showOnLaunch"] }
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

    // Center pane empty states.
    //
    // A project with endpoints but no selection shows "No endpoint selected". A project with no
    // endpoints at all shows the first-endpoint chooser instead: a heading and three cards (add,
    // import HAR, import OpenAPI) — `CenterPaneView.firstEndpointChooser`.
    var centerEmptyHeading: XCUIElement { app.staticTexts["No endpoint selected"] }
    var centerSelectEndpointMessage: XCUIElement {
        app.staticTexts["Select an endpoint from the sidebar to view and edit its configuration."]
    }
    /// "Mock your first endpoint". The heading sets its own identifier outside `DSEmptyState`, so
    /// the identifier lands; the words are polled beside it in case the chooser flattens. Any
    /// element type: the header trait publishes it as a heading, which `app.staticTexts` misses.
    var centerFirstEndpointHeading: XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            "ds.empty.center.noSelection.heading", "Mock your first endpoint", "Mock your first endpoint"
        )).firstMatch
    }
    /// The chooser's three cards. `DSOptionCard` is a plain `Button` named by its identifier.
    var centerAddEndpointCard: XCUIElement { app.buttons["empty.center.noSelection.cta"].firstMatch }
    var centerImportHARCard: XCUIElement { app.buttons["center.importHAR"].firstMatch }
    var centerImportOpenAPICard: XCUIElement { app.buttons["center.importOpenAPI"].firstMatch }

    // Toolbar
    /// Run/Stop inline in the toolbar. As a toolbar item's root button it publishes its visible
    /// title, "Run" or "Stop", as its label; the view's `.accessibilityLabel` does not reach the tree.
    /// It leads the toolbar as a round, icon-only button; the title still names it.
    /// Absent while the narrowest centre column folds it into "More actions" — use `toggleServer()`
    /// and `waitForServerToggle(toRead:)` for the action wherever it sits.
    var serverToggleButton: XCUIElement { app.buttons["serverToggleButton"].firstMatch }
    /// Run/Stop as the first item of the open "More actions" menu ("Run server" / "Stop server").
    var serverToggleMenuItem: XCUIElement { app.menuItems["serverToggleButton"].firstMatch }

    /// Whether the centre column is narrow enough (`WorkspaceView.toolbarLayout`'s minimal tier)
    /// that Run/Stop leads the "More actions" menu instead of sitting inline.
    var foldsRunIntoOverflow: Bool { !serverToggleButton.exists && overflowMenu.exists }

    /// Waits until Run/Stop is reachable: inline, or through "More actions".
    @discardableResult
    func waitForServerToggle(timeout: TimeInterval = 5) -> Bool {
        UITestApp.waitForAny([serverToggleButton, overflowMenu], timeout: timeout)
    }

    /// Starts or stops the server with the toolbar's Run/Stop, opening "More actions" first when
    /// the narrowest centre column has folded it there.
    func toggleServer(file: StaticString = #filePath, line: UInt = #line) {
        guard waitForServerToggle() else {
            XCTFail("The toolbar should offer Run/Stop inline or in More actions", file: file, line: line)
            return
        }
        if serverToggleButton.exists {
            serverToggleButton.click()
            return
        }
        overflowMenu.click()
        let item = serverToggleMenuItem
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("More actions should lead with Run/Stop when it is folded", file: file, line: line)
            closeToolbarMenu()
            return
        }
        item.click()
    }

    /// "Run" or "Stop", with the control enabled: the inline button's title, or — when folded — the
    /// menu item's ("Run server" / "Stop server"), read with the menu open and closed again.
    func waitForServerToggle(toRead title: String, timeout: TimeInterval = 10) -> Bool {
        UITestApp.waitUntil(timeout: timeout, pollInterval: 0.5) {
            let inline = serverToggleButton
            if inline.exists { return inline.isEnabled && inline.label == title }
            guard overflowMenu.exists else { return false }
            overflowMenu.click()
            let item = serverToggleMenuItem
            _ = item.waitForExistence(timeout: 2)
            let shown = item.exists ? "\(item.title) \(item.label)" : ""
            let enabled = item.exists && item.isEnabled
            closeToolbarMenu()
            return enabled && shown.contains("\(title) server")
        }
    }
    var legacyServerStartButton: XCUIElement { app.buttons["serverStartButton"].firstMatch }
    var legacyServerStopButton: XCUIElement { app.buttons["serverStopButton"].firstMatch }
    var serverSettingsToolbarButton: XCUIElement { app.toolbars.buttons["backend.settingsButton"].firstMatch }
    /// The navigator footer's "+" (right of the filter), falling back to any "Add endpoint" button —
    /// an empty project's centre chooser offers the same action on its first card.
    var addEndpointButton: XCUIElement {
        let navigator = app.buttons["sidebar.addEndpointButton"].firstMatch
        if navigator.exists { return navigator }
        return app.buttons.matching(NSPredicate(format: "label == %@", "Add endpoint")).firstMatch
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
    /// The request log and inspector toggles. Beside the inspector's title while the inspector is
    /// open; otherwise inline at the end of the centre column's toolbar when it is wide, or items of
    /// the "More" menu (`toolbar.overflow`) when it is narrower than 780pt. The identifier is the
    /// same everywhere, so `toolbarAction` opens the menu first when the toggle is folded.
    var toggleInspectorButton: XCUIElement { toolbarAction("toggleInspectorButton") }
    var toggleDrawerButton: XCUIElement { toolbarAction("toggleDrawerButton") }
    var projectTitle: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectName").firstMatch
    }
    var projectIdentity: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectIdentity").firstMatch
    }
    /// Where the project serves: the toolbar's address and state control beside the project name,
    /// "localhost:<port>" over the server's state. Its spoken value carries every address.
    var projectKind: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "serverStatusWell.url").firstMatch
    }
    /// The project name's subtitle, "12 endpoints · 3 journeys", on a wide enough toolbar.
    var projectContents: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "toolbar.projectContents").firstMatch
    }
    func inlineToolbarAction(_ identifier: String) -> XCUIElement {
        app.toolbars.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    func overflowAction(_ identifier: String) -> XCUIElement {
        app.menuItems.matching(identifier: identifier).firstMatch
    }
    /// An item of the open "More actions" menu, by identifier or by any of its titles.
    ///
    /// The titles are the fallback for the one item AppKit realizes as a submenu (Import), whose
    /// SwiftUI identifier does not reliably reach the `NSMenuItem`; for the panel toggles they are
    /// the two directions the item can read ("Hide request log" / "Show request log").
    func overflowItem(_ identifier: String, titled titles: [String]) -> XCUIElement {
        app.menuItems.matching(NSPredicate(
            format: "identifier == %@ OR title IN %@ OR label IN %@", identifier, titles, titles
        )).firstMatch
    }
    /// The compact toolbar's "More actions" menu. It holds Import and Server settings, the panel
    /// toggles while the inspector is hidden, and at the narrowest centre column Run/Stop as well.
    var overflowMenu: XCUIElement {
        app.toolbars.descendants(matching: .any).matching(identifier: "toolbar.overflow").firstMatch
    }

    /// Whether the centre column is narrow enough that the secondary actions folded into "More".
    var usesOverflowToolbar: Bool { overflowMenu.exists }

    /// Opens the "More actions" menu and waits for one of its items, so the caller can query them.
    @discardableResult
    func openOverflowMenu(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard overflowMenu.waitForExistence(timeout: 5) else {
            XCTFail("The compact toolbar should offer its More menu", file: file, line: line)
            return false
        }
        overflowMenu.click()
        return overflowAction("backend.settingsButton").waitForExistence(timeout: 5)
    }

    /// Toggles the inspector with the toolbar's own control: inline when there is room, otherwise the
    /// "More actions" item. The caller asserts the panel's effect.
    func toggleInspector(file: StaticString = #filePath, line: UInt = #line) {
        let inline = inlineToolbarAction("toggleInspectorButton")
        guard UITestApp.waitForAny([inline, overflowMenu], timeout: 5) else {
            XCTFail("The toolbar should offer the inspector toggle inline or in More actions", file: file, line: line)
            return
        }
        if inline.exists {
            inline.click()
            return
        }
        overflowMenu.click()
        let item = overflowItem("toggleInspectorButton", titled: ["Hide inspector", "Show inspector"])
        guard item.waitForExistence(timeout: 5) else {
            XCTFail("More actions should offer the inspector toggle", file: file, line: line)
            closeToolbarMenu()
            return
        }
        item.click()
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

    /// Fills the screen's visible frame with the window.
    ///
    /// Through the Debug-only Window ▸ Test: Fill Window command (⌃⌥⌘F), which sets the frame
    /// directly. The system's Fill command and the Window menu were both unreliable on CI: AppKit
    /// rebuilds the menu's window items while it opens, and Fill toggles a filled window back.
    func fillWindow() {
        let window = app.windows.firstMatch
        app.typeKey("f", modifierFlags: [.command, .option, .control])
        _ = UITestApp.waitUntil(timeout: 5) { Self.isFilled(window.frame) }
        UITestApp.waitForStableFrame(window)
    }

    /// Wide enough for every tier of the workspace, or as large as the primary display allows.
    private static func isFilled(_ frame: CGRect) -> Bool {
        if frame.width >= 1180 { return true }
        guard let visible = NSScreen.screens.first?.visibleFrame else { return false }
        return frame.width >= visible.width - 1 && frame.height >= visible.height - 1
    }

    /// Restores a collapsed navigator. Keyed on the footer's own "+", not on any "Add endpoint":
    /// an empty project's centre card carries the same label while the navigator is hidden.
    func showSidebarIfNeeded() {
        let navigatorAdd = app.buttons["sidebar.addEndpointButton"].firstMatch
        if navigatorAdd.exists { return }
        let show = app.toolbars.buttons["Show Sidebar"].firstMatch
        if show.isHittable { show.click() }
        _ = navigatorAdd.waitForExistence(timeout: 5)
    }

    /// The centre column's width at which the toolbar stops folding its secondary actions into
    /// "More" (`WorkspaceView.toolbarLayout(centerWidth:)`), measured across the card and its inset.
    static let expandedToolbarBreakpoint: CGFloat = 780
    /// Below this centre-column width Run/Stop folds into "More" too.
    static let minimalToolbarBreakpoint: CGFloat = 360

    /// The centre column's width as the toolbar layout measures it: the card plus its
    /// `DSLayout.panelInset` (8pt) on each side.
    var centreColumnWidth: CGFloat {
        let pane = app.descendants(matching: .any).matching(identifier: "centerPane").firstMatch
        return pane.exists ? pane.frame.width + 16 : 0
    }

    /// Fills the window and, when the display alone cannot give the centre column the toolbar's
    /// expanded breakpoint, hides the inspector and then the navigator until it does.
    ///
    /// On CI's 1024pt display a filled window is 1024pt wide; the navigator (264pt) and inspector
    /// (300pt) leave the centre column far under 780pt, so the only genuinely wide centre column is
    /// one with both side panels collapsed. Idempotent. Returns whether any panel was hidden.
    @discardableResult
    func widenCentreColumnForExpandedToolbar() -> Bool {
        fillWindow()
        guard overflowMenu.exists else { return false }
        let inspectorHeader = app.descendants(matching: .any).matching(identifier: "inspector.header").firstMatch
        if inspectorHeader.exists {
            app.typeKey("i", modifierFlags: [.command, .option])
            _ = inspectorHeader.waitForNonExistence(timeout: 5)
        }
        if UITestApp.waitUntil(timeout: 2, { !overflowMenu.exists }) { return true }
        hideSidebarIfShown()
        _ = UITestApp.waitUntil(timeout: 5) { !overflowMenu.exists }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
        return true
    }

    /// Collapses the navigator with the split view's own toolbar toggle, or View ▸ Hide Sidebar.
    func hideSidebarIfShown() {
        let navigatorAdd = app.buttons["sidebar.addEndpointButton"].firstMatch
        let hide = app.toolbars.buttons["Hide Sidebar"].firstMatch
        if hide.exists, hide.isHittable {
            hide.click()
        } else if navigatorAdd.exists {
            app.menuBars.menuBarItems["View"].click()
            let item = app.menuItems["Hide Sidebar"].firstMatch
            if item.waitForExistence(timeout: 2) {
                item.click()
            } else {
                UITestApp.dismissAnyOpenMenu(in: app)
                // The split view's own shortcut, ⌃⌘S.
                app.typeKey("s", modifierFlags: [.control, .command])
            }
        }
        _ = navigatorAdd.waitForNonExistence(timeout: 5)
    }

    /// Undoes `widenCentreColumnForExpandedToolbar`: brings back the navigator and the inspector.
    func restoreSidePanels() {
        showSidebarIfNeeded()
        let inspectorHeader = app.descendants(matching: .any).matching(identifier: "inspector.header").firstMatch
        if !inspectorHeader.exists {
            app.typeKey("i", modifierFlags: [.command, .option])
            _ = inspectorHeader.waitForExistence(timeout: 5)
        }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
    }

    /// Shrinks the window to the compact test width (900pt), against the screen's right edge.
    ///
    /// Through the Debug-only Window ▸ Test: Compact Window command (⌃⌥⌘C), which sets the frame
    /// directly. Tiling through Window ▸ Move & Resize never landed reliably on CI, and the corner
    /// drag it fell back to stopped at whatever minimum the panels allowed, as narrow as 288pt.
    func compactWindow(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        app.typeKey("c", modifierFlags: [.command, .option, .control])
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 5) { window.frame.width < 1180 },
            "The window should be compact (under 1180pt) — it is \(window.frame.width)pt",
            file: file, line: line
        )
        UITestApp.waitForStableFrame(window)
    }

    // Autosave
    //
    // The indicator sits at the trailing end of the jump bar (`breadcrumb`), not in the toolbar.
    // It renders nothing while idle, so the addressable surface is the state-specific identifiers,
    // one per arm.
    var autosaveSavedIndicator: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "autosaveStatus.saved").firstMatch
    }
    var autosaveSavingIndicator: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "autosaveStatus.saving").firstMatch
    }

    // Drawer empty state
    //
    // One sentence whatever the server is doing — "Requests appear here while the server runs" —
    // plus, only while it runs, a `curl http://localhost:<port>/` chip to try. Matched by identifier
    // first: the inspector's Traffic section says "No requests yet", which this used to be.
    var drawerEmptyHeading: XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            "ds.empty.drawer.requests.heading",
            "Requests appear here while the server runs",
            "Requests appear here while the server runs"
        )).firstMatch
    }
    /// The running server's "try this" command. Absent while the server is stopped.
    var drawerCurlCommand: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "drawer.empty.command").firstMatch
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
    /// A menu button, not a pop-up: matched across element types by its identifier.
    var methodPicker: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.methodPicker").firstMatch
    }
    var pathField: XCUIElement { app.textFields["newEndpoint.pathField"] }
    var createButton: XCUIElement { app.buttons["newEndpoint.createButton"] }
    var cancelButton: XCUIElement { app.buttons["newEndpoint.cancelButton"] }
    var groupField: XCUIElement { app.textFields["newEndpoint.group"] }
    /// Present only when the project already has groups.
    var groupMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.groupMenu").firstMatch
    }
    var statusMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.status").firstMatch
    }
    var contentTypeMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.contentType").firstMatch
    }
    var pathError: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "newEndpoint.path.error").firstMatch
    }
}

/// Page object for the Endpoint Editor (center pane).
@MainActor
struct EndpointEditorPage {
    let app: XCUIApplication

    // The editor has no scroll view and no options disclosure. Top to bottom it is: the request bar
    // (method menu, path, copy URL), the edited scenario's title row (name, Live/Not live, Make
    // live, scenario menu), one fields row (Status, Delay, Content type), the Body/Headers
    // segmented control, and whichever of the two panes is selected. The group tag, backend and
    // project delay moved to the inspector's Endpoint section — see `InspectorPage`.

    var statusCodeField: XCUIElement { app.textFields["endpointEditor.statusCode"] }
    var statusDescription: XCUIElement { app.staticTexts["endpointEditor.statusDescription"] }
    /// The chevron beside the status code that offers common codes.
    var statusMenu: XCUIElement { app.descendants(matching: .any).matching(identifier: "endpointEditor.statusMenu").firstMatch }
    var contentTypeMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "endpointEditor.contentType").firstMatch
    }
    var copyURLButton: XCUIElement { app.buttons["endpointEditor.copyURL"].firstMatch }
    /// The visible scroll viewport; the inner text view keeps the unsuffixed identifier.
    var bodyEditor: XCUIElement {
        app.scrollViews.matching(identifier: "ds.jsoneditor.editor.body.viewport").firstMatch
    }

    // MARK: Scenario title row

    /// The name of the scenario being edited — which is not necessarily the live one.
    var scenarioName: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "endpointEditor.scenarioName").firstMatch
    }
    /// "Live" or "Not live", combined into one element with its dot.
    var liveState: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "endpointEditor.liveState").firstMatch
    }
    /// Present only while the edited scenario is not live. `DSButton` prefixes its identifier.
    var makeLiveButton: XCUIElement {
        app.buttons["ds.button.endpointEditor.makeLive"].firstMatch
    }
    var scenarioMenu: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "endpointEditor.scenarioMenu").firstMatch
    }

    /// What the live-state readout says, label and value together.
    func liveStateText() -> String {
        let element = liveState
        guard element.exists else { return "" }
        return "\(element.label) \(element.value.map { String(describing: $0) } ?? "")"
    }

    /// Waits for the title row to name `name` and say whether it is live.
    ///
    /// "Not live" contains "live", so the negative case is matched on "Not live" and the positive
    /// case requires its absence.
    @discardableResult
    func waitForEditedScenario(_ name: String, live: Bool, timeout: TimeInterval = 5) -> Bool {
        let title = scenarioName
        let state = liveState
        return UITestApp.waitUntil(timeout: timeout) {
            guard title.exists, state.exists else { return false }
            let shown = "\(title.label) \(title.value.map { String(describing: $0) } ?? "")"
            let said = "\(state.label) \(state.value.map { String(describing: $0) } ?? "")"
            let saysNotLive = said.localizedCaseInsensitiveContains("Not live")
            return shown.contains(name) && (live ? !saysNotLive && said.contains("Live") : saysNotLive)
        }
    }

    // MARK: Body / Headers

    /// The two segments of the response-part control. `DSSegmentedControl` draws each segment as a
    /// plain button carrying the selected trait, not as a radio button.
    var bodyTab: XCUIElement { app.buttons["endpointEditor.tab.body"].firstMatch }
    var headersTab: XCUIElement { app.buttons["endpointEditor.toggleHeaders"].firstMatch }
    var headersEmptyNote: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "endpointEditor.headers.empty").firstMatch
    }

    /// Switches to the headers pane. Clicking the segment selects it; it does not toggle.
    func showHeaders(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(headersTab.waitForExistence(timeout: 5), "The editor should offer a Headers segment",
                      file: file, line: line)
        if !headersTab.isSelected { headersTab.click() }
        XCTAssertTrue(addHeaderButton.waitForExistence(timeout: 5),
                      "The headers pane should offer Add header", file: file, line: line)
    }

    /// Switches back to the body pane.
    func showBody(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bodyTab.waitForExistence(timeout: 5), "The editor should offer a Body segment",
                      file: file, line: line)
        if !bodyTab.isSelected { bodyTab.click() }
        XCTAssertTrue(prettyPrintButton.waitForExistence(timeout: 5),
                      "The body pane should offer Format", file: file, line: line)
    }

    var delayField: XCUIElement { app.textFields["endpointEditor.delay"] }
    /// The endpoint's group tag. It lives in the inspector's Endpoint section now, so the inspector
    /// has to be open for this to exist; kept here because every caller is editing the endpoint.
    var groupTagField: XCUIElement { app.textFields["endpointEditor.groupTag"] }
    /// The method menu at the head of the request bar: Edit request, Rename, Duplicate, Delete.
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
    ///
    /// The table is the shortest scroll view in the row's own column. With a request selected, the
    /// detail beside the list scrolls too, and is shorter than the list — so the column matters.
    func reveal(_ row: XCUIElement) -> Bool {
        let drawer = app.descendants(matching: .any).matching(identifier: "drawer").firstMatch
        guard drawer.exists, row.exists else { return false }
        let rowMidX = row.frame.midX
        guard let table = drawer.scrollViews.allElementsBoundByIndex
            .filter({ $0.frame.height > 0 && $0.frame.minX <= rowMidX && rowMidX <= $0.frame.maxX })
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
    /// The method filter: a `Menu` at the filter field's leading edge, so a menu button.
    var methodFilter: XCUIElement {
        let byIdentifier = app.menuButtons["drawer.methodFilter"].firstMatch
        if byIdentifier.exists { return byIdentifier }
        return app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier == %@ OR label CONTAINS %@",
                                  "drawer.methodFilter", "Filter by method"))
            .firstMatch
    }
    var clearButton: XCUIElement { app.buttons["clearRequestLogButton"] }
    /// The idle empty state, "Requests appear here while the server runs". Matched by identifier
    /// first; the inspector's Traffic section says "No requests yet".
    var emptyHeading: XCUIElement {
        app.staticTexts.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR value == %@",
            "ds.empty.drawer.requests.heading",
            "Requests appear here while the server runs",
            "Requests appear here while the server runs"
        )).firstMatch
    }
    /// The All / Unmatched / Errors segments: buttons with `.isSelected` on the chosen one, labelled
    /// with the title and ", N" once there is something to count.
    private func scopeSegment(identifier: String, title: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR label == %@ OR label BEGINSWITH %@",
            identifier, title, "\(title), "
        )).firstMatch
    }
    var allSegment: XCUIElement { scopeSegment(identifier: "drawer.scope.all", title: "All") }
    var unmatchedSegment: XCUIElement { scopeSegment(identifier: "drawer.unmatchedFilter", title: "Unmatched") }
    var errorsSegment: XCUIElement { scopeSegment(identifier: "drawer.errorsFilter", title: "Errors") }
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
    /// cell, so this returned one element per cell for every logged request, all reporting the same
    /// `requestLog-<uuid>`. Dumped from `app.debugDescription` at the time:
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

/// Page object for the request detail, which opens beside the request log in the centre column
/// while a row is selected — and for the inspector's header, which the detail hides and deselecting
/// brings back.
@MainActor
struct RequestDetailPage {
    let app: XCUIApplication

    /// The detail pane itself, present only while exactly one request is open.
    var container: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestDetail").firstMatch
    }

    /// Stands in for the detail while several rows are selected.
    var multipleRequests: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "ds.empty.requestDetail.multipleRequests").firstMatch
    }

    /// Waits for one request to be open beside the log — its path is the detail's first line.
    @discardableResult
    func waitForDetail(timeout: TimeInterval = 5) -> Bool {
        path.waitForExistence(timeout: timeout)
    }

    /// Waits for the several-rows state that replaces the detail.
    @discardableResult
    func waitForMultipleSelection(timeout: TimeInterval = 5) -> Bool {
        multipleRequests.waitForExistence(timeout: timeout)
    }

    /// Every inspector mode names itself in the header text — "Scenarios", "Journey", "Overview".
    ///
    /// Matched across element types: the title carries the header trait, which AppKit publishes as
    /// a heading rather than a plain `StaticText`, so an `app.staticTexts` query never saw it.
    func panelTitle(_ title: String) -> XCUIElement {
        app.descendants(matching: .any).matching(
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
    /// Closes the request, which gives the centre column back to the editor.
    var closeButton: XCUIElement {
        app.buttons["requestDetail.close"].firstMatch
    }
    /// "Create endpoint" for a call nothing answered.
    var createEndpointButton: XCUIElement {
        app.buttons["requestDetail.createEndpoint"].firstMatch
    }
    /// "Go to endpoint" for a call an endpoint answered.
    var goToEndpointButton: XCUIElement {
        app.buttons["requestDetail.goToEndpoint"].firstMatch
    }
    var copyCurlButton: XCUIElement {
        app.descendants(matching: .button).matching(identifier: "requestDetail.copy.curl").firstMatch
    }
    var copyConfirmation: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestDetail.copyConfirmation").firstMatch
    }
    var requestBody: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestLog.body.request").firstMatch
    }
    var responseBody: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "requestLog.body.response").firstMatch
    }

    /// A segment of the Request/Response/Timing picker.
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

    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
    var header: XCUIElement { element("inspector.header") }
    /// The header's title text: "Scenarios" for an endpoint, "Request", "Journey", "Overview"…
    var title: XCUIElement { element("ds.panelheader.title.inspector") }

    // MARK: Endpoint mode
    //
    // One scrolling column, no tabs: the scenario list, the live note, the "Endpoint" section
    // (group, base delay, port, when unmatched) and the "Traffic" section.

    /// The endpoint content container, spoken as "<METHOD> method <path>".
    var endpointIdentity: XCUIElement { element("inspector.endpointIdentity") }
    var scenarioList: XCUIElement { element("inspector.scenarioList") }
    var liveNote: XCUIElement { element("inspector.liveNote") }

    /// The group tag field in the Endpoint section. Commits on Return or on losing focus.
    var groupTagField: XCUIElement { app.textFields["endpointEditor.groupTag"].firstMatch }
    /// The chevron beside the group field, listing existing groups. Only present when some exist.
    var groupMenu: XCUIElement { element("inspector.groupMenu") }
    /// The port/backend menu. Disabled while the project has a single listener.
    var backendMenu: XCUIElement { element("endpointEditor.backend") }
    /// The project-wide delay, read-only, with its number as the accessibility value.
    var globalDelayValue: XCUIElement { element("endpointEditor.globalDelay") }
    var unmatchedBehavior: XCUIElement { element("inspector.unmatchedBehavior") }

    var traffic: XCUIElement { element("inspector.traffic") }
    var trafficServed: XCUIElement { element("inspector.traffic.served") }
    var trafficErrors: XCUIElement { element("inspector.traffic.errors") }
    var trafficMedian: XCUIElement { element("inspector.traffic.median") }

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

    /// A scenario row. Clicking it OPENS the scenario in the editor; it does not make it live.
    /// Its value still reports the live state ("active"/"inactive"); its selected trait marks the
    /// row being edited.
    func scenarioRow(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "inspector.scenario.\(name)").firstMatch
    }

    /// The radio at the head of a scenario row. Clicking it makes that scenario live.
    func liveRadio(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: "inspector.scenario.\(name).live").firstMatch
    }

    /// Makes a scenario live through its radio — the one click that changes what the mock serves.
    func makeLive(named name: String, file: StaticString = #filePath, line: UInt = #line) {
        let radio = liveRadio(named: name)
        XCTAssertTrue(radio.waitForExistence(timeout: 5), "\(name) should offer a live radio",
                      file: file, line: line)
        radio.click()
    }

    /// Finds scenario row by looking for the text content as fallback.
    func findScenario(named name: String) -> XCUIElement {
        let byId = scenarioRow(named: name)
        if byId.exists { return byId }
        return app.staticTexts[name].firstMatch
    }

    /// Whether the row is the one open in the editor (its selected trait), as distinct from live.
    func isScenarioEdited(named name: String) -> Bool {
        let row = scenarioRow(named: name)
        return row.exists && row.isSelected
    }

    /// Checks if a scenario row reports itself live ("active").
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
