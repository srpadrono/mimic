import AppKit
import Foundation
import XCTest

/// Regenerates the two screenshots `docs/` embeds, from real application state.
///
/// Not a test of behaviour — it asserts only enough to know the frame it captured is the screen it
/// meant to capture. It exists because the docs images had drifted a whole redesign behind the app,
/// and a hand-taken screenshot drifts again the moment anything moves. It now writes four —
/// `workspace` and `journeys`, each `-light` and `-dark` — because the README and the landing page
/// both pick one by theme.
///
/// **Skipped unless `MIMIC_CAPTURE_DOCS=1`.** It writes into the working tree, which no ordinary test
/// run should do, and it is slower than the tests around it. Run it deliberately:
///
/// ```
/// MIMIC_CAPTURE_DOCS=1 xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
///   -destination 'platform=macOS' -only-testing:MimicUITests/DocScreenshotTests
/// ```
///
/// That captures the light pair. `Scripts/capture_doc_screenshots.sh` runs it twice — once per
/// appearance — and lifts all four PNGs out of the result bundles.
///
/// **Grant the runner Documents access before the first run.** macOS raises a TCC prompt —
/// *"MimicUITests-Runner would like to access files in your Documents folder"* — the first time a run
/// touches the checkout, and until someone answers it the test **hangs** rather than failing: the
/// dialog is modal, the runner waits, and `xcodebuild` sits there until it is killed. Worse for this
/// particular test, the prompt is drawn *over the app*, so a capture taken while it is up has a
/// system dialog in the middle of the frame. If a run stalls with no output after the first
/// attachment, look at the screen before looking at the code.
///
/// Two traps are load-bearing here and both cost a full re-run when this was first done:
///
/// 1. **`app.screenshot()` returns the whole display on macOS**, not the app — desktop, Dock, and
///    whatever else is open. `app.windows.firstMatch.screenshot()` is the one that returns the
///    window. The capture helper already in `MimicUITests` uses the former; that is fine for an
///    xcresult attachment and wrong for a published image.
/// 2. **Forcing the appearance needs *two* launch arguments.** `-AppleInterfaceStyle Light` alone
///    does nothing on macOS 26; `-NSRequiresAquaSystemAppearance YES` has to come with it. Both land
///    in `NSArgumentDomain`, which outranks the global domain, so the developer's own desktop
///    appearance is untouched by a run.
final class DocScreenshotTests: MimicUITestCase {

    /// `light` unless `MIMIC_CAPTURE_APPEARANCE=dark` says otherwise.
    ///
    /// It was fixed at Light, per issue #48, when both images went in one README that had one
    /// background. Two consumers now want a pair: the README renders `<picture>` so GitHub's own
    /// theme picks one, and the landing page swaps its screenshot with the site's theme toggle — a
    /// light screenshot on a dark page reads as a hole punched in it.
    ///
    /// The value reaches the *test* process, so it is set as `TEST_RUNNER_MIMIC_CAPTURE_APPEARANCE`
    /// and read here without the prefix, exactly as `MIMIC_CAPTURE_DOCS` is.
    private var appearanceIsDark: Bool {
        ProcessInfo.processInfo.environment["MIMIC_CAPTURE_APPEARANCE"]?.lowercased() == "dark"
    }

    /// The filename suffix, and the only place the two spellings are tied together.
    private var appearanceName: String { appearanceIsDark ? "dark" : "light" }

    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Both arguments, always. `-AppleInterfaceStyle` alone does nothing on macOS 26, and the
        // pair lands in NSArgumentDomain, so a run leaves the developer's own desktop alone.
        app.launchArguments += [
            "-AppleInterfaceStyle", appearanceIsDark ? "Dark" : "Light",
            "-NSRequiresAquaSystemAppearance", appearanceIsDark ? "NO" : "YES",
        ]
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["MIMIC_CAPTURE_DOCS"] == "1",
            "Set MIMIC_CAPTURE_DOCS=1 to regenerate docs/images. Skipped so an ordinary run does not "
                + "write into the working tree."
        )
    }

    /// The port the captured project serves on. Fixed, because it is legible in the toolbar of
    /// every image this produces and a number that moves between runs makes two screenshots taken
    /// weeks apart look like two different products.
    private let capturePort = 8080

    @MainActor
    func testCaptureWorkspaceAndJourneys() async throws {
        launchApp()
        createProjectViaUI(name: "Acme Storefront", port: capturePort)

        // A project that looks like somebody's, not like a fixture.
        //
        // The previous version of this created four endpoints, typed nothing into any of them and
        // captured with the server stopped — so the images showed an empty response body, an empty
        // request log and a "Server stopped" toolbar. Every caption on the README and the landing
        // page describes the opposite, because those captions were written against hand-made
        // screenshots of real use. A screenshot of the app doing nothing is worse than a stale one:
        // it is current *and* it makes the product look like it does not work.
        //
        // So this builds the state the captions actually claim — groups in the sidebar, a body in
        // the editor, a second scenario in the inspector, and traffic in the log including calls
        // nothing matched.
        for endpoint in Self.endpoints {
            createEndpoint(name: endpoint.name, path: endpoint.path, method: endpoint.method)
            setGroupTag(endpoint.group)
        }

        // Account summary is still selected — it was created last — so the editor is already on the
        // endpoint the shot is about. Give it something to answer with.
        setResponseBody(#"{"balance":128.40,"currency":"EUR","pendingOrders":2}"#)

        // A second scenario, so the inspector shows the thing the page is describing: one endpoint
        // holding more than one answer, with one of them active. It is given a 500 because it is
        // called "Server error" — the first version of this left it on the default 200, and a
        // scenario named for a failure that returns success is the kind of detail a reader notices
        // and distrusts the whole screenshot for.
        addScenario(named: "Server error", status: "500")

        startServer(onPort: capturePort)

        // Real traffic. Three of these match nothing, which is the state the request log calls out
        // and the reason the log is worth a screenshot at all.
        let traffic: [(String, String)] = [
            ("GET", "/account-summary"),
            ("GET", "/orders"),
            ("GET", "/orders/A-1042"),
            ("POST", "/checkout"),
            ("GET", "/inbox"),
            ("POST", "/cart/items"),
            ("GET", "/profile/avatar"),
            ("GET", "/notifications"),
        ]
        for (method, path) in traffic {
            await sendRequest(port: capturePort, path: path, method: method)
        }
        // The drawer has no row count to assert on — SwiftUI flattens a row's identifier onto all six
        // of its cells, so counting elements counts cells. The empty state going away is the honest
        // signal that traffic has landed, and the first row existing is the honest signal that it is
        // drawn.
        XCTAssertTrue(
            UITestApp.waitUntil(timeout: 10) { !self.requestLogDrawer.emptyHeading.exists },
            "The request log should have caught up with the traffic before the window is captured"
        )
        XCTAssertTrue(
            requestLogDrawer.firstLogRow.waitForExistence(timeout: 5),
            "The request log should be showing rows before the window is captured"
        )

        // Drop focus before capturing. The status-code field was last edited, and a focused field
        // draws a caret — in a published screenshot that reads as caught mid-edit. A soft click on an
        // inert card title, because failing the capture over a focus ring would be worse than the
        // ring.
        let inert = app.staticTexts["Response headers"].firstMatch
        if inert.exists, inert.isHittable { inert.click() }

        XCTAssertTrue(workspace.assertVisible(), "The workspace should be on screen before capturing it")

        // Let the window settle. A capture taken mid-transition catches a half-drawn panel, and that
        // is the kind of defect nobody notices until the image is in the README.
        //
        // Polled, not paused: `UITestApp.waitForStableFrame` returns as soon as the window reports
        // the same frame twice a poll apart, which is what "settled" actually means. The fixed 1.5s
        // this replaced was both slower than it needed to be on a quiet machine and no guarantee at
        // all on a loaded CI runner — and the house rules forbid it for exactly that reason.
        UITestApp.waitForStableFrame(app.windows.firstMatch)
        try capture(named: "workspace-\(appearanceName).png")

        // Journeys. The navigator tab, not a menu item — the same route a reader of the docs takes.
        let journeys = app.buttons["Show journeys"].firstMatch
        XCTAssertTrue(journeys.waitForExistence(timeout: 5), "The navigator should offer a Journeys tab")
        journeys.click()

        // A journey with steps in it, for the same reason the endpoints above have bodies: the
        // journeys image is meant to show a flow, and an empty journey list shows a placeholder.
        addJourneyTemplate("retry-after-failure", activate: true)

        // And then *run* part of it. The journey is added after the traffic above, so on its own it
        // sits at "Step 1 of 4 — 0 served" — an active journey that has never answered anything.
        // Both documents caption this image as a journey mid-run, with the first steps served and the
        // cursor waiting on the next, so the image has to be of that rather than of an idle one.
        //
        // Two requests: step one answers /login, step two answers /account-summary with the 500 that
        // is the whole point of the template, and the cursor lands on step three.
        await sendRequest(port: capturePort, path: "/login", method: "POST")
        await sendRequest(port: capturePort, path: "/account-summary")
        // Soft, and it prints what it found. A capture walk is evidence gathering: failing the whole
        // run because a progress label is worded differently than expected throws away three good
        // images to protect one detail, and the detail is visible in the image anyway. The first
        // version asserted on the exact words "2 served" and went red without capturing anything.
        let served = UITestApp.waitUntil(timeout: 10) {
            self.app.staticTexts
                .containing(NSPredicate(format: "label CONTAINS[c] %@", "served"))
                .allElementsBoundByIndex
                .contains { !($0.label.contains("0 served")) }
        }
        let progress = app.staticTexts
            .containing(NSPredicate(format: "label CONTAINS[c] %@", "served"))
            .allElementsBoundByIndex
            .map(\.label)
        print("JOURNEY PROGRESS \(served ? "advanced" : "did not advance") — labels: \(progress)")

        UITestApp.waitForStableFrame(app.windows.firstMatch)
        try capture(named: "journeys-\(appearanceName).png")
    }

    /// The project the images show. Four groups, because the sidebar groups by tag and one group is
    /// not a demonstration of grouping.
    /// **Account summary is last on purpose.** `createEndpointViaUI` leaves the endpoint it just made
    /// selected, so creating the featured one last means the editor is already showing it and no
    /// lookup is needed. Selecting it by name did not work: the sidebar row truncates the name, and a
    /// query for it inside the sidebar found nothing.
    private static let endpoints: [(name: String, path: String, method: String, group: String)] = [
        ("Order history", "/orders", "GET", "Account"),
        ("Order detail", "/orders/:id", "GET", "Account"),
        ("Sign in", "/login", "POST", "Auth"),
        ("Sign out", "/logout", "POST", "Auth"),
        ("Inbox", "/inbox", "GET", "Messaging"),
        ("Checkout", "/checkout", "POST", "Orders"),
        ("Account summary", "/account-summary", "GET", "Account"),
    ]


    // MARK: - Building the state the images are of

    /// Types a group tag into the editor, which is what puts an endpoint under a heading in the
    /// sidebar.
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

    /// Puts a JSON body in the response editor.
    ///
    /// Pasted rather than typed: the editor reformats as it goes, and typing a brace makes it insert
    /// the closing one, so typed JSON arrives doubled. The identifier lands on an
    /// `NSViewRepresentable` wrapper, with the text view one level down — both shapes are handled
    /// here for the same reason `EndpointEditorUITests` handles both.
    @MainActor
    private func setResponseBody(_ json: String) {
        let container = app.descendants(matching: .any)
            .matching(identifier: "ds.jsoneditor.editor.body").firstMatch
        let editor = container.exists
            ? (container.descendants(matching: .textView).firstMatch.exists
                ? container.descendants(matching: .textView).firstMatch
                : container)
            : app.textViews.firstMatch

        XCTAssertTrue(editor.waitForExistence(timeout: 5), "The response body editor should be present")
        editor.click()
        editor.typeKey("a", modifierFlags: .command)

        paste(json)
        waitForAsyncSave()
    }

    /// Adds a second scenario to the selected endpoint, so the inspector shows a choice rather than
    /// a single row. It does not activate it — adding never does — which is the state the caption
    /// describes: one active, one not.
    /// Creates an endpoint, **pasting** the path rather than typing it.
    ///
    /// `createEndpointViaUI` types it, and a typed `:` does not survive on every keyboard layout —
    /// `/orders/:id` arrived as `/orders/id`, which silently turned the one endpoint demonstrating
    /// path parameters into a literal, so `GET /orders/A-1042` matched nothing and the request log
    /// showed it as Unmatched. In a screenshot that reads as the product being unable to match its
    /// own route. The pasteboard has no layout, so it cannot lose the character. (This is the same
    /// hazard #65 fixed in the header-refusal test by not asserting on the host's layout.)
    ///
    /// Local to this suite deliberately: the shared helper is used by a dozen tests that pass plain
    /// paths, and changing how they all type is not a change to make for a screenshot.
    @MainActor
    private func createEndpoint(name: String, path: String, method: String) {
        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitForExistence(timeout: 5),
                      "Adding an endpoint should ask for its name")
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText(name)

        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        paste(path)

        if method != "GET" { selectMethod(method) }

        newEndpointSheet.createButton.click()
        XCTAssertTrue(endpointEditor.pathLabel.waitForExistence(timeout: 5),
                      "The editor should open on the new endpoint")
    }

    /// Puts `text` on the pasteboard and presses ⌘V, which is how this suite enters anything a
    /// keyboard layout could mangle.
    @MainActor
    private func paste(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }

    @MainActor
    private func addScenario(named name: String, status: String) {
        // By label, and queried before the sheet opens: the sheet's confirm button answers to the
        // same words, and the header's identifier is swallowed by `DSPanelHeader`'s accessory slot.
        let add = app.buttons["Add scenario"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 5), "The Scenarios header should offer a way to add one")
        add.click()

        XCTAssertTrue(newScenarioSheet.nameField.waitForExistence(timeout: 5),
                      "Adding a scenario should ask for its name first")
        newScenarioSheet.nameField.click()
        newScenarioSheet.nameField.typeText(name)
        newScenarioSheet.createButton.click()

        let row = inspector.scenarioRow(named: name)
        XCTAssertTrue(row.waitForExistence(timeout: 5),
                      "The new scenario should be listed in the inspector")

        // Select it to edit its status, then go back to Default — adding never activates, so Default
        // is still the active one and the shot should show the editor on it, holding the body above.
        row.click()
        let field = endpointEditor.statusCodeField
        XCTAssertTrue(field.waitForExistence(timeout: 5), "The editor should offer a status code field")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(status)
        field.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(endpointEditor.waitForStatusCodeValue(status),
                      "The scenario should be holding \(status)")
        waitForAsyncSave()

        inspector.scenarioRow(named: "Default").click()
        XCTAssertTrue(endpointEditor.waitForStatusCodeValue("200"),
                      "The editor should be back on the default scenario before the capture")
    }

    /// Starts the mock server from the toolbar and waits for the well to report its address, so the
    /// captured toolbar reads as running rather than stopped.
    @MainActor
    private func startServer(onPort port: Int) {
        workspace.serverToggleButton.click()
        XCTAssertTrue(workspace.waitForServerURL(port: port),
                      "The server should report its base URL once running")
    }

    /// Adds one of the bundled journey templates and activates it, so the journeys image shows a
    /// flow with steps in it instead of the empty state.
    @MainActor
    private func addJourneyTemplate(_ id: String, activate: Bool) {
        let journeys = JourneysNavigatorPage(app: app)
        let picker = JourneyTemplatePickerPage(app: app)

        journeys.addButton.click()
        XCTAssertTrue(journeys.templateMenuItem.waitForExistence(timeout: 5),
                      "The add control should offer the template chooser")
        journeys.templateMenuItem.click()

        XCTAssertTrue(picker.addButton.waitForExistence(timeout: 5), "The template picker should open")

        let row = picker.template(id)
        if row.waitForExistence(timeout: 3) { row.click() }

        // The toggle defaults to on; only click when the caller wants the other state.
        if !activate, picker.activateToggle.exists, picker.activateToggle.value as? Int == 1 {
            picker.activateToggle.click()
        }
        picker.addButton.click()
        waitForAsyncSave()
    }

    /// Writes the front window's own image to `docs/images/<name>`, and attaches it to the result
    /// bundle so a CI run keeps the evidence even when the working tree is read-only.
    @MainActor
    private func capture(named name: String) throws {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists, "There should be a window to capture for \(name)")

        let shot = window.screenshot()

        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        // Written to a temp directory, **not** into the repository. The UI-test runner is sandboxed,
        // and a write to `~/Documents/…` from it does not fail cleanly — the first version of this
        // hung there for twenty minutes with the attachment already made. The caller lifts the PNGs
        // out afterwards; `Scripts/capture_doc_screenshots.sh` does it with `xcresulttool`.
        let destination = FileManager.default.temporaryDirectory
            .appendingPathComponent("mimic-doc-screenshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: destination.appendingPathComponent(name))

        // Report the size, because "the two screenshots are the same size" is an acceptance
        // criterion of #48 and an assertion nobody can make by looking at the files later.
        print("CAPTURED \(name) (\(shot.image.size.width)x\(shot.image.size.height))")
    }
}
