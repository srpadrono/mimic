import AppKit
import Foundation
import XCTest

@MainActor
struct NavigatorPage {
    let app: XCUIApplication

    func element(_ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }
    var header: XCUIElement { element("navigator.header") }
    var footer: XCUIElement { element("navigator.footer") }
    var endpointFilter: XCUIElement { app.textFields["sidebar.filter.field"] }
    var journeyFilter: XCUIElement { app.textFields["journeys.filter.field"] }
    var noEndpointMatches: XCUIElement { element("sidebar.noMatches") }
    var noJourneyMatches: XCUIElement { element("journeys.noMatches") }
    var journeyGroupField: XCUIElement { app.textFields["journeyEditor.groupTag"] }
    func journeyGroup(_ name: String) -> XCUIElement { element("journeys.group.\(name)") }
    var activeJourney: XCUIElement { app.buttons["navigator.activeJourney"] }
    var methodScope: XCUIElement { app.menuButtons["sidebar.filter.scope"].firstMatch }

    func row(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "(identifier BEGINSWITH %@ OR identifier BEGINSWITH %@) AND label CONTAINS %@",
            "endpoint-", "journeys.row.", name
        )).firstMatch
    }
    func endpointRow(named name: String, path: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@ AND label CONTAINS %@",
            "endpoint-", name, path
        )).firstMatch
    }
    func rowHeight(named name: String) -> CGFloat {
        app.descendants(matching: .outlineRow)
            .containing(.any, identifier: row(named: name).identifier).firstMatch.frame.height
    }
    func group(_ name: String) -> XCUIElement {
        let identified = element("sidebar.group.\(name)")
        if identified.exists { return identified }
        return app.descendants(matching: .any).matching(NSPredicate(
            format: "label == %@ OR label == %@", "Collapse \(name)", "Expand \(name)"
        )).firstMatch
    }
    func scopeOption(_ name: String) -> XCUIElement { app.menuItems[name].firstMatch }
    func filter(_ field: XCUIElement, text: String) {
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
        XCTAssertTrue(NavigatorPage(app: app).row(named: "Account summary").waitForExistence(timeout: 5))
    }

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
        if requestLogDrawer.emptyHeading.exists { workspace.toggleDrawerButton.click() }
        XCTAssertTrue(endpointEditor.bodyEditor.waitForExistence(timeout: 5))
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            self.endpointEditor.bodyEditor.frame.width >= shell.panel("centerPane").frame.width - 26
                && self.endpointEditor.bodyEditor.frame.height > 200
        }, "The body should fill the available centre pane instead of using a capped form card")
        XCTAssertEqual(endpointEditor.bodyEditor.frame.minX - shell.panel("centerPane").frame.minX, 12, accuracy: 1)
        XCTAssertEqual(shell.panel("centerPane").frame.maxX - endpointEditor.bodyEditor.frame.maxX, 12, accuracy: 1)
        XCTAssertEqual(endpointEditor.optionsToggle.value as? String, "Collapsed")
        XCTAssertEqual(endpointEditor.headersToggle.value as? String, "Collapsed")
        XCTAssertFalse(endpointEditor.groupTagField.exists)
        XCTAssertTrue(endpointEditor.statusDescription.label.contains("OK") ||
                      (endpointEditor.statusDescription.value as? String)?.contains("OK") == true)
        navigator.row(named: "Account summary").click()
        add(navigator.screenshot("endpoint-editor-wide"))

        let bodyHeight = endpointEditor.bodyEditor.frame.height
        endpointEditor.showOptions()
        XCTAssertTrue(endpointEditor.groupTagField.waitForExistence(timeout: 5))
        XCTAssertTrue(endpointEditor.delayField.isHittable)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { self.endpointEditor.bodyEditor.frame.height < bodyHeight })
        endpointEditor.addHeaderButton.click()
        XCTAssertTrue(endpointEditor.headerKeyField(at: 0).waitForExistence(timeout: 5))
        XCTAssertEqual(endpointEditor.headersToggle.value as? String, "Expanded")
        endpointEditor.headerKeyField(at: 0).click()
        endpointEditor.headerKeyField(at: 0).typeText("X-Request-Source")
        endpointEditor.headerValueField(at: 0).click()
        endpointEditor.headerValueField(at: 0).typeText("Mimic")
        endpointEditor.headerValueField(at: 0).typeKey(.return, modifierFlags: [])
        add(navigator.screenshot("endpoint-editor-options-wide"))

        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(endpointEditor.reveal(endpointEditor.optionsToggle))
        XCTAssertTrue(endpointEditor.reveal(endpointEditor.delayField))
        XCTAssertTrue(endpointEditor.reveal(endpointEditor.groupTagField))
        XCTAssertGreaterThanOrEqual(endpointEditor.headerKeyField(at: 0).frame.minX, shell.panel("centerPane").frame.minX)
        XCTAssertLessThanOrEqual(endpointEditor.groupTagField.frame.maxX, shell.panel("centerPane").frame.maxX)
        XCTAssertLessThanOrEqual(endpointEditor.headerValueField(at: 0).frame.maxX, shell.panel("centerPane").frame.maxX)
        XCTAssertGreaterThanOrEqual(endpointEditor.bodyEditor.frame.height, 180)
        add(navigator.screenshot("endpoint-editor-narrow"))
        // Scroll over the options bar so the nested code editor cannot consume the wheel event.
        endpointEditor.formScrollView.scroll(byDeltaX: 0, deltaY: -300)
        XCTAssertTrue(endpointEditor.globalDelayNote.isHittable, "Short windows must allow the last option to scroll into view")
        add(navigator.screenshot("endpoint-editor-options-narrow-scrolled"))
        endpointEditor.formScrollView.scroll(byDeltaX: 0, deltaY: 300)
        endpointEditor.headersToggle.click()
        XCTAssertTrue(endpointEditor.headerKeyField(at: 0).waitForNonExistence(timeout: 5))
        endpointEditor.delayField.click()
        endpointEditor.delayField.typeKey("a", modifierFlags: .command)
        endpointEditor.delayField.typeText("250")
        endpointEditor.optionsToggle.click()
        XCTAssertTrue(endpointEditor.groupTagField.waitForNonExistence(timeout: 5))
        XCTAssertTrue(endpointEditor.prettyPrintButton.isHittable)
        add(navigator.screenshot("endpoint-editor-narrow-collapsed"))
        navigator.row(named: "Current orders").click()
        navigator.row(named: "Account summary").click()
        endpointEditor.showOptions()
        XCTAssertEqual(endpointEditor.delayField.value as? String, "250", "Collapsing options commits its focused field")
        XCTAssertEqual(endpointEditor.headerValueField(at: 0).value as? String, "Mimic", "Existing headers reopen as a table")
    }

    @MainActor
    func testSharedGeometryFilteringAndDisclosureAtWideAndNarrowWidths() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        workspace.fillWindow()
        let endpointFooter = navigator.footer.frame
        let endpointFilterMidY = navigator.endpointFilter.frame.midY
        let endpointHeader = navigator.header.frame
        let endpointRowHeight = navigator.rowHeight(named: "Account summary")
        XCTAssertEqual(shell.panel("sidebar").frame.maxX - navigator.endpointFilter.frame.maxX, 20, accuracy: 1,
                       "Inactive journey controls must not leave an empty slot beside the filter")
        XCTAssertEqual(endpointRowHeight, 34, accuracy: 1)
        XCTAssertEqual(navigator.group("Account").frame.minX - shell.panel("sidebar").frame.minX, 12, accuracy: 1)
        XCTAssertEqual(shell.panel("sidebar").frame.maxX - navigator.element("sidebar.addEndpointButton").frame.maxX, 12, accuracy: 1)
        XCTAssertTrue(navigator.row(named: "Current orders").exists)
        XCTAssertTrue(navigator.row(named: "Archived orders").exists)
        navigator.group("Orders").click()
        XCTAssertTrue(navigator.row(named: "Current orders").waitForNonExistence(timeout: 5))
        navigator.group("Orders").click()
        XCTAssertTrue(navigator.row(named: "Current orders").waitForExistence(timeout: 5))
        navigator.row(named: "Account summary").click()
        add(navigator.screenshot("navigator-endpoints-wide"))

        navigator.filter(navigator.endpointFilter, text: "missing-route")
        XCTAssertTrue(navigator.noEndpointMatches.waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.footer.frame.minY, endpointFooter.minY, accuracy: 1)
        navigator.filter(navigator.endpointFilter, text: "Current orders")
        XCTAssertTrue(navigator.row(named: "Current orders").waitForExistence(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Archived orders").exists)

        shell.journeysTab.click()
        XCTAssertTrue(navigator.journeyFilter.waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.header.frame.midY, endpointHeader.midY, accuracy: 1)
        XCTAssertEqual(navigator.journeyFilter.frame.midY, endpointFilterMidY, accuracy: 1)
        XCTAssertEqual(navigator.journeyFilter.frame.minX - shell.panel("sidebar").frame.minX, 20, accuracy: 1)
        XCTAssertEqual(shell.panel("sidebar").frame.maxX - navigator.journeyFilter.frame.maxX, 20, accuracy: 1)
        XCTAssertEqual(navigator.rowHeight(named: "Empty journey"), endpointRowHeight, accuracy: 1)
        navigator.filter(navigator.journeyFilter, text: "authorization")
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitForExistence(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Empty journey").exists)
        navigator.row(named: "Payment succeeds").click()
        XCTAssertFalse(navigator.activeJourney.exists, "Selection must not start a journey")
        add(navigator.screenshot("navigator-journeys-wide"))
        navigator.filter(navigator.journeyFilter, text: "missing-journey")
        XCTAssertTrue(navigator.noJourneyMatches.waitForExistence(timeout: 5))
        shell.endpointsTab.click()
        XCTAssertEqual(navigator.endpointFilter.value as? String, "Current orders")
        navigator.filter(navigator.endpointFilter, text: "")
        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(navigator.endpointFilter.isHittable)
        add(navigator.screenshot("navigator-narrow-editor-edge"))
        XCTAssertGreaterThanOrEqual(navigator.element("ds.method.editor.method").frame.minX, shell.panel("centerPane").frame.minX,
                                    "A narrow editor must keep its leading content visible")
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
    func testJourneyGroupsMatchEndpointSpacingAndSupportEditingAndReveal() async throws {
        try await launchFixture()
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        let endpointRowHeight = navigator.rowHeight(named: "Account summary")
        let groupInset = navigator.group("Account").frame.minX - shell.panel("sidebar").frame.minX
        let groupHeight = navigator.group("Account").frame.height
        try await command(["journeyUpdate": ["journey": ["name": "Payment succeeds after the second authorization attempt"], "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Payment declined", "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Session expired", "spec": ["groupTag": "Account"]]])
        shell.journeysTab.click()
        XCTAssertTrue(navigator.journeyGroup("Checkout").waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.journeyGroup("Checkout").value as? String, "2 journeys")
        XCTAssertEqual(navigator.rowHeight(named: "Payment declined"), endpointRowHeight, accuracy: 1)
        XCTAssertEqual(navigator.journeyGroup("Account").frame.height, groupHeight, accuracy: 1)
        XCTAssertEqual(navigator.journeyGroup("Account").frame.minX - shell.panel("sidebar").frame.minX, groupInset, accuracy: 1)
        XCTAssertEqual(navigator.row(named: "Payment declined").frame.midY - navigator.row(named: "Payment succeeds").frame.midY, endpointRowHeight, accuracy: 1)
        navigator.journeyGroup("Checkout").click()
        XCTAssertTrue(navigator.row(named: "Payment declined").waitForNonExistence(timeout: 5))
        shell.endpointsTab.click()
        shell.journeysTab.click()
        XCTAssertFalse(navigator.row(named: "Payment declined").exists, "Collapse survives switching tabs")
        navigator.filter(navigator.journeyFilter, text: "Checkout")
        XCTAssertTrue(navigator.row(named: "Payment declined").waitForExistence(timeout: 5), "Filtering reveals matches inside a collapsed group")
        XCTAssertFalse(navigator.row(named: "Session expired").exists)
        navigator.filter(navigator.journeyFilter, text: "")
        navigator.row(named: "Empty journey").click()
        navigator.element("journeyEditor.settingsDisclosure").click()
        XCTAssertTrue(navigator.journeyGroupField.waitForExistence(timeout: 5))
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
        XCTAssertTrue(navigator.row(named: "Empty journey").waitForNonExistence(timeout: 5))
        let journeys = JourneysNavigatorPage(app: app)
        journeys.addButton.click()
        XCTAssertTrue(journeys.newEmptyMenuItem.waitForExistence(timeout: 5))
        journeys.newEmptyMenuItem.click()
        let newJourney = NewJourneySheetPage(app: app)
        XCTAssertTrue(newJourney.nameField.waitForExistence(timeout: 5))
        newJourney.nameField.click()
        newJourney.nameField.typeText("New ungrouped journey")
        newJourney.createButton.click()
        XCTAssertTrue(navigator.row(named: "New ungrouped journey").waitForExistence(timeout: 5),
                      "Creating a selected journey must reveal its collapsed Ungrouped section")
        XCTAssertTrue(navigator.row(named: "New ungrouped journey").isHittable)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            journeys.editorName.label.contains("New ungrouped journey")
                || (journeys.editorName.value as? String)?.contains("New ungrouped journey") == true
        }, "The centre pane should edit the newly selected journey")
        try await command(["journeyActivate": ["journey": ["name": "Payment succeeds after the second authorization attempt"]]])
        navigator.journeyGroup("Checkout").click()
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitForNonExistence(timeout: 5))
        navigator.activeJourney.click()
        XCTAssertTrue(navigator.row(named: "Payment succeeds").waitForExistence(timeout: 5))
        XCTAssertTrue(navigator.row(named: "Payment succeeds").label.contains(", active"))
        add(navigator.screenshot("navigator-journeys-grouped-wide"))
        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        XCTAssertEqual(navigator.rowHeight(named: "Payment declined"), endpointRowHeight, accuracy: 1)
        XCTAssertTrue(navigator.journeyGroup("Checkout").isHittable)
        let settings = navigator.element("journeyEditor.settingsDisclosure")
        XCTAssertTrue(settings.waitForExistence(timeout: 5), "Narrow editors disclose secondary settings")
        XCTAssertEqual(settings.value as? String, "Collapsed")
        let firstStep = navigator.element("journeyStep-0")
        XCTAssertTrue(firstStep.isHittable, "The first step must be visible in the initial narrow viewport")
        XCTAssertLessThan(firstStep.frame.minY, shell.panel("centerPane").frame.maxY)
        settings.click()
        XCTAssertEqual(settings.value as? String, "Expanded")
        XCTAssertGreaterThanOrEqual(navigator.element("journeyEditor.unmatchedPicker").frame.minY,
                                    navigator.element("journeyRun.deactivateButton").frame.maxY,
                                    "Expanded behavior controls must follow the run buttons")
        settings.click()
        XCTAssertTrue(firstStep.isHittable)
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
        XCTAssertTrue(firstStep.waitForExistence(timeout: 5))
        XCTAssertTrue(firstStep.label.contains("First charge declined"), firstStep.label)
        XCTAssertTrue(navigator.element("journeyStep-1").label.contains("Retry accepted"))
        let settingsWide = navigator.element("journeyEditor.settingsDisclosure")
        XCTAssertEqual(settingsWide.value as? String, "Collapsed")
        add(navigator.screenshot("journey-editor-light-wide"))

        workspace.compactWindow()
        workspace.showSidebarIfNeeded()
        let settings = navigator.element("journeyEditor.settingsDisclosure")
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertEqual(settings.value as? String, "Collapsed")
        XCTAssertTrue(firstStep.isHittable, "The first step should remain visible in light mode at narrow width")
        XCTAssertTrue(navigator.element("journeyStep-1").isHittable,
                      "Both short journey steps should fit above the compact request log")
        add(navigator.screenshot("journey-editor-light-narrow"))
    }

    @MainActor
    func testEmptyListsKeepTheSameHeaderFooterAndCreationActions() async throws {
        try await launchFixture(populated: false)
        let navigator = NavigatorPage(app: app)
        let shell = WorkspaceShellPage(app: app)
        XCTAssertTrue(navigator.endpointFilter.waitForExistence(timeout: 5))
        XCTAssertTrue(workspace.addEndpointButton.isHittable)
        let header = navigator.header.frame
        let footer = navigator.footer.frame
        shell.journeysTab.click()
        let journeys = JourneysNavigatorPage(app: app)
        XCTAssertTrue(journeys.emptyStateHeading.waitForExistence(timeout: 5))
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
        navigator.methodScope.click()
        navigator.scopeOption("DELETE").click()
        XCTAssertTrue(navigator.noEndpointMatches.waitForExistence(timeout: 5))
        navigator.methodScope.click()
        navigator.scopeOption("POST").click()
        XCTAssertTrue(navigator.row(named: "Create order").waitForExistence(timeout: 5))
        XCTAssertFalse(navigator.row(named: "Current orders").exists)
        shell.journeysTab.click()
        let name = "Payment succeeds after the second authorization attempt"
        navigator.row(named: name).click()
        let journeys = JourneysNavigatorPage(app: app)
        XCTAssertTrue(journeys.activateButton.waitForExistence(timeout: 5))
        let before = navigator.row(named: name).frame
        journeys.activateButton.click()
        XCTAssertTrue(navigator.activeJourney.waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.row(named: name).frame, before)
        navigator.filter(navigator.journeyFilter, text: "Empty")
        XCTAssertTrue(navigator.row(named: name).waitForNonExistence(timeout: 5))
        navigator.activeJourney.click()
        XCTAssertTrue(navigator.row(named: name).waitForExistence(timeout: 5))
        XCTAssertEqual(navigator.journeyFilter.value as? String, "")
        XCTAssertTrue(journeys.deactivateButton.isHittable)
        journeys.advanceButton.click()
        journeys.restartButton.click()
        add(navigator.screenshot("navigator-active-journey"))
        journeys.deactivateButton.click()
        XCTAssertTrue(navigator.activeJourney.waitForNonExistence(timeout: 5))
        shell.endpointsTab.click()
        XCTAssertTrue(navigator.row(named: "Create order").exists, "Endpoint method scope survives tab switching")
    }

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
        XCTAssertTrue(scenario.waitForExistence(timeout: 5))
        XCTAssertEqual(panel.header.frame.midY, navigator.header.frame.midY, accuracy: 1)
        XCTAssertEqual(scenario.frame.height, 30, accuracy: 1)
        scenario.click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { panel.isScenarioActive(named: "Unauthorized") })
        XCTAssertFalse(panel.isScenarioActive(named: "Default"))
        try await command(["serverStart": [:]])
        XCTAssertTrue(workspace.waitForServerURL(port: 62171))
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:62171/account-summary")))
        request.timeoutInterval = 5
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        for _ in 0..<31 {
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401)
        }
        panel.tab("traffic").click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { panel.trafficRows.count == 32 },
                      "Traffic row count: \(panel.trafficRows.count)")
        let traffic = panel.trafficRows.element(boundBy: 25)
        XCTAssertFalse(traffic.isHittable, "The scroll fixture must extend below the viewport")
        for _ in 0..<4 where !traffic.isHittable {
            panel.trafficList.scroll(byDeltaX: 0, deltaY: -500)
        }
        XCTAssertTrue(traffic.isHittable)
        let trafficFrame = traffic.frame
        add(navigator.screenshot("inspector-traffic-scrolled"))
        traffic.click()
        XCTAssertTrue(requestDetail.path.waitForExistence(timeout: 5))
        XCTAssertTrue(panel.spoken(requestDetail.status).contains("401"))
        XCTAssertEqual(requestDetail.closeButton.label, "Back to traffic")
        requestDetail.tab("Body").click()
        add(navigator.screenshot("inspector-request-body-wide"))
        requestDetail.closeButton.click()
        XCTAssertTrue(traffic.waitForExistence(timeout: 5))
        XCTAssertEqual(traffic.frame, trafficFrame, "Returning preserves the traffic list position")
        panel.tab("scenarios").click()
        XCTAssertTrue(panel.isScenarioActive(named: "Unauthorized"))
        workspace.compactWindow()
        XCTAssertTrue(panel.tab("scenarios").isHittable)
        XCTAssertTrue(panel.tab("traffic").isHittable)
        XCTAssertTrue(panel.addScenarioButton.isHittable)
        XCTAssertEqual(scenario.frame.height, 30, accuracy: 1)
        for column in ["method", "path", "status", "timestamp"] {
            let header = app.buttons["drawer.columnHeader.\(column)"].firstMatch
            XCTAssertTrue(header.isHittable, "\(column) must stay visible in the compact request log")
        }
        add(navigator.screenshot("inspector-scenarios-narrow"))
        panel.tab("traffic").click()
        panel.trafficRows.allElementsBoundByIndex.first(where: \.isHittable)?.click()
        XCTAssertTrue(requestDetail.closeButton.waitForExistence(timeout: 5))
        add(navigator.screenshot("inspector-request-narrow"))
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
        XCTAssertTrue(panel.journeyRow("steps").waitForExistence(timeout: 5))
        XCTAssertTrue(panel.spoken(panel.journeyRow("steps")).contains("2"))
        XCTAssertTrue(panel.spoken(panel.journeyRow("state")).contains("Inactive"))
        XCTAssertTrue(panel.journeyRow("noActiveRun").exists)
        try await command(["journeyActivate": ["journey": ["name": activeName]]])
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) {
            panel.spoken(panel.journeyRow("state")).contains("Prepared for next server run")
        })
        XCTAssertTrue(navigator.element("journeyRun.progress").waitForExistence(timeout: 5))
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
        XCTAssertTrue(panel.journeyRow("noActiveRun").waitForExistence(timeout: 5))
    }
}
