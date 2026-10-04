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
    /// `a.waitToExist(t) || b.waitToExist(t)`, which is the form rule 9 of the skill
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
    ///
    /// Searched inside the list rather than the whole window: a `BEGINSWITH` over every element of
    /// `app` is the query shape that has timed XCUITest's query engine out (see
    /// `WorkspacePage.serverURLText(port:)`), and the rows are always the list's.
    func recentProjectRow(named name: String) -> XCUIElement {
        app.container(named: "welcome.recents.list")
            .descendants(matching: .any)
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
        if byId.waitToExist(timeout: 5) { return byId }

        let byText = recentProjectText(named: name)
        if byText.waitToExist(timeout: 3) { return byText }

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
    //
    // Matched across element types, as `WorkspaceShellPage.panel(_:)` does. The centre pane in
    // particular is an AppKit group (`DSNamedPaneViewController`), not the SwiftUI container the
    // other three are, so an `otherElements` query could never find it.
    var sidebar: XCUIElement { app.container(named: "sidebar") }
    var centerPane: XCUIElement { app.container(named: "centerPane") }
    var inspector: XCUIElement { app.container(named: "inspector") }
    var drawer: XCUIElement { app.container(named: "drawer") }

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
        let item = serverToggleMenuItem
        guard item.exists || UITestApp.click(overflowMenu, expecting: { item.exists }) else {
            XCTFail("More actions should lead with Run/Stop when it is folded", file: file, line: line)
            closeToolbarMenu()
            return
        }
        item.click()
    }

    /// "Run" or "Stop", with the control enabled: the inline button's title, or, when folded, the
    /// menu item's ("Run server" / "Stop server").
    ///
    /// Folded, it opens "More actions" once, reads the item while the menu stays open, and closes it
    /// on the way out. It used to open and close the menu on every half-second poll, twenty times
    /// for one slow answer. The menu is opened again only when it has closed by itself, or after
    /// three seconds without the answer: an open menu is not bound to redraw an item whose title
    /// changes while it shows, and AppKit validates the items afresh each time the menu opens.
    func waitForServerToggle(toRead title: String, timeout: TimeInterval = 10) -> Bool {
        let inline = serverToggleButton
        let item = serverToggleMenuItem
        var openedAt: Date?
        defer { if openedAt != nil { closeToolbarMenu() } }
        return UITestApp.waitUntil(timeout: timeout, pollInterval: 0.2) {
            if inline.exists { return inline.isEnabled && inline.label == title }
            if let opened = openedAt, !item.exists || Date().timeIntervalSince(opened) > 3 {
                closeToolbarMenu()
                openedAt = nil
            }
            if openedAt == nil {
                guard overflowMenu.exists else { return false }
                UITestApp.click(overflowMenu, expecting: { item.exists }, attempts: 1, timeout: 2)
                openedAt = Date()
            }
            guard item.exists else { return false }
            return item.isEnabled && "\(item.title) \(item.label)".contains("\(title) server")
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
    /// The Import menu, inline or as the "Import" item of "More actions", which this opens when it has
    /// to (``revealToolbarAction(_:titled:)``).
    ///
    /// Matched by identifier across element types, because a SwiftUI `Menu` in a toolbar realizes as
    /// a `MenuButton` or a `PopUpButton` depending on how it is placed and `app.buttons[…]` matches
    /// neither; and in More by its title as well, because the submenu AppKit makes of it does not
    /// reliably keep the identifier.
    func revealImportMenu() -> XCUIElement {
        revealToolbarAction("importMenuButton", titled: ["Import"])
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
    /// same everywhere, and ``revealToolbarAction(_:titled:)`` opens the menu first when the toggle is
    /// folded.
    func revealInspectorToggle() -> XCUIElement {
        revealToolbarAction("toggleInspectorButton", titled: ["Hide inspector", "Show inspector"])
    }
    func revealRequestLogToggle() -> XCUIElement {
        revealToolbarAction("toggleDrawerButton", titled: ["Hide request log", "Show request log"])
    }
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
    /// A menu that is already open is left as it is: a second click would close it.
    @discardableResult
    func openOverflowMenu(file: StaticString = #filePath, line: UInt = #line) -> Bool {
        guard overflowMenu.waitToExist(timeout: 5) else {
            XCTFail("The compact toolbar should offer its More menu", file: file, line: line)
            return false
        }
        let settings = overflowAction("backend.settingsButton")
        return settings.exists || UITestApp.click(overflowMenu, expecting: { settings.exists })
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
        let item = overflowItem("toggleInspectorButton", titled: ["Hide inspector", "Show inspector"])
        guard item.exists || UITestApp.click(overflowMenu, expecting: { item.exists }) else {
            XCTFail("More actions should offer the inspector toggle", file: file, line: line)
            closeToolbarMenu()
            return
        }
        item.click()
    }

    /// A toolbar action wherever the centre column's width has put it: inline, or an item of the
    /// "More actions" menu, which this opens when it has to and leaves open, for the caller to click
    /// the item or to close with ``closeToolbarMenu()``.
    ///
    /// A function rather than a property because it can click. The toggles and Import used to be
    /// properties that opened the menu when read, so reading two in a row opened it and closed it
    /// again, a read of `isEnabled` left it open for the next line to trip over, and what a read
    /// returned depended on how many reads came before it. Opening is idempotent here: when the menu
    /// is already open its item is returned as it is.
    ///
    /// `titles` are the item's titles in the menu, for the item whose identifier AppKit does not
    /// reliably carry (see ``overflowItem(_:titled:)``).
    @discardableResult
    func revealToolbarAction(_ identifier: String, titled titles: [String] = []) -> XCUIElement {
        let item = overflowItem(identifier, titled: titles)
        if item.exists { return item }
        let inline = inlineToolbarAction(identifier)
        guard UITestApp.waitForAny([inline, overflowMenu], timeout: 5) else { return inline }
        if inline.exists { return inline }
        UITestApp.click(overflowMenu, expecting: { item.exists })
        return item
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

    /// The whole pinned screen, which is what Test: Fill Window gives the window on every Mac.
    ///
    /// It used to accept any frame 1180pt wide, or the runner's own display, so "filled" meant
    /// 1024×674 on CI and something far larger locally, and a test could pass at a size CI never
    /// reaches. The app now takes every size from ``UITestEnvironment/screen``, and so does this.
    private static func isFilled(_ frame: CGRect) -> Bool {
        frame.width >= UITestEnvironment.screen.width - 1 && frame.height >= UITestEnvironment.screen.height - 1
    }

    /// Restores a collapsed navigator.
    ///
    /// Keyed on the navigator's own pane, which is there on either tab. It used to wait for the
    /// endpoints footer's "+", which the Journeys tab does not have, so with Journeys showing it
    /// looked for a Show Sidebar toggle that was not there and then waited five seconds for a button
    /// that could not appear, with the navigator open the whole time.
    func showSidebarIfNeeded() {
        if navigatorIsShown { return }
        let show = app.toolbars.buttons["Show Sidebar"].firstMatch
        // Waited for rather than read once: in a toolbar still being laid out the toggle is not yet
        // hittable, and a single read skipped the click and failed five seconds later about something
        // else.
        if UITestApp.waitUntil(timeout: 2, pollInterval: 0.1, { show.exists && show.isHittable }) { show.click() }
        _ = UITestApp.waitUntil(timeout: 5, pollInterval: 0.1) { navigatorIsShown }
    }

    /// Whether the navigator is open: its pane in the tree and more than a sliver of it inside the
    /// window, the same test the layout audit puts a pane to. A collapsed split item usually leaves
    /// the tree, and the frame check covers one that stays at no width or outside the window.
    var navigatorIsShown: Bool {
        guard let pane = (try? sidebar.snapshot())?.frame,
              let window = (try? app.windows.firstMatch.snapshot())?.frame else { return false }
        let visible = pane.intersection(window)
        return !visible.isNull && visible.width > 20 && visible.height > 20
    }

    /// The centre column's width at which the toolbar stops folding its secondary actions into
    /// "More" (`WorkspaceToolbarLayout(centerWidth:)`), measured across the card and its inset.
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
            _ = inspectorHeader.waitToDisappear(timeout: 5)
        }
        if UITestApp.waitUntil(timeout: 2, { !overflowMenu.exists }) { return true }
        hideSidebarIfShown()
        _ = UITestApp.waitUntil(timeout: 5) { !overflowMenu.exists }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
        return true
    }

    /// Collapses the navigator with the split view's own toolbar toggle, or View ▸ Hide Sidebar.
    /// Keyed on the navigator's pane, like ``showSidebarIfNeeded()``, so it works on either tab.
    func hideSidebarIfShown() {
        guard navigatorIsShown else { return }
        let hide = app.toolbars.buttons["Hide Sidebar"].firstMatch
        if UITestApp.waitUntil(timeout: 2, pollInterval: 0.1, { hide.exists && hide.isHittable }) {
            hide.click()
        } else {
            app.menuBars.menuBarItems["View"].click()
            let item = app.menuItems["Hide Sidebar"].firstMatch
            if item.waitToExist(timeout: 2) {
                item.click()
            } else {
                UITestApp.dismissAnyOpenMenu(in: app)
                // The split view's own shortcut, ⌃⌘S.
                app.typeKey("s", modifierFlags: [.control, .command])
            }
        }
        _ = UITestApp.waitUntil(timeout: 5, pollInterval: 0.1) { !navigatorIsShown }
    }

    /// Undoes `widenCentreColumnForExpandedToolbar`: brings back the navigator and the inspector.
    func restoreSidePanels() {
        showSidebarIfNeeded()
        let inspectorHeader = app.descendants(matching: .any).matching(identifier: "inspector.header").firstMatch
        if !inspectorHeader.exists {
            app.typeKey("i", modifierFlags: [.command, .option])
            _ = inspectorHeader.waitToExist(timeout: 5)
        }
        UITestApp.waitForStableFrame(app.windows.firstMatch)
    }

    /// Test: Compact Window's width, `UITestSupport.compactTestWindowWidth` in the app, spelled here
    /// because this target links no app code.
    static let compactWindowWidth: CGFloat = 900

    /// Shrinks the window to the compact test width (900pt), against the screen's right edge.
    ///
    /// Through the Debug-only Window ▸ Test: Compact Window command (⌃⌥⌘C), which sets the frame
    /// directly. Tiling through Window ▸ Move & Resize never landed reliably on CI, and the corner
    /// drag it fell back to stopped at whatever minimum the panels allowed, as narrow as 288pt.
    func compactWindow(file: StaticString = #filePath, line: UInt = #line) {
        let window = app.windows.firstMatch
        app.typeKey("c", modifierFlags: [.command, .option, .control])
        // Waited for at the compact width itself first. "Under 1180pt" alone already held before the
        // app had handled the key, because every launch's window is CI's 1024pt one, so a test could
        // carry on at the old size. Not asserted at 900pt, so a window the app keeps wider for its
        // panels' minimums still passes the check below as it always has, a few seconds later.
        _ = UITestApp.waitUntil(timeout: 5) { abs(window.frame.width - Self.compactWindowWidth) <= 1 }
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
        // Navigator rows expose method, path and name as one accessible element. Searched inside the
        // navigator, which holds every row, rather than with a `CONTAINS` over the whole window.
        sidebar.descendants(matching: .any).matching(NSPredicate(
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
        guard element.waitToExist(timeout: timeout) else { return false }
        return UITestApp.waitUntil(timeout: timeout) {
            let shown = ((element.value as? String) ?? "") + " " + element.label
            return shown.contains("localhost:\(port)") && shown.contains("server running")
        }
    }

    /// Waits for the workspace to be visible — by its empty state if the project has no endpoints, by
    /// the navigator's add button if it has some.
    ///
    /// Polled together, never `a.waitToExist(t) || b.waitToExist(t)`. That form waits out
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
        XCTAssertTrue(headersTab.waitToExist(timeout: 5), "The editor should offer a Headers segment",
                      file: file, line: line)
        if !headersTab.isSelected { headersTab.click() }
        XCTAssertTrue(addHeaderButton.waitToExist(timeout: 5),
                      "The headers pane should offer Add header", file: file, line: line)
    }

    /// Switches back to the body pane.
    func showBody(file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(bodyTab.waitToExist(timeout: 5), "The editor should offer a Body segment",
                      file: file, line: line)
        if !bodyTab.isSelected { bodyTab.click() }
        XCTAssertTrue(prettyPrintButton.waitToExist(timeout: 5),
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

    /// Waits for the status field to read `value`. Read through a snapshot, so a field that has not
    /// appeared yet is one more poll rather than a failed read.
    @discardableResult
    func waitForStatusCodeValue(_ value: String, timeout: TimeInterval = 5) -> Bool {
        let field = statusCodeField
        return UITestApp.waitUntil(timeout: timeout, pollInterval: 0.1) {
            (try? field.snapshot())?.value as? String == value
        }
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
    ///
    /// Searched inside `drawer`, the log's own container docked or taking over the centre column,
    /// rather than across the whole window: these two queries are polled, and a `BEGINSWITH` over
    /// every element of `app` is the shape that has timed XCUITest's query engine out.
    var firstLogRow: XCUIElement {
        allRowCells.firstMatch
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
        app.container(named: "drawer").descendants(matching: .any)
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
    ///
    /// Every 0.3 s rather than `waitUntil`'s default: one count reads each row it finds, so it is a
    /// handful of queries rather than one.
    func waitForRowCount(_ count: Int, timeout: TimeInterval) -> Bool {
        UITestApp.waitUntil(timeout: timeout, pollInterval: 0.3) {
            distinctRows(limit: count).count >= count
        }
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
        path.waitToExist(timeout: timeout)
    }

    /// Waits for the several-rows state that replaces the detail.
    @discardableResult
    func waitForMultipleSelection(timeout: TimeInterval = 5) -> Bool {
        multipleRequests.waitToExist(timeout: timeout)
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
        panelTitle(title).waitToExist(timeout: timeout)
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
        XCTAssertTrue(radio.waitToExist(timeout: 5), "\(name) should offer a live radio",
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
        guard row.waitToExist(timeout: 5) else { return false }

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
extension XCUIApplication {
    /// The element carrying `identifier`, whatever its type: one of the window's named containers
    /// (`sidebar`, `drawer`, `welcome.recents.list`…), to scope a predicate query to.
    ///
    /// A `CONTAINS` or `BEGINSWITH` over `app.descendants(matching: .any)` is evaluated against every
    /// element in the window, and polled that has timed XCUITest's query engine out. Inside the one
    /// container whose rows it is looking for, the same predicate has a fraction of the tree to walk,
    /// and it cannot match a namesake elsewhere in the window either.
    func container(named identifier: String) -> XCUIElement {
        descendants(matching: .any).matching(identifier: identifier).firstMatch
    }
}

/// The suite's waits for an element to arrive or to go: XCTest's `waitForExistence(timeout:)` and
/// `waitForNonExistence(timeout:)`, with the same answer and the same deadline, minus the second
/// XCTest spends before it looks.
///
/// **XCTest's waits never look before about a second.** Both poll an `existsNoRetry` predicate, as an
/// `XCTNSPredicateExpectation` does, and on Xcode 26 the first evaluation comes a second in. Across 13
/// CI shard logs, all 1,527 such waits (these two and the predicate expectations) made their first
/// check 1.0–1.1 s in, and 1,449 of them passed on that first check, one for a button that had been on
/// screen for about 4 s. That came to about 9 s of every test.
///
/// These look at once and then every tenth of a second, through
/// ``UITestApp/waitUntil(timeout:pollInterval:_:)``, which turns the run loop between looks as
/// XCTest's waiter does. The result means what XCTest's did: whether the element was there, or gone,
/// by the deadline. `Scripts/check_house_rules.sh` keeps XCTest's waits and predicate expectations out
/// of this target, so the slow form cannot come back one call at a time.
///
/// **What the second used to hide.** An element that appeared during a wait used to be found anything
/// up to a second after it arrived; now it is found within a tenth. A test that clicks a control the
/// moment it appears, in a sheet or a menu still animating in, loses that accidental settling time.
/// Such a click wants ``UITestApp/click(_:expecting:attempts:timeout:)`` or
/// ``UITestApp/waitForStableFrame(_:timeout:)``, which wait for what a click needs, rather than a
/// slower wait.
@MainActor
extension XCUIElement {
    /// Waits up to `timeout` for the element to exist, and returns whether it does.
    func waitToExist(timeout: TimeInterval) -> Bool {
        UITestApp.waitUntil(timeout: timeout, pollInterval: 0.1) { self.exists }
    }

    /// Waits up to `timeout` for the element to stop existing, and returns whether it has.
    ///
    /// Gone from the accessibility tree, which is not the same as hidden: a row scrolled out of view
    /// and a closed menu's items both still exist.
    func waitToDisappear(timeout: TimeInterval) -> Bool {
        UITestApp.waitUntil(timeout: timeout, pollInterval: 0.1) { !self.exists }
    }
}
