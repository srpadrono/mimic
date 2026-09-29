import AppKit
import Foundation
import XCTest

/// Walks every screen with realistic data and saves one screenshot per state, so the window can be
/// compared with the design canvas. Each test covers one appearance at wide and compact widths.
///
/// Captures never fail the run on their own: a missing screen is reported by its missing image and
/// a `DESIGN_SHOT_MISSING` line, so one broken step does not hide every screen after it.
final class DesignReviewUITests: MimicUITestCase {
    private let fixtureID = UUID().uuidString
    private let fixtureToken = UUID().uuidString + UUID().uuidString
    private let controlPort = 62190
    private let mockPort = 62191
    private var usesLightAppearance = false
    private var launchStarted = Date.distantFuture
    private var verifiedFixture = false

    private var appearance: String { usesLightAppearance ? "light" : "dark" }

    @MainActor
    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        app.launchArguments += ["-AppleInterfaceStyle", usesLightAppearance ? "Light" : "Dark",
                                "-NSRequiresAquaSystemAppearance", usesLightAppearance ? "YES" : "NO"]
        app.launchEnvironment["MIMIC_APPEARANCE"] = usesLightAppearance ? "light" : "dark"
        app.launchEnvironment["MIMIC_CONTROL_PORT"] = String(controlPort)
        app.launchEnvironment["MIMIC_UPDATE_FEED_FIXTURE"] = UpdateFixtures.available
        app.launchEnvironment["MIMIC_CONTROL_TOKEN"] = fixtureToken
        let base = "~/Library/Application Support/devxa.Mimic/design-uitest-\(fixtureID)"
        app.launchEnvironment["MIMIC_CONTROL_FILE"] = base + ".json"
        app.launchEnvironment["MIMIC_DATABASE_PATH"] = base + ".sqlite"
        app.launchEnvironment["MIMIC_UPDATE_FEED_FIXTURE"] = "mimic-uitest-update-available.json"
        app.launchEnvironment["MIMIC_IMPORT_FILE"] = "mimic-uitest-review.json"
        app.launchEnvironment["MIMIC_IMPORT_KIND"] = "har"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = true
    }

    @MainActor
    func testDesignReviewDark() async throws {
        usesLightAppearance = false
        try await walkEveryScreen()
    }

    @MainActor
    func testDesignReviewLight() async throws {
        usesLightAppearance = true
        try await walkEveryScreen()
    }

    // MARK: - The walk

    @MainActor
    private func walkEveryScreen() async throws {
        launchStarted = Date()
        launchApp()
        try await verifyFixture()
        capture("01-welcome-empty")

        welcome.newProjectButton.click()
        if newProjectSheet.nameField.waitForExistence(timeout: 3) {
            newProjectSheet.nameField.typeText("Storefront")
            capture("02-new-project")
        }
        app.typeKey(.escape, modifierFlags: [])

        try await command(["projectCreate": ["name": "Empty project", "port": mockPort + 1]])
        workspace.fillWindow()
        workspace.showSidebarIfNeeded()
        // The injected HAR import opens its review sheet whenever a workspace appears.
        if element("import.candidateList").waitForExistence(timeout: 8) {
            capture("13-import-review")
        } else {
            missing("13-import-review")
        }
        dismissInjectedImport()
        capture("03-empty-workspace")

        try await seedStorefront()
        workspace.fillWindow()
        workspace.showSidebarIfNeeded()
        dismissInjectedImport()
        let product = row(named: "Get product")
        if product.waitForExistence(timeout: 5) { product.click() }
        _ = endpointEditor.pathLabel.waitForExistence(timeout: 5)
        capture("04-workspace-editor")

        let outOfStock = element("inspector.scenario.Out of stock")
        if outOfStock.waitForExistence(timeout: 3) {
            outOfStock.click()
            capture("04b-editor-not-live")
            let defaultRow = element("inspector.scenario.Default")
            if defaultRow.waitForExistence(timeout: 2) { defaultRow.click() }
        } else {
            missing("04b-editor-not-live")
        }

        if workspace.addEndpointButton.waitForExistence(timeout: 3) {
            workspace.addEndpointButton.click()
            if newEndpointSheet.nameField.waitForExistence(timeout: 3) {
                newEndpointSheet.nameField.click()
                newEndpointSheet.nameField.typeText("List reviews")
                capture("05-new-endpoint")
            }
            app.typeKey(.escape, modifierFlags: [])
        }

        try await command(["serverStart": ["port": mockPort]])
        _ = workspace.waitForServerURL(port: mockPort, timeout: 8)
        for (method, path) in [("GET", "/products/42"), ("GET", "/products/42"), ("POST", "/cart/items"),
                               ("GET", "/users/me"), ("GET", "/products/7/reviews"), ("DELETE", "/cart/items/3")] {
            await sendRequest(port: mockPort, path: path, method: method,
                              body: method == "POST" ? #"{"productId":42,"quantity":1}"# : nil)
        }
        let firstLog = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", "requestLog-")).firstMatch
        if !firstLog.waitForExistence(timeout: 3) {
            // The log is shown by default now; open it only when a toggle hid it.
            workspace.toggleDrawerButton.click()
            workspace.closeToolbarMenu()
        }
        _ = firstLog.waitForExistence(timeout: 5)
        capture("06-server-running")

        let statusWell = element("serverStatusWell.url")
        if statusWell.waitForExistence(timeout: 3) {
            statusWell.click()
            capture("07-server-popover")
            app.typeKey(.escape, modifierFlags: [])
        }

        if firstLog.waitForExistence(timeout: 5) {
            capture("08-request-log")
            firstLog.click()
            _ = element("requestDetail.path").waitForExistence(timeout: 5)
            capture("09-request-detail")
        } else {
            missing("08-request-log")
        }

        // A run in progress, as the design shows it: active, one step served, the next one waiting.
        try await command(["journeyActivate": ["journey": ["name": "Payment retry"]]])
        try await command(["journeyAdvance": [:]])
        app.typeKey("2", modifierFlags: .command)
        let journey = app.descendants(matching: .any)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label BEGINSWITH %@",
                                  "journeys.row.", "Payment retry, ")).firstMatch
        if journey.waitForExistence(timeout: 5) {
            journey.click()
            _ = element("journeyEditor.stepList").waitForExistence(timeout: 5)
            let step = element("journeyStep-1")
            if step.waitForExistence(timeout: 3) {
                // One click shows the step in the inspector, as the design's journey screen does.
                step.click()
                _ = element("inspector.journeyStep").waitForExistence(timeout: 3)
            }
            capture("10-journeys")
            if step.exists {
                step.doubleClick()
                if element("stepSheet.nameField").waitForExistence(timeout: 3) {
                    capture("11-journey-step")
                }
                app.typeKey(.escape, modifierFlags: [])
            }
        } else {
            missing("10-journeys")
        }
        app.typeKey("1", modifierFlags: .command)
        // The screens after this one show endpoints answering for themselves.
        try await command(["journeyActivate": [:]])

        let settings = workspace.toolbarAction("backend.settingsButton")
        if settings.waitForExistence(timeout: 3) {
            settings.click()
            capture("12-server-settings")
            let cancel = element("backend.cancel")
            if cancel.waitForExistence(timeout: 2) { cancel.click() } else { app.typeKey(.escape, modifierFlags: []) }
        } else {
            missing("12-server-settings")
        }

        workspace.compactWindow()
        if product.waitForExistence(timeout: 3) { product.click() }
        capture("14-compact")
        let overflow = workspace.overflowMenu
        if overflow.waitForExistence(timeout: 3) {
            overflow.click()
            capture("15-compact-overflow")
            workspace.closeToolbarMenu()
        } else {
            missing("15-compact-overflow")
        }
        workspace.fillWindow()

        closeProjectViaMenu()
        if welcome.newProjectButton.waitForExistence(timeout: 5) {
            capture("16-welcome-recents")
        }

        let updateSheet = UpdateSheetPage(app: app)
        updateSheet.openFromMenu()
        if updateSheet.downloadButton.waitForExistence(timeout: 10) {
            capture("17-update")
            app.typeKey(.escape, modifierFlags: [])
        } else {
            app.typeKey(.escape, modifierFlags: [])
            missing("17-update")
        }
    }

    // MARK: - Fixture

    @MainActor
    private func seedStorefront() async throws {
        try await command(["projectCreate": ["name": "Storefront", "port": mockPort]])
        let endpoints: [(String, String, String, String, Int, String)] = [
            ("Get product", "GET", "/products/:id", "Catalog", 200,
             #"{"id":42,"name":"Trail running shoe","price":{"amount":129.0,"currency":"EUR"},"inStock":true,"sizes":[40,41,42,43]}"#),
            ("List products", "GET", "/products", "Catalog", 200, #"{"items":[],"total":0}"#),
            ("Product reviews", "GET", "/products/:id/reviews", "Catalog", 200, #"{"reviews":[]}"#),
            ("Add to cart", "POST", "/cart/items", "Cart", 201, #"{"cartId":"c_81","items":1}"#),
            ("Update quantity", "PATCH", "/cart/items/:id", "Cart", 200, #"{"ok":true}"#),
            ("Remove from cart", "DELETE", "/cart/items/:id", "Cart", 204, ""),
            ("Current user", "GET", "/users/me", "Account", 200, #"{"id":"u_1","name":"Ada"}"#),
            ("Update profile", "PUT", "/users/me", "Account", 200, #"{"ok":true}"#),
        ]
        for (name, method, path, group, status, body) in endpoints {
            try await command(["endpointCreate": ["name": name, "method": method, "path": path,
                                                  "spec": ["groupTag": group]]])
            try await command(["scenarioUpdate": [
                "endpoint": ["method": method, "path": path],
                "scenario": ["name": "Default"],
                "spec": ["statusCode": status, "body": body, "contentType": "application/json"],
            ]])
        }
        let product: [String: Any] = ["method": "GET", "path": "/products/:id"]
        try await command(["scenarioCreate": ["endpoint": product, "name": "Out of stock",
                                              "spec": ["statusCode": 200, "body": #"{"id":42,"inStock":false}"#]]])
        try await command(["scenarioCreate": ["endpoint": product, "name": "Not found",
                                              "spec": ["statusCode": 404, "body": #"{"error":"not_found"}"#]]])
        try await command(["scenarioCreate": ["endpoint": product, "name": "Server error",
                                              "spec": ["statusCode": 500, "body": #"{"error":"internal"}"#]]])
        // Grouped as the design's navigator is: sections under headers, ungrouped last.
        try await command(["journeyAddTemplate": ["templateID": "payment-retry", "name": "Payment retry"]])
        try await command(["journeyUpdate": ["journey": ["name": "Payment retry"], "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Checkout happy path", "spec": ["groupTag": "Checkout"]]])
        try await command(["journeyCreate": ["name": "Session expiry", "spec": ["groupTag": "Account"]]])
    }

    // MARK: - Control API

    @MainActor
    private func response(_ command: [String: Any]) async throws -> [String: Any] {
        var request = URLRequest(url: try XCTUnwrap(URL(string: "http://127.0.0.1:\(controlPort)/v1/command")))
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        request.setValue(fixtureToken, forHTTPHeaderField: "X-Mimic-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: command)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              envelope["ok"] as? Bool == true else {
            let text = String(decoding: data, as: UTF8.self)
            print("DESIGN_FIXTURE_REFUSED \(command.keys.first ?? "?"): \(text)")
            throw NSError(domain: "DesignFixture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Fixture command was refused: \(text)"])
        }
        return envelope["result"] as? [String: Any] ?? [:]
    }

    @MainActor
    @discardableResult
    private func command(_ command: [String: Any]) async throws -> [String: Any] {
        guard verifiedFixture else { throw NSError(domain: "DesignFixture", code: 2) }
        return try await response(command)
    }

    @MainActor
    private func verifyFixture() async throws {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let result = try? await response(["state": [:]]),
               let state = result["state"] as? [String: Any], let pid = state["pid"] as? Int,
               let process = NSRunningApplication(processIdentifier: pid_t(pid)),
               process.bundleIdentifier == "devxa.Mimic", let date = process.launchDate,
               date >= launchStarted {
                verifiedFixture = true
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The authenticated fixture must identify the newly launched app")
    }

    // MARK: - Capture

    @MainActor
    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    @MainActor
    private func row(named name: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(
            format: "identifier BEGINSWITH %@ AND label CONTAINS %@", "endpoint-", name
        )).firstMatch
    }

    /// Cancels the injected import sheet if it is up, so it does not cover the next screen.
    @MainActor
    private func dismissInjectedImport() {
        let cancel = element("harImport.cancelButton")
        guard cancel.waitForExistence(timeout: 8) else { return }
        cancel.click()
        _ = element("import.candidateList").waitForNonExistence(timeout: 3)
    }

    @MainActor
    private func missing(_ name: String) {
        print("DESIGN_SHOT_MISSING \(name)-\(appearance)")
    }

    /// Saves the whole screen, so sheets, popovers, and menus outside the window frame are included.
    @MainActor
    private func capture(_ name: String) {
        let full = "\(name)-\(appearance)"
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = full
        attachment.lifetime = .keepAlways
        add(attachment)

        let environment = ProcessInfo.processInfo.environment
        let directory = URL(fileURLWithPath: environment["MIMIC_DESIGN_SHOTS"]
            ?? (NSTemporaryDirectory() + "mimic-design-shots"), isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(full).png")
        do {
            try shot.pngRepresentation.write(to: url)
            print("DESIGN_SHOT \(url.path)")
        } catch {
            print("DESIGN_SHOT_FAIL \(full): \(error)")
        }
    }
}
