import AppKit
import Foundation
import XCTest

/// Sweeps the window through its sizes and panel arrangements and checks the geometry of every frame.
///
/// What a careful tester checks by eye on each screen: nothing cut off by the window or its pane,
/// no two controls drawn over each other, panels that keep their floors, a toolbar that folds at its
/// breakpoint and never into AppKit's own overflow, and an arrangement that comes back the same after
/// a round trip. `LayoutAudit` holds the rules; this suite drives the app into each state and feeds
/// them the window's accessibility tree and screenshot.
///
/// Errors fail the test, once, after every frame of the sweep has been recorded, so one red run
/// shows everything that is wrong. Warnings (near-miss alignment, off-grid insets, blank bands) are
/// recorded for the contact sheet and fail nothing until their thresholds have been calibrated.
///
/// Every frame is written to `$MIMIC_LAYOUT_AUDIT_DIR` (CI sets it through
/// `TEST_RUNNER_MIMIC_LAYOUT_AUDIT_DIR`), or to `MimicLayoutAudit` in the runner's temporary
/// directory: a PNG per frame and one line of `frames.jsonl` with its findings.
/// `Scripts/layout_audit_report.py` turns that folder into the contact sheet.
///
/// The sizes come from the app's Debug-only Window ▸ Test commands, which work from the screen's
/// visible frame. UI test launches pin that to CI's 1024×674pt (`UITestEnvironment`), so on every
/// Mac the sweep's widths are the narrowest window, the compact width (900pt) and the full 1024pt.
///
/// The sweep steers by the panels' frames, and reads all of them from one snapshot of the window at
/// a time (`PaneFrames`).
final class LayoutAuditUITests: MimicUITestCase {

    private var recorder: LayoutAuditRecorder!
    private var errors: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        errors = []
        // A sweep runs for minutes, past the 300s CI allows a UI test by default. CI has recorded
        // sweeps of up to 496s, before the panels were read from one snapshot, and the audit shards
        // never retry, so ten minutes left a slow runner about a hundred seconds. Fifteen still
        // stops a hung sweep inside the test step's 25-minute limit; bring it and the shards'
        // `allowance` back to 600 once CI has measured the faster sweep well under that. XCTest
        // enforces it only when the run enables test timeouts, and never past the run's maximum
        // allowance, which is the shard's.
        executionTimeAllowance = 900
    }

    override func tearDownWithError() throws {
        recorder = nil
        try super.tearDownWithError()
    }

    // MARK: - The rules on their own

    /// The rules against trees written out by hand, so a rule that stops firing fails here first
    /// rather than going quietly green over the whole sweep. Launches nothing.
    func testLayoutRulesFlagWhatTheyShould() {
        let window = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tree = LayoutNode("window", frame: window, children: [
            LayoutNode("group", "centerPane", frame: CGRect(x: 200, y: 50, width: 400, height: 300), children: [
                // Runs 20pt past the pane's trailing edge.
                LayoutNode("staticText", "title", label: "Title", frame: CGRect(x: 220, y: 60, width: 400, height: 16)),
                // Two buttons drawn 10pt into each other.
                LayoutNode("button", "save", frame: CGRect(x: 220, y: 100, width: 60, height: 24)),
                LayoutNode("button", "cancel", frame: CGRect(x: 270, y: 100, width: 60, height: 24)),
                // A column at x=220 that this field misses by 2pt.
                LayoutNode("textField", "name", frame: CGRect(x: 222, y: 140, width: 200, height: 22)),
                LayoutNode("staticText", "hint", label: "Hint", frame: CGRect(x: 220, y: 170, width: 100, height: 14)),
                // Inside a scroll view: clipped by it on purpose, never reported.
                LayoutNode("scrollView", frame: CGRect(x: 200, y: 200, width: 400, height: 100), children: [
                    LayoutNode("staticText", "row", label: "Row", frame: CGRect(x: 220, y: 290, width: 100, height: 40)),
                ]),
            ]),
            // Half off the window's bottom edge.
            LayoutNode("button", "footer", frame: CGRect(x: 10, y: 590, width: 80, height: 24)),
            // A field and the clear button inside it: a composite, not a collision.
            LayoutNode("searchField", "search", frame: CGRect(x: 10, y: 10, width: 150, height: 22), children: [
                LayoutNode("button", "clear", frame: CGRect(x: 140, y: 13, width: 16, height: 16)),
            ]),
        ])

        let findings = LayoutAudit.check(tree)
        func has(_ rule: String, _ subject: String) -> Bool {
            findings.contains { $0.rule == rule && $0.message.contains(subject) }
        }
        XCTAssertTrue(has("clipped-by-pane", "'title'"), "\(findings)")
        XCTAssertTrue(has("clipped-by-window", "'footer'"), "\(findings)")
        XCTAssertTrue(has("overlap", "'save'") && has("overlap", "'cancel'"), "\(findings)")
        XCTAssertTrue(has("alignment-near-miss", "'name'"), "\(findings)")
        XCTAssertFalse(findings.contains { $0.message.contains("'row'") }, "Scrolled content is not clipped: \(findings)")
        XCTAssertFalse(findings.contains { $0.message.contains("'clear'") }, "A control inside a field is not an overlap: \(findings)")
        XCTAssertEqual(findings.filter { $0.severity == .error }.count, 3, "\(findings)")
    }

    /// The blank-band scan against a bitmap written out by hand: a 100×200 pane, white, with a
    /// grey line of content at rows 10–19 and nothing below it.
    func testBlankSpaceScanMeasuresTheTallestEmptyBand() {
        let width = 100
        let height = 200
        var pixels = [UInt8](repeating: 255, count: width * height * 4)
        for y in 10..<20 {
            for x in 10..<90 {
                let offset = (y * width + x) * 4
                pixels[offset] = 60
                pixels[offset + 1] = 60
                pixels[offset + 2] = 60
            }
        }
        let scan = BlankSpaceScan(pixels: pixels, width: width, height: height)
        let run = scan.tallestBlankRun(in: PixelRect(minX: 0, minY: 0, width: width, height: height))
        XCTAssertEqual(run.start, 20)
        XCTAssertEqual(run.length, 180)

        let pane = LayoutElement(
            node: LayoutNode("group", "centerPane", frame: CGRect(x: 0, y: 0, width: 100, height: 200)),
            path: [0], pane: nil, scrollContainer: nil
        )
        let findings = LayoutAudit.blankSpace(
            [pane], window: CGRect(x: 0, y: 0, width: 100, height: 200), scan: scan
        )
        XCTAssertEqual(findings.map(\.rule), ["blank-space"])
        XCTAssertEqual(findings.first?.rect.minY, 20)
    }

    // MARK: - Sweeps

    /// The welcome window and the new project sheet, at every width.
    @MainActor
    func testWelcomeWindowLayout() {
        startAudit("welcome")
        launchApp()
        for size in WindowSize.allCases {
            let panes = resize(to: size)
            capture("welcome", size: size, panels: "-", after: panes)
        }
        resize(to: .fill)
        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitToExist(timeout: 5))
        capture("new project sheet", size: .fill, panels: "-")
        finishAudit()
    }

    /// A project with no endpoints: the first endpoint chooser in the centre, no inspector to show.
    @MainActor
    func testEmptyProjectLayout() {
        startAudit("empty-project")
        launchApp()
        createProjectViaUI(name: "Empty audit")
        sweepPanels("empty project")
        finishAudit()
    }

    /// Endpoints with a long name and path, the editor, the inspector and the new endpoint sheet.
    @MainActor
    func testEndpointsLayout() {
        startAudit("endpoints")
        launchApp()
        createProjectViaUI(name: "Storefront audit with a project name long enough to crowd the toolbar")
        resize(to: .fill)
        createEndpointViaUI(name: "List users", path: "/users")
        createEndpointViaUI(name: "Create order", path: "/orders", method: "POST")
        createEndpointViaUI(
            name: "Fetch every archived invoice for the selected customer account",
            path: "/v1/customers/{customerId}/invoices/archived/2026/with-a-path-long-enough-to-wrap"
        )
        sweepPanels("endpoint editor")

        resize(to: .fill)
        setPanels(sidebar: true, inspector: true, log: .shown)
        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitToExist(timeout: 5))
        capture("new endpoint sheet", size: .fill, panels: "sheet")
        newEndpointSheet.cancelButton.click()
        finishAudit()
    }

    /// The journeys tab with a new journey open in the editor.
    @MainActor
    func testJourneysLayout() {
        startAudit("journeys")
        launchApp()
        createProjectViaUI(name: "Journeys audit")
        resize(to: .fill)
        createEndpointViaUI(name: "Sign in", path: "/session", method: "POST")
        let journeys = JourneysNavigatorPage(app: app)
        journeys.tab.click()
        XCTAssertTrue(journeys.emptyStateAddButton.waitToExist(timeout: 5), "An empty journeys tab offers Add journey")
        let empty = settle()
        capture("journeys empty", size: .fill, panels: panelKey(empty), after: empty)
        journeys.emptyStateAddButton.click()
        XCTAssertTrue(journeys.editorName.waitToExist(timeout: 5), "Adding a journey opens it in the editor")
        sweepPanels("journey editor")
        finishAudit()
    }

    /// A running server with matched and unmatched requests in the log, then a request open in
    /// the centre column.
    @MainActor
    func testRequestLogLayout() async {
        startAudit("request-log")
        launchApp()
        let port = 62151
        createProjectViaUI(name: "Traffic audit", port: port)
        resize(to: .fill)
        createEndpointViaUI(name: "List users", path: "/users")
        workspace.toggleServer()
        XCTAssertTrue(workspace.waitForServerURL(port: port), "The server should report its base URL once running")
        for path in ["/users", "/users", "/missing", "/users?page=2"] {
            await sendRequest(port: port, path: path)
        }
        setPanels(sidebar: true, inspector: true, log: .shown)
        XCTAssertTrue(requestLogDrawer.waitForRowCount(3, timeout: 15), "The requests should reach the log")
        sweepPanels("request log")

        resize(to: .fill)
        setPanels(sidebar: true, inspector: true, log: .shown)
        requestLogDrawer.distinctRows(limit: 1).first?.click()
        XCTAssertTrue(requestDetail.waitForDetail(), "Clicking a logged request opens it in the centre column")
        for size in WindowSize.allCases {
            var panes = resize(to: size)
            for sidebar in [true, false] {
                panes = setSidebar(sidebar, from: panes)
                panes = capture("request detail", size: size, panels: panelKey(panes), after: panes)
            }
        }
        finishAudit()
    }

    /// Hiding and showing a panel, switching tabs, and shrinking and regrowing the window each put
    /// every panel back where it was.
    @MainActor
    func testPanelRoundTripsKeepTheirGeometry() {
        startAudit("round-trips")
        launchApp()
        createProjectViaUI(name: "Round trips")
        resize(to: .fill)
        createEndpointViaUI(name: "List users", path: "/users")
        // The first endpoint gives the inspector something to show, and the app brings the column in
        // on its own a moment after the editor appears: the panel is shown by default
        // (`PanelLayout.default`) and an empty project only held it back. ⌥⌘I is a toggle, so
        // arranging the panels from a reading taken before the column arrives shuts it. On CI the
        // window was read at t=10.90s, the column slid in at about 11.05s and the chord sent at
        // 11.43s closed it, so every later trip was measured against a baseline with no inspector
        // (run 37190636173). Wait for the column the app is bringing in, then arrange around it;
        // the settle below lets it finish arriving. If it never comes, `setInspector` opens it.
        let arriving = waitForPanes(timeout: 5) { $0.shown("inspector") != nil }
        let arranged = setPanels(
            sidebar: true, inspector: true, log: .shown, from: arriving.isReadable ? arriving : nil
        )
        let before = anchors(settle(after: arranged))

        let trips: [(String, @MainActor () -> Void)] = [
            ("switching to Journeys and back", {
                WorkspaceShellPage(app: self.app).journeysTab.click()
                _ = JourneysNavigatorPage(app: self.app).waitUntilVisible()
                WorkspaceShellPage(app: self.app).endpointsTab.click()
                _ = self.workspace.addEndpointButton.waitToExist(timeout: 5)
            }),
            ("hiding and showing the inspector", {
                self.setInspector(false)
                self.setInspector(true)
            }),
            ("hiding and showing the request log", {
                self.setLog(.hidden)
                self.setLog(.shown)
            }),
            ("hiding and showing the navigator", {
                self.setSidebar(false)
                self.setSidebar(true)
            }),
            ("shrinking the window to its narrowest and back", {
                self.resize(to: .minimum)
                self.resize(to: .fill)
            }),
            ("shrinking the window to its shortest and back", {
                self.resize(to: .short)
                self.resize(to: .fill)
            }),
        ]
        for (trip, perform) in trips {
            perform()
            let panes = settle()
            let after = anchors(panes)
            for (name, frame) in before {
                guard let moved = after[name] else {
                    errors.append("After \(trip), the \(name) is gone (it was \(LayoutAudit.describe(frame)))")
                    continue
                }
                if !Self.matches(frame, moved, tolerance: 1) {
                    errors.append(
                        "After \(trip), the \(name) moved from \(LayoutAudit.describe(frame)) to \(LayoutAudit.describe(moved))"
                    )
                }
            }
            capture("after \(trip)", size: .fill, panels: panelKey(panes), after: panes)
        }
        finishAudit()
    }

    // MARK: - Driving the sweep

    enum WindowSize: String, CaseIterable {
        case fill, compact, minimum, short
    }

    enum LogState: String {
        case hidden, shown, minimum, maximum
    }

    /// The arrangements each width is checked in: every navigator and inspector combination with
    /// the log at its usual height, and the log hidden, at its floor and at its ceiling with both
    /// side panels shown and with both hidden. The shortest window gets the usual arrangement only.
    static let arrangements: [(sidebar: Bool, inspector: Bool, log: LogState)] = [
        (true, true, .shown), (true, false, .shown), (false, true, .shown), (false, false, .shown),
        (true, true, .hidden), (false, false, .hidden),
        (true, true, .minimum), (true, true, .maximum),
        (false, false, .minimum), (false, false, .maximum),
    ]

    /// Captures every arrangement at every width, skipping arrangements the screen cannot reach
    /// (no inspector in an empty project) so each distinct frame is recorded once.
    @MainActor
    private func sweepPanels(_ state: String) {
        for size in WindowSize.allCases {
            var panes = resize(to: size)
            var seen: Set<String> = []
            // The navigator states at this size in which ⌥⌘I left the inspector shut. Whether it
            // opens turns on the window's width, the navigator, the inspector's last width and what
            // the project holds (`WorkspaceToolbarLayout.leavesRoomForInspector` and
            // `WorkspaceView.canPresentInspector`), never on whether the log is shown or how tall it
            // is, so asking again with only the log changed would wait out the same three seconds to
            // the same answer. Forgotten as soon as the inspector does open, because closing it
            // records a new last width.
            var inspectorStaysShut: Set<Bool> = []
            let arrangements = size == .short ? [Self.arrangements[0]] : Self.arrangements
            for arrangement in arrangements {
                panes = setSidebar(arrangement.sidebar, from: panes)
                if !arrangement.inspector || !inspectorStaysShut.contains(arrangement.sidebar) {
                    panes = setInspector(arrangement.inspector, from: panes)
                }
                if panes.shown("inspector") != nil {
                    inspectorStaysShut = []
                } else if arrangement.inspector {
                    inspectorStaysShut.insert(arrangement.sidebar)
                }
                panes = setLog(arrangement.log, from: panes)
                let key = panelKey(panes, log: arrangement.log)
                guard seen.insert(key).inserted else { continue }
                panes = capture(state, size: size, panels: key, after: panes)
            }
            // Leave the log at its usual height for the next width.
            dragLog(toHeight: 220, from: setLog(.shown, from: panes))
        }
        resize(to: .fill)
    }

    /// Sets the window to one of the test sizes and returns once it and its panels stop moving.
    ///
    /// All four through the app's Debug-only Window ▸ Test shortcuts, fill included (⌃⌥⌘F is what
    /// `WorkspacePage.fillWindow()` sends), so every size waits the same way: the settled reading
    /// holds the window's frame as well as the panels'.
    @MainActor
    @discardableResult
    private func resize(to size: WindowSize) -> PaneFrames {
        let key: String = switch size {
        case .fill: "f"
        case .compact: "c"
        case .minimum: "n"
        case .short: "t"
        }
        app.typeKey(key, modifierFlags: [.command, .option, .control])
        return settle()
    }

    @MainActor
    @discardableResult
    private func setPanels(
        sidebar: Bool, inspector: Bool, log: LogState, from earlier: PaneFrames? = nil
    ) -> PaneFrames {
        var panes = setSidebar(sidebar, from: earlier)
        panes = setInspector(inspector, from: panes)
        return setLog(log, from: panes)
    }

    // Each of these takes the reading its caller already holds, if nothing that could move a panel
    // has happened since it was taken, and reads the window itself otherwise. Each returns the
    // reading it leaves the window in: settled after anything it changed, or the one it started
    // from when it changed nothing.

    /// The navigator, through the split view's own toolbar toggle, the one way the app offers.
    ///
    /// The app adopts no `SidebarCommands`, so View has no Show Sidebar item to carry ⌃⌘S. The
    /// menu-and-shortcut fallback this used to try found no such item on CI and moved the navigator
    /// in none of its 93 attempts there, at about eleven seconds each. So a toggle that is not
    /// hittable yet is waited for instead, and one that never is gives up quietly, as the inspector
    /// does; `panelKey` records what was reached.
    @MainActor
    @discardableResult
    private func setSidebar(_ shown: Bool, from earlier: PaneFrames? = nil) -> PaneFrames {
        let panes = earlier ?? readPanes()
        guard (panes.shown("sidebar") != nil) != shown else { return panes }
        let toggle = app.toolbars.buttons[shown ? "Show Sidebar" : "Hide Sidebar"].firstMatch
        guard UITestApp.waitUntil(timeout: 2, pollInterval: Self.pollInterval, { toggle.exists && toggle.isHittable })
        else { return panes }
        toggle.click()
        return settle(after: waitForPanes(timeout: 5) { ($0.shown("sidebar") != nil) == shown })
    }

    /// The inspector, through View ▸ Inspector (⌥⌘I). An empty project or an open request hides it
    /// whatever is asked, so this gives up quietly; `panelKey` records what was reached.
    @MainActor
    @discardableResult
    private func setInspector(_ shown: Bool, from earlier: PaneFrames? = nil) -> PaneFrames {
        let panes = earlier ?? readPanes()
        guard (panes.shown("inspector") != nil) != shown else { return panes }
        app.typeKey("i", modifierFlags: [.command, .option])
        return settle(after: waitForPanes(timeout: 3) { ($0.shown("inspector") != nil) == shown })
    }

    @MainActor
    @discardableResult
    private func setLog(_ state: LogState, from earlier: PaneFrames? = nil) -> PaneFrames {
        let shown = state != .hidden
        var panes = earlier ?? readPanes()
        if (panes.shown("drawer") != nil) != shown {
            app.typeKey("l", modifierFlags: [.command, .option])
            panes = settle(after: waitForPanes(timeout: 3) { ($0.shown("drawer") != nil) == shown })
        }
        switch state {
        case .minimum: return dragLog(toHeight: 162, from: panes)
        case .maximum: return dragLog(toHeight: 4000, from: panes)
        case .hidden, .shown: return panes
        }
    }

    /// Drags the divider between the centre pane and the request log so the log is `height` tall,
    /// as far as the split view allows: its own floor below, the centre pane's floor above.
    @MainActor
    @discardableResult
    private func dragLog(toHeight height: CGFloat, from earlier: PaneFrames? = nil) -> PaneFrames {
        let panes = earlier ?? readPanes()
        guard let current = panes.logPaneHeight, abs(current - height) > 4,
              let centre = panes.shown("centerPane") else { return panes }
        let window = app.windows.firstMatch
        let frame = panes.window
        // The divider is the band between the centre pane and the log pane, not the log's header:
        // `drawer` is the log's content, which starts below that header.
        let dividerY = centre.maxY + Self.dividerBand / 2
        let bottom = centre.maxY + Self.dividerBand + current
        let targetY = max(frame.minY + 60, bottom - height - Self.dividerBand / 2)
        let x = centre.midX - frame.minX
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: x, dy: dividerY - frame.minY))
        let end = origin.withOffset(CGVector(dx: x, dy: targetY - frame.minY))
        start.press(forDuration: 0.2, thenDragTo: end)
        return settle()
    }

    /// `DSSplitPane` names its split view after the pair; the centre pane and the log pane share it.
    private static let logSplitIdentifier = "ds.splitpane.requestLog"
    /// `DSSplitPane`'s divider band, which belongs to neither pane.
    private static let dividerBand: CGFloat = 10

    /// The log pane's height, header included: from below the divider to the split view's bottom.
    /// The `drawer` element is only the log's content, so its own height understates the pane.
    static func logPaneHeight(centre: CGRect?, split: CGRect?, drawer: CGRect?) -> CGFloat? {
        guard let drawer else { return nil }
        guard let centre else { return drawer.height }
        let bottom = split.map { max($0.maxY, drawer.maxY) } ?? drawer.maxY
        return bottom - centre.maxY - dividerBand
    }

    /// The arrangement actually on screen, which is what a frame is labelled with.
    private func panelKey(_ panes: PaneFrames, log: LogState? = nil) -> String {
        let logLabel: String
        if let log, log == .minimum || log == .maximum, let height = panes.logPaneHeight {
            logLabel = "log \(log.rawValue) \(LayoutAudit.format(height))pt"
        } else {
            logLabel = panes.shown("drawer") == nil ? "no log" : "log"
        }
        return [
            panes.shown("sidebar") == nil ? "no navigator" : "navigator",
            panes.shown("inspector") == nil ? "no inspector" : "inspector",
            logLabel,
        ].joined(separator: ", ")
    }

    private func anchors(_ panes: PaneFrames) -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        let names = ["navigator": "sidebar", "centre pane": "centerPane", "inspector": "inspector",
                     "request log": "drawer", "project name": "toolbar.projectIdentity"]
        for (name, identifier) in names {
            if let frame = panes.shown(identifier) { result[name] = frame }
        }
        if panes.isReadable { result["window"] = panes.window }
        return result
    }

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Reading the panels

    /// What one reading records: the panels, the split view the centre pane and the log share, and
    /// the toolbar's items, which AppKit lays out again after the panels move. A frame taken in
    /// between shows items on top of each other that a moment later are not.
    private static let trackedIdentifiers: Set<String> = [
        "sidebar", "centerPane", "inspector", "drawer", logSplitIdentifier,
        "toolbar.projectIdentity", "serverStatusWell.url", "toolbar.overflow",
    ]

    /// The pause between two readings of the window.
    private static let pollInterval: TimeInterval = 0.15

    /// Where the panels are, from one snapshot of the window.
    ///
    /// A snapshot carries the whole tree, so every panel comes from one accessibility round trip.
    /// The sweep used to query each panel by identifier, several times for each panel it moved, and
    /// on CI those queries took about 275 of the request log sweep's 424 seconds.
    struct PaneFrames: Equatable {
        /// The window's frame, or `.null` when the window could not be read.
        var window: CGRect
        /// The first element with each tracked identifier, at whatever size it is in the tree.
        var frames: [String: CGRect]
        /// The sheet's frame while one is up, so a capture waits for it to finish arriving too.
        var sheet: CGRect?
        /// The tree the frames came from, which a capture checks rather than reading the window again.
        var snapshot: (any XCUIElementSnapshot)?
        /// When the read began, so the two readings `settle` compares are at least a poll apart.
        var time: Date

        static var unread: PaneFrames {
            PaneFrames(window: .null, frames: [:], sheet: nil, snapshot: nil, time: .distantPast)
        }

        var isReadable: Bool { snapshot != nil }

        /// A pane's frame while it is on screen: present, wider and taller than a sliver, and inside
        /// the window. A collapsed split view column can stay in the tree at zero width or off screen.
        func shown(_ identifier: String) -> CGRect? {
            guard let frame = frames[identifier] else { return nil }
            let visible = frame.intersection(window)
            guard !visible.isNull, visible.width > 20, visible.height > 20 else { return nil }
            return frame
        }

        var logPaneHeight: CGFloat? {
            LayoutAuditUITests.logPaneHeight(
                centre: shown("centerPane"), split: shown(LayoutAuditUITests.logSplitIdentifier),
                drawer: shown("drawer")
            )
        }

        /// Two readings agree when the layout does. When each was taken, and its snapshot, is not layout.
        static func == (lhs: PaneFrames, rhs: PaneFrames) -> Bool {
            lhs.window == rhs.window && lhs.frames == rhs.frames && lhs.sheet == rhs.sheet
        }
    }

    @MainActor
    private func readPanes() -> PaneFrames {
        let time = Date()
        guard let root = try? app.windows.firstMatch.snapshot() else { return .unread }
        var frames: [String: CGRect] = [:]
        var sheet: CGRect?
        // Parent before children, the order `LayoutAudit.flatten` lists them in, so an identifier
        // that appears twice resolves to the element the rules read.
        func visit(_ node: any XCUIElementSnapshot) {
            if Self.trackedIdentifiers.contains(node.identifier), frames[node.identifier] == nil {
                frames[node.identifier] = node.frame
            }
            if sheet == nil, node.elementType == .sheet { sheet = node.frame }
            for child in node.children { visit(child) }
        }
        visit(root)
        return PaneFrames(window: root.frame, frames: frames, sheet: sheet, snapshot: root, time: time)
    }

    /// Reads the window until `condition` holds or `timeout` passes, and returns the last reading.
    @MainActor
    private func waitForPanes(timeout: TimeInterval, until condition: (PaneFrames) -> Bool) -> PaneFrames {
        var latest = PaneFrames.unread
        _ = UITestApp.waitUntil(timeout: timeout, pollInterval: Self.pollInterval) {
            latest = readPanes()
            return condition(latest)
        }
        return latest
    }

    /// Waits for the window and its panels to stop moving, and returns the reading that showed it.
    ///
    /// Stopped means two readable readings a poll apart agree, within two seconds. Panel animations
    /// run after the command that starts them, and two readings taken before one starts agree too,
    /// which is why every toggle first waits for the state it asked for and only then settles.
    /// `earlier`, a reading the caller already holds, counts as the first of the two; what comes
    /// back is always a reading taken here, or `.unread` if the window could not be read at all.
    @MainActor
    @discardableResult
    private func settle(after earlier: PaneFrames? = nil, timeout: TimeInterval = 2) -> PaneFrames {
        var previous = earlier?.isReadable == true ? earlier : nil
        var latest = PaneFrames.unread
        _ = UITestApp.waitUntil(timeout: timeout, pollInterval: Self.pollInterval) {
            // Readings a moment apart can agree halfway through an animation, where a fast Mac reads
            // the window several times in the time CI reads it once.
            if let previous, Date().timeIntervalSince(previous.time) < Self.pollInterval { return false }
            let current = readPanes()
            guard current.isReadable else { return false }
            let agrees = current == previous
            previous = current
            latest = current
            return agrees
        }
        return latest
    }

    // MARK: - Capturing a frame

    private func startAudit(_ name: String) {
        recorder = LayoutAuditRecorder(test: name)
    }

    /// Checks and records the window as it is now. `earlier`, the reading the caller left the window
    /// in, saves a read: the tree checked is the next reading that agrees with it.
    @MainActor
    @discardableResult
    private func capture(
        _ state: String, size: WindowSize, panels: String, after earlier: PaneFrames? = nil
    ) -> PaneFrames {
        let window = app.windows.firstMatch
        let panes = settle(after: earlier)
        guard let snapshot = panes.snapshot else {
            errors.append("\(state) at \(size.rawValue): the window could not be read")
            return panes
        }
        let tree = Self.node(from: snapshot)
        // A sheet sits over the window it belongs to, so the controls behind it would read as
        // overlapping its own. Check the sheet alone while one is up.
        let root = Self.firstNode(in: tree) { $0.role == "sheet" } ?? tree
        let elements = LayoutAudit.flatten(root)
        var findings = LayoutAudit.check(root)
        let insets = LayoutAudit.paneInsets(elements)
        findings += insets.findings
        if root.role == "window" {
            findings += workspaceRules(elements, window: root.frame)
        }
        let screenshot = window.screenshot()
        if let image = screenshot.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
           let scan = BlankSpaceScan(image: image) {
            findings += LayoutAudit.blankSpace(elements, window: tree.frame, scan: scan)
        }

        let label = "\(state) · \(size.rawValue) \(LayoutAudit.format(tree.frame.width))×\(LayoutAudit.format(tree.frame.height)) · \(panels)"
        recorder.record(
            state: state, size: size.rawValue, panels: panels, window: tree.frame,
            png: screenshot.pngRepresentation, insets: insets.insets, findings: findings
        )
        let frameErrors = findings.filter { $0.severity == .error }
        errors += frameErrors.map { "\(label): \($0.message)" }
        if !frameErrors.isEmpty {
            let attachment = XCTAttachment(screenshot: screenshot)
            attachment.name = label
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        return panes
    }

    /// What the workspace promises at every size: its panels keep their floors, and the toolbar
    /// folds into "More" exactly when the centre column is under its breakpoint, never into AppKit's
    /// own overflow, which would take the project name with it.
    private func workspaceRules(_ elements: [LayoutElement], window: CGRect) -> [LayoutFinding] {
        func shown(_ identifier: String) -> CGRect? {
            guard let frame = elements.first(where: { $0.node.identifier == identifier })?.frame else { return nil }
            let visible = frame.intersection(window)
            return !visible.isNull && visible.width > 20 && visible.height > 20 ? frame : nil
        }
        guard let centre = shown("centerPane") ?? shown("drawer") ?? shown("sidebar") else { return [] }
        var findings: [LayoutFinding] = []
        let floors: [(String, String, KeyPath<CGRect, CGFloat>, CGFloat)] = [
            ("sidebar", "navigator", \.width, 220),
            ("inspector", "inspector", \.width, 260),
            ("centerPane", "centre pane", \.height, 270),
        ]
        for (identifier, name, dimension, floor) in floors {
            guard let frame = shown(identifier), frame[keyPath: dimension] < floor - 1 else { continue }
            findings.append(LayoutFinding(
                rule: "panel-floor", severity: .error,
                message: "The \(name) is \(LayoutAudit.format(frame[keyPath: dimension]))pt, under its \(LayoutAudit.format(floor))pt floor",
                rect: frame
            ))
        }
        if let drawer = shown("drawer"),
           let log = Self.logPaneHeight(centre: shown("centerPane"), split: shown(Self.logSplitIdentifier), drawer: drawer),
           log < 160 - 1 {
            findings.append(LayoutFinding(
                rule: "panel-floor", severity: .error,
                message: "The request log is \(LayoutAudit.format(log))pt, under its 160pt floor",
                rect: drawer
            ))
        }
        if let identity = elements.first(where: { $0.node.identifier == "toolbar.projectIdentity" })?.frame {
            if !window.insetBy(dx: -1, dy: -1).contains(identity) {
                findings.append(LayoutFinding(
                    rule: "toolbar-identity", severity: .error,
                    message: "The project name runs outside the window (\(LayoutAudit.describe(identity)))", rect: identity
                ))
            }
        } else {
            findings.append(LayoutFinding(
                rule: "toolbar-identity", severity: .error,
                message: "The project name is not in the toolbar: AppKit has moved it into its own overflow",
                rect: CGRect(x: window.minX, y: window.minY, width: window.width, height: 52)
            ))
        }
        if let centrePane = shown("centerPane"), centre == centrePane {
            let column = centrePane.width + 16
            let folded = elements.contains { $0.node.identifier == "toolbar.overflow" }
            if column >= 784, folded {
                findings.append(LayoutFinding(
                    rule: "toolbar-fold", severity: .error,
                    message: "The toolbar folds into More over a \(LayoutAudit.format(column))pt centre column, at or above its 780pt breakpoint",
                    rect: centrePane
                ))
            } else if column <= 776, !folded {
                findings.append(LayoutFinding(
                    rule: "toolbar-fold", severity: .error,
                    message: "The toolbar does not fold into More over a \(LayoutAudit.format(column))pt centre column, under its 780pt breakpoint",
                    rect: centrePane
                ))
            }
        }
        return findings
    }

    @MainActor
    private func finishAudit() {
        recorder.finish()
        guard !errors.isEmpty else { return }
        let shown = errors.prefix(40).joined(separator: "\n")
        let more = errors.count > 40 ? "\n…and \(errors.count - 40) more" : ""
        XCTFail("\(errors.count) layout errors (frames and markers in \(recorder.directory.path)):\n\(shown)\(more)")
    }

    // MARK: - Reading the tree

    @MainActor
    static func node(from snapshot: XCUIElementSnapshot) -> LayoutNode {
        LayoutNode(
            roleName(snapshot.elementType), snapshot.identifier, label: snapshot.label, frame: snapshot.frame,
            children: snapshot.children.map { node(from: $0) }
        )
    }

    static func firstNode(in node: LayoutNode, where matches: (LayoutNode) -> Bool) -> LayoutNode? {
        if matches(node) { return node }
        for child in node.children {
            if let found = firstNode(in: child, where: matches) { return found }
        }
        return nil
    }

    static func roleName(_ type: XCUIElement.ElementType) -> String {
        switch type {
        case .window: "window"
        case .sheet: "sheet"
        case .group: "group"
        case .button: "button"
        case .staticText: "staticText"
        case .textField: "textField"
        case .secureTextField: "secureTextField"
        case .searchField: "searchField"
        case .popUpButton: "popUpButton"
        case .menuButton: "menuButton"
        case .checkBox: "checkBox"
        case .radioButton: "radioButton"
        case .slider: "slider"
        case .segmentedControl: "segmentedControl"
        case .comboBox: "comboBox"
        case .image: "image"
        case .link: "link"
        case .stepper: "stepper"
        case .disclosureTriangle: "disclosureTriangle"
        case .toggle: "toggle"
        case .incrementArrow: "incrementArrow"
        case .decrementArrow: "decrementArrow"
        case .colorWell: "colorWell"
        case .progressIndicator: "progressIndicator"
        case .scrollView: "scrollView"
        case .table: "table"
        case .outline: "outline"
        case .collectionView: "collectionView"
        case .textView: "textView"
        case .webView: "webView"
        case .toolbar: "toolbar"
        case .splitGroup: "splitGroup"
        case .splitter: "splitter"
        case .tableRow: "tableRow"
        case .outlineRow: "outlineRow"
        case .cell: "cell"
        case .popover: "popover"
        case .menu: "menu"
        case .menuItem: "menuItem"
        case .scrollBar: "scrollBar"
        default: "other\(type.rawValue)"
        }
    }
}

// MARK: - Writing the frames out

/// Writes each audited frame as a PNG and a line of `frames.jsonl`, for the contact sheet.
struct LayoutAuditRecorder {
    struct Frame: Codable {
        var test: String
        var index: Int
        var state: String
        var size: String
        var panels: String
        var window: CGRect
        var image: String
        var insets: [String: CGFloat]
        var findings: [LayoutFinding]
    }

    static var root: URL {
        if let path = ProcessInfo.processInfo.environment["MIMIC_LAYOUT_AUDIT_DIR"], !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.temporaryDirectory.appendingPathComponent("MimicLayoutAudit", isDirectory: true)
    }

    let test: String
    let directory: URL
    private var frames: [Frame] = []

    init(test: String) {
        self.test = test
        directory = Self.root.appendingPathComponent(test, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    mutating func record(
        state: String, size: String, panels: String, window: CGRect, png: Data,
        insets: [String: CGFloat], findings: [LayoutFinding]
    ) {
        let index = frames.count + 1
        let slug = "\(state) \(size) \(panels)".lowercased()
            .map { $0.isLetter || $0.isNumber ? $0 : "-" }
            .reduce(into: "") { result, character in
                if character != "-" || result.last != "-" { result.append(character) }
            }
        let image = String(format: "%03d-", index) + String(slug.prefix(80)) + ".png"
        try? png.write(to: directory.appendingPathComponent(image))
        frames.append(Frame(
            test: test, index: index, state: state, size: size, panels: panels, window: window,
            image: "\(test)/\(image)", insets: insets, findings: findings
        ))
    }

    func finish() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let lines = frames.compactMap { try? encoder.encode($0) }.map { String(decoding: $0, as: UTF8.self) }
        try? (lines.joined(separator: "\n") + "\n").write(
            to: directory.appendingPathComponent("frames.jsonl"), atomically: true, encoding: .utf8
        )
    }
}
