import AppKit
import Foundation
import XCTest

@MainActor
struct NavigatorPage {
    let app: XCUIApplication

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    /// The navigator's pane, which holds every row. The `CONTAINS` queries below search it rather
    /// than the whole window, which is the shape of query that has timed XCUITest's engine out.
    var pane: XCUIElement { app.container(named: "sidebar") }
    var header: XCUIElement { element("navigator.header") }
    var footer: XCUIElement { element("navigator.footer") }
    var endpointFilter: XCUIElement { app.textFields["sidebar.filter.field"] }
    var endpointFilterClear: XCUIElement { app.buttons["sidebar.filter.clear"] }
    var journeyFilter: XCUIElement { app.textFields["journeys.filter.field"] }
    var noEndpointMatches: XCUIElement { element("sidebar.noMatches") }
    var noJourneyMatches: XCUIElement { element("journeys.noMatches") }
    var journeyGroupField: XCUIElement { app.textFields["journeyEditor.groupTag"] }
    func journeyGroup(_ name: String) -> XCUIElement { element("journeys.group.\(name)") }
    /// The active journey's row: it speaks ", active". Only in the tree on the Journeys tab.
    var activeJourney: XCUIElement {
        pane.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "journeys.row.", ", active"
        )).firstMatch
    }
    /// Journeys ▸ Show Active Journey. The navigator's footer holds only the filter and Add.
    func showActiveJourneyFromMenu() {
        app.menuBars.menuBarItems["Journeys"].click()
        let item = app.menuItems["Show Active Journey"].firstMatch
        XCTAssertTrue(item.waitToExist(timeout: 5), "Journeys ▸ Show Active Journey should be listed")
        item.click()
    }
    var methodScope: XCUIElement { app.menuButtons["sidebar.filter.scope"].firstMatch }

    func row(named name: String) -> XCUIElement {
        pane.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS %@",
            "endpoint-", "journeys.row.", name
        )).firstMatch
    }
    func endpointRow(named name: String, path: String) -> XCUIElement {
        pane.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "endpoint-", name, path
        )).firstMatch
    }
    func rowHeight(named name: String) -> CGFloat {
        outlineRow(named: name).frame.height
    }
    func outlineRow(named name: String) -> XCUIElement {
        app.descendants(matching: .outlineRow)
            .containing(.any, identifier: row(named: name).identifier).firstMatch
    }
    func group(_ name: String) -> XCUIElement {
        let identified = element("sidebar.group.\(name)")
        if identified.exists { return identified }
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@", "Collapse \(name)", "Expand \(name)"
        )).firstMatch
    }
    func scopeOption(_ name: String) -> XCUIElement { app.menuItems[name].firstMatch }
    /// Waits for the field to be hittable first: the journey editor's group field is disclosed into a
    /// scroll view, and a click before it has scrolled into view lands on whatever is there instead.
    func filter(_ field: XCUIElement, text: String) {
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { field.exists && field.isHittable },
                      "The field should be on screen before it is edited")
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText(text.isEmpty ? XCUIKeyboardKey.delete.rawValue : text)
    }
    func screenshot(_ name: String) -> XCTAttachment {
        let result = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        result.name = name
        result.lifetime = .keepAlways
        return result
    }
}

/// Fixtures use the production control API with an explicit per-test credential and store.
/// An authenticated state reply must identify a freshly launched Mimic before setup can mutate it.
final class NavigatorUITests: MimicUITestCase {
    private let fixtureID = UUID().uuidString
    private let fixtureToken = UUID().uuidString + UUID().uuidString
    private let controlPort = 62170
    private var usesLightAppearance = false
    private var launchStarted = Date.distantFuture
    private var verifiedFixture = false

    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += ["-AppleInterfaceStyle", usesLightAppearance ? "Light" : "Dark",
                                "-NSRequiresAquaSystemAppearance", usesLightAppearance ? "YES" : "NO"]
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = String(controlPort)
        app.launchEnvironment["MIMIC_CONTROL_TOKEN"] = fixtureToken
        // The sandboxed app expands ~ itself. No runner access to its protected container is needed.
        let base = "~/Library/Application Support/devxa.Mimic/navigator-uitest-\(fixtureID)"
        app.launchEnvironment["MIMIC_CONTROL_FILE"] = base + ".json"
        app.launchEnvironment["MIMIC_DATABASE_PATH"] = base + ".sqlite"
    }

    @MainActor
    private func response(_ command: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(controlPort)/v1/command")))
        request.httpMethod = "POST"
        request.timeoutInterval = 2
        request.setValue(fixtureToken, forHTTPHeaderField: "X-Mimic-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["ok"] as? Bool == true,
              let result = envelope["result"] as? [String: Any] else {
            throw NSError(domain: "NavigatorFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture command was refused"])
        }
        return result
    }

    @MainActor
    @discardableResult
    private func command(_ command: [String: Any]) async throws -> [String: Any] {
        guard verifiedFixture else { throw NSError(domain: "NavigatorFixture", code: 2) }
        return try await response(command)
    }

    @MainActor
    private func launchFixture(populated: Bool = true) async throws {
        launchStarted = Date()
        launchApp()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let result = try? await response(["state": [:]]),
               let state = result["state"] as? [String: Any], let pid = state["pid"] as? Int,
               let process = NSRunningApplication(processIdentifier: pid_t(pid)),
               process.bundleIdentifier == "devxa.Mimic", let date = process.launchDate,
               date >= launchStarted {
                verifiedFixture = true
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(verifiedFixture, "The authenticated fixture must identify the newly launched app")
        try await command(["projectCreate": ["name": "Navigator Review", "port": 62171]])
        workspace.fillWindow()
        workspace.showSidebarIfNeeded()
        guard populated else { return }
        // Literal inputs deliberately include identical methods/paths, long paths, and a non-GET method.
        for (name, method, path, group) in [
            ("Account summary", "GET", "/account-summary", "Account"),
            ("Current orders", "GET", "/api/v1/orders", "Orders"),
            ("Archived orders", "GET", "/api/v1/orders", "Orders"),
            ("Create order", "POST", "/api/v1/orders", "Orders"),
            ("Payment authorizations", "OPTIONS", "/api/v1/organizations/{organizationId}/payments/{paymentId}/authorizations", "Payments")
        ] {
            try await command(["endpointCreate": ["name": name, "method": method, "path": path, "spec": ["groupTag": group]]])
        }
        try await command(["journeyAddTemplate": ["templateID": "payment-retry", "name": "Payment succeeds after the second authorization attempt"]])
        try await command(["journeyCreate": ["name": "Empty journey"]])
        XCTAssertTrue(NavigatorPage(app: app).row(named: "Account summary").waitToExist(timeout: 5))
    }

    /// An element's frame once two readings a poll apart agree, for a geometry assertion.
    ///
    /// Read straight after a resize or a tab switch, a row or a field can report a frame it is about
    /// to leave: this file's journey-group spacing assertion once read 26pt against 28pt on CI, on a
    /// tree that passed elsewhere. Falls back to a plain read when the frame never holds still, so a
    /// control that keeps moving fails the assertion with the frame it had.
    @MainActor
    private func settledFrame(of element: XCUIElement) -> CGRect {
        UITestApp.waitForStableFrame(element) ?? element.frame
    }

    @MainActor
    func testInspectorIdentityFollowsEndpointSelection() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let identity = navigator.element("inspector.endpointIdentity")

        navigator.row(named: "Account summary").click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            identity.label.contains("GET method /account-summary")
        }, "The inspector must announce the selected GET route")

        navigator.row(named: "Create order").click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            identity.label.contains("POST method /api/v1/orders")
        }, "The inspector must not announce the previous endpoint's path")
    }

    @MainActor
    func testEndpointKeyboardRenameAndRequestEditing() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Account")
        XCTAssertEqual(navigator.endpointFilter.value as? String, "Account",
                       "Command-F should focus the current navigator filter")
        navigator.filter(navigator.endpointFilter, text: "")
        let account = navigator.row(named: "Account summary")
        account.click()
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(navigator.outlineRow(named: "Current orders").isSelected,
                      "Down should select the next visible endpoint")
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(navigator.outlineRow(named: "Account summary").isSelected,
                      "Up should return to the previous endpoint")

        account.rightClick()
        app.menuItems["sidebar.contextMenu.rename"].click()
        let name = app.textFields["ds.textfield.endpointRename.name"]
        XCTAssertTrue(name.waitToExist(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Account overview")
        app.buttons["endpointRename.confirm"].click()
        let renamed = navigator.row(named: "Account overview")
        XCTAssertTrue(renamed.waitToExist(timeout: 5))

        renamed.rightClick()
        app.menuItems["sidebar.contextMenu.editRequest"].click()
        let path = app.textFields["ds.textfield.endpointRequest.path"]
        XCTAssertTrue(path.waitToExist(timeout: 5))
        path.click()
        path.typeKey("a", modifierFlags: .command)
        path.typeText("/account-overview")
        app.buttons["endpointRequest.save"].click()
        XCTAssertTrue(navigator.endpointRow(named: "Account overview", path: "/account-overview")
            .waitToExist(timeout: 5))
        let identity = navigator.element("inspector.endpointIdentity")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            identity.label.contains("GET method /account-overview")
        }, "The inspector should announce the edited path for the same endpoint")

        let scenario = navigator.element("inspector.scenario.Default")
        XCTAssertTrue(scenario.waitToExist(timeout: 5))
        scenario.rightClick()
        app.menuItems["inspector.scenario.contextMenu.rename"].click()
        let scenarioName = app.textFields["ds.textfield.scenarioRename.name"]
        XCTAssertTrue(scenarioName.waitToExist(timeout: 5))
        scenarioName.click()
        scenarioName.typeKey("a", modifierFlags: .command)
        scenarioName.typeText("Success")
        app.buttons["scenarioRename.confirm"].click()
        XCTAssertTrue(navigator.element("inspector.scenario.Success").waitToExist(timeout: 5))

        let edited = navigator.row(named: "Account overview")
        edited.click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["ds.textfield.endpointRename.name"].waitToExist(timeout: 5),
                      "Return should offer to rename the selected endpoint")
        app.buttons["endpointRename.cancel"].click()
        edited.click()
        app.typeKey(.delete, modifierFlags: [])
        let endpointDeleteSheet = app.sheets.firstMatch
        XCTAssertTrue(endpointDeleteSheet.buttons["Delete endpoint"].waitToExist(timeout: 5),
                      "Delete should confirm before removing the selected endpoint")
        endpointDeleteSheet.buttons["Cancel"].click()
        XCTAssertTrue(edited.exists)
    }

    @MainActor
    func testJourneyKeyboardNavigationAndContextRename() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        app.buttons["navigator.tab.journeys"].click()
        app.typeKey("f", modifierFlags: .command)
        app.typeText("Empty")
        XCTAssertEqual(navigator.journeyFilter.value as? String, "Empty",
                       "Command-F should follow the selected navigator")
        navigator.filter(navigator.journeyFilter, text: "")
        let empty = navigator.row(named: "Empty journey")
        XCTAssertTrue(empty.waitToExist(timeout: 5))
        empty.click()
        app.typeKey(.upArrow, modifierFlags: [])
        XCTAssertTrue(navigator.outlineRow(named: "Payment succeeds").isSelected,
                      "Up should select the previous visible journey")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertTrue(navigator.outlineRow(named: "Empty journey").isSelected,
                      "Down should return to the empty journey")

        empty.rightClick()
        app.menuItems["journeys.contextMenu.rename"].click()
        let name = app.textFields["ds.textfield.journeyRename.name"]
        XCTAssertTrue(name.waitToExist(timeout: 5))
        name.click()
        name.typeKey("a", modifierFlags: .command)
        name.typeText("Renamed journey")
        app.buttons["journeyRename.confirm"].click()
        let renamed = navigator.row(named: "Renamed journey")
        XCTAssertTrue(renamed.waitToExist(timeout: 5))
        renamed.click()
        // The description is edited in the journey's inspector while no step is selected.
        let summary = app.textFields["journeyEditor.summaryField"]
        XCTAssertTrue(summary.waitToExist(timeout: 5))
        summary.click()
        summary.typeText("Fallback sequence")
        summary.typeKey(.return, modifierFlags: [])
        XCTAssertEqual(summary.value as? String, "Fallback sequence")
        renamed.click()
        app.typeKey(.delete, modifierFlags: [])
        let journeyDeleteSheet = app.sheets.firstMatch
        XCTAssertTrue(journeyDeleteSheet.buttons["Delete"].waitToExist(timeout: 5),
                      "Delete should confirm before removing the selected journey")
        journeyDeleteSheet.buttons["Cancel"].click()
        XCTAssertTrue(renamed.exists)
    }

    /// The editor has no options disclosure and no scroll view any more: the status, delay and
    /// content type sit in one fields row that is always visible, the body and the headers share
    /// the space below through a Body/Headers switch, and the group tag lives in the inspector.
    @MainActor
    func testEndpointEditorUsesTheWorkspaceAndKeepsOptionsAccessibleAtBothWidths() async throws {
        try await launchFixture()
        try await command(["scenarioUpdate": [
            "endpoint": ["name": "Account summary"], "scenario": ["name": "Default"],
            "spec": ["body": "{\n  \"id\": \"account-001\",\n  \"name\": \"Demo account\",\n  \"plan\": \"Pro\"\n}"]
        ]])
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        navigator.row(named: "Account summary").click()
        if workspace.drawerEmptyHeading.exists {
            app.typeKey("l", modifierFlags: [.command, .option])
            XCTAssertTrue(workspace.drawerEmptyHeading.waitToDisappear(timeout: 5))
        }
        let centre = shell.panel("centerPane")
        XCTAssertTrue(endpointEditor.bodyEditor.waitToExist(timeout: 5))
        XCTAssertTrue(endpointEditor.bodyTab.isSelected, "The editor opens on the Body pane")
        // The editor pads its content by `DSSpacing.xl` (20pt) on both sides and `DSSpacing.lg`
        // (16pt) below, and the card pads its text inside that. With the request log hidden, the
        // body takes the pane down to those margins however few lines it holds, so hiding the log
        // leaves no empty space under it.
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            self.endpointEditor.bodyEditor.frame.width >= centre.frame.width - 42
                && self.endpointEditor.bodyEditor.frame.height >= 110
                && centre.frame.maxY - self.endpointEditor.bodyEditor.frame.maxY <= 40
        }, "The body should span the pane's width and reach down to its bottom margin — it is "
            + "\(endpointEditor.bodyEditor.frame) in a centre pane of \(centre.frame)")
        XCTAssertEqual(endpointEditor.bodyEditor.frame.minX - centre.frame.minX, 20, accuracy: 1)
        XCTAssertEqual(centre.frame.maxX - endpointEditor.bodyEditor.frame.maxX, 20, accuracy: 1)
        XCTAssertTrue(endpointEditor.statusDescription.label.contains("OK") ||
                      (endpointEditor.statusDescription.value as? String)?.contains("OK") == true)
        for (field, name) in [(endpointEditor.statusCodeField, "status"), (endpointEditor.delayField, "delay"),
                              (endpointEditor.contentTypeMenu, "content type")] {
            XCTAssertTrue(field.waitToExist(timeout: 5), "The \(name) control is always in the fields row")
            XCTAssertTrue(field.isHittable, "The \(name) control needs no disclosure to reach")
        }
        let groupTag = inspector.groupTagField
        XCTAssertTrue(groupTag.waitToExist(timeout: 5), "The group tag is in the inspector's Endpoint section")
        XCTAssertEqual(groupTag.value as? String, "Account")
        XCTAssertFalse(endpointEditor.addHeaderButton.exists, "Headers are behind their own segment")
        add(navigator.screenshot("endpoint-editor-wide"))

        endpointEditor.showHeaders()
        XCTAssertTrue(endpointEditor.headersEmptyNote.waitToExist(timeout: 5))
        XCTAssertTrue(endpointEditor.bodyEditor.waitToDisappear(timeout: 5),
                      "The headers pane takes the body's place rather than stacking under it")
        endpointEditor.addHeaderButton.click()
        XCTAssertTrue(endpointEditor.headerKeyField(at: 0).waitToExist(timeout: 5))
        endpointEditor.headerKeyField(at: 0).click()
        endpointEditor.headerKeyField(at: 0).typeText("X-Request-Source")
        endpointEditor.headerValueField(at: 0).click()
        endpointEditor.headerValueField(at: 0).typeText("Mimic")
        endpointEditor.headerValueField(at: 0).typeKey(.return, modifierFlags: [])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { self.endpointEditor.headersTab.label == "Headers, 1" },
                      "The Headers segment should count its rows — label: \(endpointEditor.headersTab.label)")
        add(navigator.screenshot("endpoint-editor-headers-wide"))

        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertGreaterThanOrEqual(endpointEditor.headerKeyField(at: 0).frame.minX, centre.frame.minX)
        XCTAssertLessThanOrEqual(endpointEditor.headerValueField(at: 0).frame.maxX, centre.frame.maxX)
        for (field, name) in [(endpointEditor.statusCodeField, "status"), (endpointEditor.delayField, "delay"),
                              (endpointEditor.contentTypeMenu, "content type")] {
            XCTAssertTrue(field.isHittable, "The \(name) control stays reachable in a narrow window")
            XCTAssertLessThanOrEqual(field.frame.maxX, centre.frame.maxX,
                                     "The \(name) control must not run past the centre pane")
        }
        if InspectorPage(app: app).header.exists {
            XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { groupTag.isHittable },
                          "The inspector's group tag should stay reachable in a narrow window")
        }
        add(navigator.screenshot("endpoint-editor-headers-narrow"))
        endpointEditor.showBody()
        // `EditorMetrics.bodyMinHeight`.
        XCTAssertGreaterThanOrEqual(endpointEditor.bodyEditor.frame.height, 120)
        XCTAssertTrue(endpointEditor.prettyPrintButton.isHittable)
        add(navigator.screenshot("endpoint-editor-narrow"))

        endpointEditor.delayField.click()
        endpointEditor.delayField.typeKey("a", modifierFlags: .command)
        endpointEditor.delayField.typeText("250")
        endpointEditor.delayField.typeKey(.return, modifierFlags: [])
        navigator.row(named: "Current orders").click()
        navigator.row(named: "Account summary").click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { self.endpointEditor.delayField.value as? String == "250" },
                      "The delay should have been committed to the endpoint")
        endpointEditor.showHeaders()
        XCTAssertEqual(endpointEditor.headerValueField(at: 0).value as? String, "Mimic", "Existing headers reopen as a table")
    }

    @MainActor
    func testSharedGeometryFilteringAndDisclosureAtWideAndNarrowWidths() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        workspace.fillWindow()
        // Measured once the navigator has stopped moving, see `settledFrame(of:)`.
        let endpointFooter = settledFrame(of: navigator.footer)
        let endpointFilterMidY = settledFrame(of: navigator.endpointFilter).midY
        let endpointHeader = settledFrame(of: navigator.header)
        let endpointRowHeight = settledFrame(of: navigator.outlineRow(named: "Account summary")).height
        let endpointFilterMinX = navigator.endpointFilter.frame.minX
        let addEndpoint = navigator.element("sidebar.addEndpointButton")
        // The footer is filter then "+", 8pt apart (`DSSpacing.sm`), inside 10pt of padding.
        XCTAssertLessThanOrEqual(navigator.endpointFilter.frame.maxX, addEndpoint.frame.minX)
        XCTAssertLessThanOrEqual(addEndpoint.frame.minX - navigator.endpointFilter.frame.maxX, 24,
                                 "Inactive journey controls must not leave an empty slot beside the filter")
        XCTAssertEqual(navigator.footer.frame.maxX - addEndpoint.frame.maxX, 10, accuracy: 1)
        // `DSNavigatorMetrics.rowPitch`: the 28pt `DSRowHeight.list` row and the 2pt gap between rows.
        XCTAssertEqual(endpointRowHeight, 30, accuracy: 1)
        XCTAssertEqual(navigator.group("Account").frame.minX, navigator.row(named: "Account summary").frame.minX,
                       accuracy: 1, "Group headings and rows share the navigator's row inset")
        XCTAssertTrue(navigator.row(named: "Current orders").exists)
        XCTAssertTrue(navigator.row(named: "Archived orders").exists)
        navigator.group("Orders").click()
        XCTAssertTrue(navigator.row(named: "Current orders").waitToDisappear(timeout: 5))
        navigator.group("Orders").click()
        XCTAssertTrue(navigator.row(named: "Current orders").waitToExist(timeout: 5))
        navigator.row(named: "Account summary").click()
        add(navigator.screenshot("navigator-endpoints-wide"))

        navigator.filter(navigator.endpointFilter, text: "missing-route")
        XCTAssertTrue(navigator.noEndpointMatches.waitToExist(timeout: 5))
        XCTAssertEqual(navigator.footer.frame.minY, endpointFooter.minY, accuracy: 1)
        navigator.filter(navigator.endpointFilter, text: "Current orders")
        XCTAssertTrue(navigator.row(named: "Current orders").waitToExist(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Archived orders").exists)

        shell.journeysTab.click()
        XCTAssertTrue(navigator.journeyFilter.waitToExist(timeout: 5))
        let journeyFilter = settledFrame(of: navigator.journeyFilter)
        XCTAssertEqual(navigator.header.frame.midY, endpointHeader.midY, accuracy: 1)
        XCTAssertEqual(journeyFilter.midY, endpointFilterMidY, accuracy: 1)
        XCTAssertEqual(journeyFilter.minX, endpointFilterMinX, accuracy: 1,
                       "Both navigators put the filter in the same place")
        let addJourney = JourneysNavigatorPage(app: app).addButton
        XCTAssertLessThanOrEqual(navigator.journeyFilter.frame.maxX, addJourney.frame.minX)
        XCTAssertEqual(navigator.footer.frame.maxX - addJourney.frame.maxX, 10, accuracy: 1)
        XCTAssertEqual(settledFrame(of: navigator.outlineRow(named: "Empty journey")).height, endpointRowHeight,
                       accuracy: 1)
        navigator.filter(navigator.journeyFilter, text: "authorization")
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitToExist(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Empty journey").exists)
        navigator.row(named: "Payment succeeds").click()
        XCTAssertFalse(navigator.activeJourney.exists, "Selection must not start a journey")
        add(navigator.screenshot("navigator-journeys-wide"))
        navigator.filter(navigator.journeyFilter, text: "missing-journey")
        XCTAssertTrue(navigator.noJourneyMatches.waitToExist(timeout: 5))
        shell.endpointsTab.click()
        XCTAssertEqual(navigator.endpointFilter.value as? String, "Current orders")
        navigator.filter(navigator.endpointFilter, text: "")
        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(navigator.endpointFilter.isHittable)
        add(navigator.screenshot("navigator-narrow-editor-edge"))
        XCTAssertGreaterThanOrEqual(endpointEditor.moreMenu.frame.minX, shell.panel("centerPane").frame.minX,
                                    "A narrow editor must keep its leading content — the method menu — visible")
        XCTAssertTrue(shell.endpointsTab.isHittable)
        XCTAssertTrue(shell.journeysTab.isHittable)
        XCTAssertTrue(workspace.addEndpointButton.isHittable)
        XCTAssertTrue(navigator.row(named: "Payment authorizations").exists)
        add(navigator.screenshot("navigator-endpoints-narrow"))
        shell.journeysTab.click()
        XCTAssertEqual(navigator.journeyFilter.value as? String, "missing-journey")
        navigator.filter(navigator.journeyFilter, text: "")
        XCTAssertTrue(navigator.row(named: "Payment succeeds").isHittable)
        add(navigator.screenshot("navigator-journeys-narrow"))
    }

    @MainActor
    // Row height, group height and inset are checked by the `journeys.navigator` and
    // `workspace.navigator` gallery snapshots (GallerySnapshotTests), not here: as frame assertions
    // in a live window they failed three times on main with no product change.
    func testJourneyGroupsSupportEditingAndReveal() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        try await command(["journeyUpdate": ["journey": ["name": "Payment succeeds after the second authorization attempt"], "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Payment declined", "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Session expired", "spec": ["groupTag": "Account"]]])
        shell.journeysTab.click()
        XCTAssertTrue(navigator.journeyGroup("Checkout").waitToExist(timeout: 5))
        XCTAssertEqual(navigator.journeyGroup("Checkout").value as? String, "2 journeys")
        navigator.journeyGroup("Checkout").click()
        XCTAssertTrue(navigator.row(named: "Payment declined").waitToDisappear(timeout: 5))
        shell.endpointsTab.click()
        shell.journeysTab.click()
        XCTAssertFalse(navigator.row(named: "Payment declined").exists, "Collapse survives switching tabs")
        navigator.filter(navigator.journeyFilter, text: "Checkout")
        XCTAssertTrue(navigator.row(named: "Payment declined").waitToExist(timeout: 5), "Filtering reveals matches inside a collapsed group")
        XCTAssertFalse(navigator.row(named: "Session expired").exists)
        navigator.filter(navigator.journeyFilter, text: "")
        navigator.row(named: "Empty journey").click()
        // The group is edited in the journey's inspector while no step is selected.
        XCTAssertTrue(navigator.journeyGroupField.waitToExist(timeout: 5))
        navigator.filter(navigator.journeyGroupField, text: "Checkout")
        navigator.journeyGroupField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { navigator.journeyGroup("Checkout").value as? String == "3 journeys" })
        navigator.filter(navigator.journeyGroupField, text: "Account")
        navigator.journeyFilter.click() // Blur commits, as it does for endpoint groups.
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { navigator.journeyGroup("Account").value as? String == "2 journeys" })
        navigator.filter(navigator.journeyGroupField, text: "")
        navigator.journeyGroupField.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { navigator.journeyGroup("Account").value as? String == "1 journeys" })
        navigator.journeyGroup("Account").click()
        XCTAssertTrue(navigator.row(named: "Empty journey").exists, "Cleared groups become ungrouped rows")
        navigator.journeyGroup("Account").click()
        navigator.journeyGroup("ungrouped").click()
        XCTAssertTrue(navigator.row(named: "Empty journey").waitToDisappear(timeout: 5))
        let journeys = JourneysNavigatorPage(app: app)
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitToExist(timeout: 5))
        journeys.newEmptyMenuItem.click()
        let newJourney = NewJourneySheetPage(app: app)
        XCTAssertTrue(newJourney.nameField.waitToExist(timeout: 5))
        newJourney.nameField.click()
        newJourney.nameField.typeText("New ungrouped journey")
        newJourney.createButton.click()
        XCTAssertTrue(navigator.row(named: "New ungrouped journey").waitToExist(timeout: 5),
                      "Creating a selected journey must reveal its collapsed Ungrouped section")
        XCTAssertTrue(navigator.row(named: "New ungrouped journey").isHittable)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            journeys.editorName.label.contains("New ungrouped journey")
                || (journeys.editorName.value as? String)?.contains("New ungrouped journey") == true
        }, "The centre pane should edit the newly selected journey")
        try await command(["journeyActivate": ["journey": ["name": "Payment succeeds after the second authorization attempt"]]])
        navigator.journeyGroup("Checkout").click()
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitToDisappear(timeout: 5))
        navigator.showActiveJourneyFromMenu()
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitToExist(timeout: 5))
        XCTAssertTrue(navigator.row(named: "Payment succeeds").label.contains(", active"))
        add(navigator.screenshot("navigator-journeys-grouped-wide"))
        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(navigator.journeyGroup("Checkout").isHittable)
        let firstStep = navigator.element("journeyStep-0")
        XCTAssertTrue(firstStep.waitToExist(timeout: 5))
        XCTAssertTrue(firstStep.isHittable, "The first step must be visible in the initial narrow viewport")
        XCTAssertLessThan(firstStep.frame.minY, shell.panel("centerPane").frame.maxY)
        XCTAssertGreaterThanOrEqual(navigator.element("journeyEditor.unmatchedPicker").frame.minY,
                                    navigator.element("journeyRun.deactivateButton").frame.maxY,
                                    "The behaviour row must follow the run buttons")
        XCTAssertLessThanOrEqual(navigator.element("journeyEditor.unmatchedPicker").frame.maxY, firstStep.frame.minY,
                                 "The behaviour row must sit above the steps")
        add(navigator.screenshot("navigator-journeys-grouped-narrow"))
    }

    @MainActor
    func testLightJourneyEditorShowsStepsBeforeSettingsAtBothWidths() async throws {
        usesLightAppearance = true
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        shell.journeysTab.click()
        navigator.row(named: "Payment succeeds").click()
        let firstStep = navigator.element("journeyStep-0")
        XCTAssertTrue(firstStep.waitToExist(timeout: 5))
        XCTAssertTrue(firstStep.label.contains("First charge declined"), firstStep.label)
        XCTAssertTrue(navigator.element("journeyStep-1").label.contains("Retry accepted"))
        XCTAssertTrue(navigator.element("journeyEditor.matchModePicker").exists,
                      "The behaviour row is always shown above the steps")
        add(navigator.screenshot("journey-editor-light-wide"))

        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(firstStep.waitToExist(timeout: 5))
        XCTAssertTrue(firstStep.isHittable, "The first step should remain visible in light mode at narrow width")
        let secondStep = navigator.element("journeyStep-1")
        // An outline, which is what a SwiftUI `List` is on macOS, under its own name. When anything
        // around the editor named it too, SwiftUI merged that name into the list, the list lost
        // `journeyEditor.stepList`, and this line could find nothing to scroll.
        let stepList = JourneysNavigatorPage(app: app).stepList
        XCTAssertTrue(stepList.waitToExist(timeout: 5),
                      "The steps should keep their own list, journeyEditor.stepList, inside the centre pane")
        // The compact window is 900×677 (CI's screen, pinned for every launch), which leaves the second
        // step below the fold, so the list has to scroll. A negative wheel delta brings up what is
        // below. The loop is bounded and stops as soon as the step is reachable, so it costs nothing
        // where the step is already in view and a list that will not scroll fails below.
        for _ in 0..<3 where !secondStep.isHittable {
            stepList.scroll(byDeltaX: 0, deltaY: -120)
        }
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { secondStep.isHittable },
                      "The second step should be reachable by scrolling the compact step list")
        add(navigator.screenshot("journey-editor-light-narrow"))
    }

    @MainActor
    func testEmptyListsKeepTheSameHeaderFooterAndCreationActions() async throws {
        try await launchFixture(populated: false)
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        XCTAssertTrue(navigator.endpointFilter.waitToExist(timeout: 5))
        XCTAssertTrue(workspace.addEndpointButton.isHittable)
        let header = navigator.header.frame
        let footer = navigator.footer.frame
        shell.journeysTab.click()
        let journeys = JourneysNavigatorPage(app: app)
        XCTAssertTrue(journeys.emptyStateHeading.waitToExist(timeout: 5))
        XCTAssertTrue(journeys.addButton.isHittable)
        XCTAssertTrue(navigator.journeyFilter.isHittable)
        XCTAssertEqual(navigator.header.frame.midY, header.midY, accuracy: 1)
        XCTAssertEqual(navigator.footer.frame.midY, footer.midY, accuracy: 1)
        add(navigator.screenshot("navigator-empty"))
    }

    @MainActor
    func testMethodFilterAndActiveJourneyIndicatorRemainUsable() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        // Chosen through the shared value-picker helper, which reads the scope back from the menu
        // button's value rather than trusting the click.
        let scope = navigator.methodScope
        XCTAssertTrue(
            UITestApp.chooseMenuOption("DELETE", in: scope, of: app) {
                scope.exists && scope.value as? String == "DELETE"
            },
            "The method scope should offer DELETE and switch to it — it reads \(UITestApp.spoken(scope))"
        )
        XCTAssertTrue(navigator.noEndpointMatches.waitToExist(timeout: 5))
        XCTAssertEqual(navigator.methodScope.value as? String, "DELETE")
        XCTAssertTrue(
            UITestApp.chooseMenuOption("POST", in: scope, of: app) {
                scope.exists && scope.value as? String == "POST"
            },
            "The method scope should offer POST and switch to it — it reads \(UITestApp.spoken(scope))"
        )
        XCTAssertTrue(navigator.row(named: "Create order").waitToExist(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Current orders").exists)
        UITestApp.assertAccessibleMenuName(navigator.methodScope, equals: "Filter scope")
        XCTAssertEqual(navigator.methodScope.value as? String, "POST")

        let post = navigator.scopeOption("POST")
        XCTAssertTrue(UITestApp.click(navigator.methodScope, expecting: { post.exists }),
                      "The method scope menu should open and list POST")
        UITestApp.waitForStableFrame(post)
        // NSHostingMenu coverage asserts the native on/off check state directly. Preserve the
        // real app's open menu too: XCTest's isSelected may describe menu highlighting instead.
        let selectedScope = XCTAttachment(screenshot: app.screenshot())
        selectedScope.name = "navigator-selected-POST-scope"
        selectedScope.lifetime = .keepAlways
        add(selectedScope)
        let menuAccessibility = XCTAttachment(string: app.menus.debugDescription)
        menuAccessibility.name = "navigator-filter-menu-accessibility"
        menuAccessibility.lifetime = .keepAlways
        add(menuAccessibility)
        UITestApp.dismissAnyOpenMenu(in: app)

        navigator.row(named: "Create order").click()
        XCTAssertTrue(endpointEditor.statusCodeField.waitToExist(timeout: 5))
        navigator.filter(navigator.endpointFilter, text: "missing-route")
        XCTAssertTrue(navigator.noEndpointMatches.waitToExist(timeout: 5))
        // Move focus away before clearing. The next application keystrokes must return to the
        // query without a field click or a test helper that would focus it on the user's behalf.
        endpointEditor.statusCodeField.click()
        XCTAssertTrue(navigator.endpointFilterClear.waitToExist(timeout: 5))
        XCTAssertEqual(navigator.endpointFilterClear.label, "Clear filter")
        XCTAssertTrue(navigator.endpointFilterClear.isEnabled)
        navigator.endpointFilterClear.click()
        XCTAssertTrue(navigator.endpointFilterClear.waitToDisappear(timeout: 5))
        XCTAssertEqual(navigator.endpointFilter.value as? String, "")
        app.typeText("Create")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            navigator.endpointFilter.value as? String == "Create"
        }, "Clearing a filter should return keyboard focus to its text field")
        XCTAssertTrue(navigator.row(named: "Create order").waitToExist(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Current orders").exists)
        XCTAssertEqual(navigator.methodScope.value as? String, "POST", "Clearing text must preserve its method scope")

        shell.journeysTab.click()
        let name = "Payment succeeds after the second authorization attempt"
        navigator.row(named: name).click()
        let journeys = JourneysNavigatorPage(app: app)
        XCTAssertTrue(journeys.activateButton.waitToExist(timeout: 5))
        let before = navigator.row(named: name).frame
        journeys.activateButton.click()
        XCTAssertTrue(navigator.activeJourney.waitToExist(timeout: 5))
        XCTAssertEqual(navigator.row(named: name).frame, before)
        navigator.filter(navigator.journeyFilter, text: "Empty")
        XCTAssertTrue(navigator.row(named: name).waitToDisappear(timeout: 5))
        navigator.showActiveJourneyFromMenu()
        XCTAssertTrue(navigator.row(named: name).waitToExist(timeout: 5))
        XCTAssertEqual(navigator.journeyFilter.value as? String, "")
        XCTAssertTrue(journeys.deactivateButton.isHittable)
        journeys.advanceButton.click()
        journeys.restartButton.click()
        add(navigator.screenshot("navigator-active-journey"))
        journeys.deactivateButton.click()
        XCTAssertTrue(navigator.activeJourney.waitToDisappear(timeout: 5))
        shell.endpointsTab.click()
        // Waited for, not read at once: the endpoints list redraws after the tab switch.
        XCTAssertTrue(navigator.row(named: "Create order").waitToExist(timeout: 5),
                      "Endpoint method scope survives tab switching")
        XCTAssertEqual(navigator.endpointFilter.value as? String, "Create")
        XCTAssertEqual(navigator.methodScope.value as? String, "POST")
    }

    @MainActor
    func testDisabledEndpointCreateRefusesMouseAndReturnUntilNamed() async throws {
        try await launchFixture(populated: false)
        let navigator = NavigatorPage(app: app)
        workspace.addEndpointButton.click()
        XCTAssertTrue(newEndpointSheet.nameField.waitToExist(timeout: 5))
        XCTAssertTrue(newEndpointSheet.createButton.waitToExist(timeout: 5))
        XCTAssertEqual(newEndpointSheet.createButton.label, "Add endpoint")
        XCTAssertFalse(newEndpointSheet.createButton.isEnabled)

        // Send a real click to the disabled button's surface as well as the default shortcut.
        // The control must stay disabled, keep the sheet open, and leave the project untouched.
        newEndpointSheet.createButton.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(newEndpointSheet.nameField.exists)
        XCTAssertFalse(newEndpointSheet.createButton.isEnabled)
        let refused = try await command(["endpointList": [:]])
        XCTAssertEqual(try XCTUnwrap(refused["endpoints"] as? [[String: Any]]).count, 0)
        add(navigator.screenshot("navigator-disabled-create-endpoint"))

        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText("Keyboard route")
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText("/keyboard-route")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { self.newEndpointSheet.createButton.isEnabled })
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(newEndpointSheet.nameField.waitToDisappear(timeout: 5))
        XCTAssertTrue(navigator.endpointRow(named: "Keyboard route", path: "/keyboard-route").waitToExist(timeout: 5))
        let created = try await command(["endpointList": [:]])
        let endpoints = try XCTUnwrap(created["endpoints"] as? [[String: Any]])
        XCTAssertEqual(endpoints.count, 1, "The enabled default action must create exactly one endpoint")
        XCTAssertEqual(endpoints.first?["name"] as? String, "Keyboard route")
        XCTAssertEqual(endpoints.first?["method"] as? String, "GET")
        XCTAssertEqual(endpoints.first?["path"] as? String, "/keyboard-route")
    }

    /// "When unmatched" is a menu over the endpoint's listener: forwarding needs an upstream, and
    /// choosing Return 404 turns forwarding off without forgetting the upstream.
    @MainActor
    func testWhenUnmatchedMenuSwitchesForwardingForTheListener() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let panel = InspectorPage(app: app)
        navigator.row(named: "Account summary").click()

        let menu = panel.unmatchedBehavior
        XCTAssertTrue(menu.waitToExist(timeout: 5))
        _ = try await command(["serverConfigure": ["upstreamURL": "http://127.0.0.1:65000"]])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { panel.spoken(menu).contains("Forward to upstream") },
                      "An upstream turns forwarding on — \(panel.spoken(menu))")

        // Through the shared value-picker helper: it clicks an item once its frame has settled, at a
        // point it does not look up again, checks the menu's value, and falls back to the keyboard.
        // A click during the menu's opening animation, or at a frame read a moment too early, closes
        // the menu having chosen nothing; this test has failed once on CI on a tree that passed
        // elsewhere.
        XCTAssertTrue(
            UITestApp.chooseMenuOption("Return 404", in: menu, of: app) { panel.spoken(menu).contains("Return 404") },
            "Choosing Return 404 should stop forwarding — \(panel.spoken(menu))"
        )

        // Opened first to read the item itself, then chosen from the menu already open.
        let forward = app.menuItems["Forward to upstream"].firstMatch
        XCTAssertTrue(UITestApp.click(menu, expecting: { forward.exists }), "The menu should offer Forward to upstream")
        XCTAssertTrue(forward.isEnabled, "The kept upstream can be forwarded to again")
        XCTAssertTrue(
            UITestApp.chooseMenuOption("Forward to upstream", in: menu, of: app, menuIsAlreadyOpen: true) {
                panel.spoken(menu).contains("Forward to upstream")
            },
            "Choosing Forward to upstream should turn forwarding back on — \(panel.spoken(menu))"
        )
    }

    /// The scenario list and the Traffic section share one inspector column. The radio makes a
    /// scenario live; the Traffic section counts what the endpoint answered; a logged request opens
    /// in the detail and Back returns to the endpoint with the live scenario unchanged — at both
    /// widths.
    @MainActor
    func testInspectorScenarioActivationAndTrafficReturnAtBothWidths() async throws {
        usesLightAppearance = true
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let panel = InspectorPage(app: app)
        navigator.row(named: "Account summary").click()
        try await command(["scenarioCreate": ["endpoint": ["name": "Account summary"],
                                             "name": "Unauthorized", "spec": ["statusCode": 401, "body": "{\"error\":\"Unauthorized\"}"]]])
        let scenario = panel.scenarioRow(named: "Unauthorized")
        XCTAssertTrue(scenario.waitToExist(timeout: 5))
        // `DSRowHeight.list`.
        XCTAssertEqual(scenario.frame.height, 28, accuracy: 1)
        panel.makeLive(named: "Unauthorized")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { panel.isScenarioActive(named: "Unauthorized") })
        XCTAssertFalse(panel.isScenarioActive(named: "Default"))
        XCTAssertTrue(panel.trafficServed.waitToExist(timeout: 5), "The Traffic figures show before any request")
        XCTAssertTrue(panel.spoken(panel.trafficServed).hasPrefix("0"), "No request has reached the endpoint yet")
        try await command(["serverStart": [:]])
        XCTAssertTrue(workspace.waitForServerURL(port: 62171))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:62171/account-summary")))
        request.timeoutInterval = 5
        for _ in 0..<32 {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
        // A 401 is served, not an error: the section counts 5xx and failures as errors.
        let served = panel.trafficServed
        XCTAssertTrue(served.waitToExist(timeout: 10))
        // On a busy CI runner the accessibility tree caught up with the 32nd request just after a
        // 10 s wait; the count itself is never wrong, so this waits as long as a slow runner needs.
        XCTAssertTrue(UITestApp.waitUntil(timeout: 30) { served.label.hasPrefix("32") },
                      "Served count: \(panel.spoken(served))")
        XCTAssertTrue(panel.spoken(panel.trafficErrors).hasPrefix("0"), panel.spoken(panel.trafficErrors))
        for _ in 0..<4 where !served.isHittable {
            panel.endpointIdentity.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(served.isHittable, "The Traffic section must scroll into reach")
        add(navigator.screenshot("inspector-traffic-wide"))
        let loggedRequest = requestLogDrawer.firstLogRow
        XCTAssertTrue(loggedRequest.waitToExist(timeout: 5))
        loggedRequest.click()
        XCTAssertTrue(requestDetail.waitForDetail())
        XCTAssertTrue(panel.spoken(requestDetail.status).contains("401"))
        XCTAssertEqual(requestDetail.closeButton.label, "Close request")
        XCTAssertTrue(requestDetail.goToEndpointButton.exists, "An answered request links to its endpoint")
        add(navigator.screenshot("request-detail-wide"))
        requestDetail.closeButton.click()
        XCTAssertTrue(scenario.waitToExist(timeout: 5), "Closing returns to the endpoint's scenarios")
        XCTAssertTrue(panel.isScenarioActive(named: "Unauthorized"))

        workspace.compactWindow()
        XCTAssertTrue(panel.addScenarioButton.isHittable)
        XCTAssertEqual(scenario.frame.height, 28, accuracy: 1)
        XCTAssertTrue(panel.liveRadio(named: "Default").isHittable, "The live radio stays reachable when narrow")
        add(navigator.screenshot("inspector-scenarios-narrow"))
        for _ in 0..<4 where !served.isHittable {
            panel.endpointIdentity.scroll(byDeltaX: 0, deltaY: -300)
        }
        XCTAssertTrue(served.isHittable, "The Traffic section must scroll into reach in a narrow window")
        XCTAssertTrue(requestLogDrawer.firstLogRow.waitToExist(timeout: 5))
        requestLogDrawer.firstLogRow.click()
        XCTAssertTrue(requestDetail.closeButton.waitToExist(timeout: 5))
        add(navigator.screenshot("request-detail-narrow"))
        try await command(["serverStop": [:]])
    }

    @MainActor
    func testJourneyInspectorSeparatesSelectionFromTheActiveRun() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let panel = InspectorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        shell.journeysTab.click()
        let activeName = "Payment succeeds after the second authorization attempt"
        navigator.row(named: activeName).click()
        XCTAssertTrue(panel.journeyRow("steps").waitToExist(timeout: 5))
        XCTAssertTrue(panel.spoken(panel.journeyRow("steps")).contains("2"))
        XCTAssertTrue(panel.spoken(panel.journeyRow("state")).contains("Inactive"))
        XCTAssertTrue(panel.journeyRow("noActiveRun").exists)
        try await command(["journeyActivate": ["journey": ["name": activeName]]])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            panel.spoken(panel.journeyRow("state")).contains("Prepared for next server run")
        })
        XCTAssertTrue(navigator.element("journeyRun.progress").waitToExist(timeout: 5))
        XCTAssertTrue(panel.spoken(navigator.element("journeyRun.progress")).contains("Next run"))
        try await command(["journeyAdvance": [:]])
        navigator.row(named: "Empty journey").click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            panel.spoken(panel.journeyRow("steps")).contains("0")
                && panel.spoken(panel.journeyRow("activeName")).contains(activeName)
        })
        XCTAssertTrue(panel.spoken(panel.journeyRow("state")).contains("Inactive"))
        XCTAssertTrue(panel.spoken(panel.journeyRow("progress")).contains("Step 2"))
        XCTAssertTrue(panel.spoken(panel.journeyRow("steps")).contains("0"))
        add(navigator.screenshot("inspector-journey-selection-and-run"))
        workspace.compactWindow()
        XCTAssertTrue(app.windows.firstMatch.frame.contains(panel.journeyRow("steps").frame))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(panel.journeyRow("activeName").frame))
        add(navigator.screenshot("inspector-journey-narrow"))
        try await command(["journeyActivate": [:]])
        XCTAssertTrue(panel.journeyRow("noActiveRun").waitToExist(timeout: 5))
    }
}
