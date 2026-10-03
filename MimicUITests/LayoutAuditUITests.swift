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
/// CI's display is 1024pt wide, so there the sweep's widths are the narrowest window, the compact
/// width (900pt) and the whole display. A wider display adds its own full width.
final class LayoutAuditUITests: MimicUITestCase {

    private var recorder: LayoutAuditRecorder!
    private var errors: [String] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        errors = []
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
            resize(to: size)
            capture("welcome", size: size, panels: "-")
        }
        workspace.fillWindow()
        welcome.newProjectButton.click()
        XCTAssertTrue(newProjectSheet.nameField.waitForExistence(timeout: 5))
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
        workspace.fillWindow()
        createEndpointViaUI(name: "List users", path: "/users")
        createEndpointViaUI(name: "Create order", path: "/orders", method: "POST")
        createEndpointViaUI(
            name: "Fetch every archived invoice for the selected customer account",
            path: "/v1/customers/{customerId}/invoices/archived/2026/with-a-path-long-enough-to-wrap"
        )
        sweepPanels("endpoint editor")

        workspace.fillWindow()
        setPanels(sidebar: true, inspector: true, log: .shown)
        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5))
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
        workspace.fillWindow()
        createEndpointViaUI(name: "Sign in", path: "/session", method: "POST")
        let journeys = JourneysNavigatorPage(app: app)
        journeys.tab.click()
        XCTAssertTrue(journeys.emptyStateAddButton.waitForExistence(timeout: 5), "An empty journeys tab offers Add journey")
        capture("journeys empty", size: .fill, panels: panelKey())
        journeys.emptyStateAddButton.click()
        XCTAssertTrue(journeys.editorName.waitForExistence(timeout: 5), "Adding a journey opens it in the editor")
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
        workspace.fillWindow()
        createEndpointViaUI(name: "List users", path: "/users")
        workspace.toggleServer()
        XCTAssertTrue(workspace.waitForServerURL(port: port), "The server should report its base URL once running")
        for path in ["/users", "/users", "/missing", "/users?page=2"] {
            await sendRequest(port: port, path: path)
        }
        setPanels(sidebar: true, inspector: true, log: .shown)
        XCTAssertTrue(requestLogDrawer.waitForRowCount(3, timeout: 15), "The requests should reach the log")
        sweepPanels("request log")

        workspace.fillWindow()
        setPanels(sidebar: true, inspector: true, log: .shown)
        requestLogDrawer.distinctRows(limit: 1).first?.click()
        XCTAssertTrue(requestDetail.waitForDetail(), "Clicking a logged request opens it in the centre column")
        for size in WindowSize.allCases {
            resize(to: size)
            for sidebar in [true, false] {
                setSidebar(sidebar)
                settle()
                capture("request detail", size: size, panels: panelKey())
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
        workspace.fillWindow()
        createEndpointViaUI(name: "List users", path: "/users")
        setPanels(sidebar: true, inspector: true, log: .shown)
        let before = anchors()

        let trips: [(String, @MainActor () -> Void)] = [
            ("switching to Journeys and back", {
                WorkspaceShellPage(app: self.app).journeysTab.click()
                _ = JourneysNavigatorPage(app: self.app).waitUntilVisible()
                WorkspaceShellPage(app: self.app).endpointsTab.click()
                _ = self.workspace.addEndpointButton.waitForExistence(timeout: 5)
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
            settle()
            let after = anchors()
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
            capture("after \(trip)", size: .fill, panels: panelKey())
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
            resize(to: size)
            var seen: Set<String> = []
            let arrangements = size == .short ? [Self.arrangements[0]] : Self.arrangements
            for arrangement in arrangements {
                setPanels(sidebar: arrangement.sidebar, inspector: arrangement.inspector, log: arrangement.log)
                let key = panelKey(log: arrangement.log)
                guard seen.insert(key).inserted else { continue }
                capture(state, size: size, panels: key)
            }
            // Leave the log at its usual height for the next width.
            setLog(.shown)
            dragLog(toHeight: 220)
        }
        resize(to: .fill)
    }

    @MainActor
    private func resize(to size: WindowSize) {
        let window = app.windows.firstMatch
        switch size {
        case .fill: workspace.fillWindow()
        case .compact: app.typeKey("c", modifierFlags: [.command, .option, .control])
        case .minimum: app.typeKey("n", modifierFlags: [.command, .option, .control])
        case .short: app.typeKey("t", modifierFlags: [.command, .option, .control])
        }
        UITestApp.waitForStableFrame(window)
        settle()
    }

    @MainActor
    private func setPanels(sidebar: Bool, inspector: Bool, log: LogState) {
        setSidebar(sidebar)
        setInspector(inspector)
        setLog(log)
    }

    private func pane(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    /// A pane's frame while it is on screen: present, wider and taller than a sliver, and inside
    /// the window. A collapsed split view column can stay in the tree at zero width or off screen.
    @MainActor
    private func shownFrame(_ identifier: String) -> CGRect? {
        let element = pane(identifier)
        guard element.exists, let frame = (try? element.snapshot())?.frame else { return nil }
        let window = app.windows.firstMatch.frame
        let visible = frame.intersection(window)
        guard !visible.isNull, visible.width > 20, visible.height > 20 else { return nil }
        return frame
    }

    @MainActor
    private func setSidebar(_ shown: Bool) {
        guard (shownFrame("sidebar") != nil) != shown else { return }
        let title = shown ? "Show Sidebar" : "Hide Sidebar"
        let button = app.toolbars.buttons[title].firstMatch
        if button.exists, button.isHittable {
            button.click()
        } else {
            app.menuBars.menuBarItems["View"].click()
            let item = app.menuItems[title].firstMatch
            if item.waitForExistence(timeout: 2) {
                item.click()
            } else {
                UITestApp.dismissAnyOpenMenu(in: app)
                app.typeKey("s", modifierFlags: [.control, .command])
            }
        }
        _ = UITestApp.waitUntil(timeout: 5) { (self.shownFrame("sidebar") != nil) == shown }
        settle()
    }

    /// The inspector, through View ▸ Inspector (⌥⌘I). An empty project or an open request hides it
    /// whatever is asked, so this gives up quietly; `panelKey` records what was reached.
    @MainActor
    private func setInspector(_ shown: Bool) {
        guard (shownFrame("inspector") != nil) != shown else { return }
        app.typeKey("i", modifierFlags: [.command, .option])
        _ = UITestApp.waitUntil(timeout: 3) { (self.shownFrame("inspector") != nil) == shown }
        settle()
    }

    @MainActor
    private func setLog(_ state: LogState) {
        let shown = state != .hidden
        if (shownFrame("drawer") != nil) != shown {
            app.typeKey("l", modifierFlags: [.command, .option])
            _ = UITestApp.waitUntil(timeout: 3) { (self.shownFrame("drawer") != nil) == shown }
            settle()
        }
        switch state {
        case .minimum: dragLog(toHeight: 162)
        case .maximum: dragLog(toHeight: 4000)
        case .hidden, .shown: break
        }
    }

    /// Drags the divider between the centre pane and the request log so the log is `height` tall,
    /// as far as the split view allows: its own floor below, the centre pane's floor above.
    @MainActor
    private func dragLog(toHeight height: CGFloat) {
        guard let current = logPaneHeight(), abs(current - height) > 4,
              let centre = shownFrame("centerPane") else { return }
        let window = app.windows.firstMatch
        let frame = window.frame
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
        UITestApp.waitForStableFrame(pane("drawer"))
        settle()
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

    @MainActor
    private func logPaneHeight() -> CGFloat? {
        Self.logPaneHeight(
            centre: shownFrame("centerPane"), split: shownFrame(Self.logSplitIdentifier), drawer: shownFrame("drawer")
        )
    }

    /// Waits for the panes to stop moving: panel animations run after the command that starts them.
    @MainActor
    private func settle() {
        // The toolbar too: AppKit lays its items out again after the panes move, and a frame taken
        // in between shows items on top of each other that a moment later are not.
        for identifier in ["centerPane", "drawer", "inspector", "sidebar", "toolbar.projectIdentity", "serverStatusWell.url"]
        where pane(identifier).exists {
            UITestApp.waitForStableFrame(pane(identifier), timeout: 1)
        }
    }

    /// The arrangement actually on screen, which is what a frame is labelled with.
    @MainActor
    private func panelKey(log: LogState? = nil) -> String {
        let logLabel: String
        if let log, log == .minimum || log == .maximum, let height = logPaneHeight() {
            logLabel = "log \(log.rawValue) \(LayoutAudit.format(height))pt"
        } else {
            logLabel = shownFrame("drawer") == nil ? "no log" : "log"
        }
        return [
            shownFrame("sidebar") == nil ? "no navigator" : "navigator",
            shownFrame("inspector") == nil ? "no inspector" : "inspector",
            logLabel,
        ].joined(separator: ", ")
    }

    @MainActor
    private func anchors() -> [String: CGRect] {
        var result: [String: CGRect] = [:]
        let names = ["navigator": "sidebar", "centre pane": "centerPane", "inspector": "inspector",
                     "request log": "drawer", "project name": "toolbar.projectIdentity"]
        for (name, identifier) in names {
            if let frame = shownFrame(identifier) { result[name] = frame }
        }
        if let window = (try? app.windows.firstMatch.snapshot())?.frame { result["window"] = window }
        return result
    }

    static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    // MARK: - Capturing a frame

    private func startAudit(_ name: String) {
        recorder = LayoutAuditRecorder(test: name)
    }

    @MainActor
    private func capture(_ state: String, size: WindowSize, panels: String) {
        let window = app.windows.firstMatch
        UITestApp.waitForStableFrame(window)
        guard let snapshot = try? window.snapshot() else {
            errors.append("\(state) at \(size.rawValue): the window could not be read")
            return
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
