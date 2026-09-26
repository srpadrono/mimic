import AppKit
import Darwin
import Foundation
import XCTest

@MainActor
struct BackendSettingsPage {
    let app: XCUIApplication
    var open: XCUIElement { WorkspacePage(app: app).toolbarAction("backend.settingsButton") }
    var captureHelp: XCUIElement { app.staticTexts["backend.primary.captureHelp"].firstMatch }
    var primaryName: XCUIElement { app.textFields["backend.primary.name"].firstMatch }
    var primaryPort: XCUIElement { app.textFields["backend.primary.port"].firstMatch }
    var primaryPortError: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "Use 1–65535")).firstMatch
    }
    var primaryCopy: XCUIElement { app.buttons["backend.primary.copy"].firstMatch }
    var primaryUpstream: XCUIElement { app.textFields["backend.primary.upstream"].firstMatch }
    var primaryUpstreamError: XCUIElement {
        app.descendants(matching: .any)["backend.primary.upstreamError"].firstMatch
    }
    var primaryCapture: XCUIElement { app.descendants(matching: .any)["backend.primary.capture"].firstMatch }
    var primarySelection: XCUIElement { app.buttons["backend.select.00000000-0000-0000-0000-000000000000"].firstMatch }
    var additionalSelection: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                                         "backend.select.", "backend.select.00000000-0000-0000-0000-000000000000")).firstMatch
    }
    var additionalPortError: XCUIElement {
        app.descendants(matching: .any)
            .matching(NSPredicate(format: "label == %@", "This port is used by another backend")).firstMatch
    }
    var primaryEnabled: XCUIElement { app.descendants(matching: .any)["backend.primary.enabled"].firstMatch }
    var add: XCUIElement { app.buttons["backend.add"].firstMatch }
    var removeSelected: XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier != %@",
                                         "backend.delete.", "backend.delete.00000000-0000-0000-0000-000000000000")).firstMatch
    }
    var apply: XCUIElement { app.buttons["backend.apply"].firstMatch }
    var cancel: XCUIElement { app.buttons["backend.cancel"].firstMatch }
    func portMenuItem(_ port: Int, copying: Bool = false) -> XCUIElement {
        app.descendants(matching: .any)["serverStatusWell.\(copying ? "copyPort" : "configuredPort").\(port)"].firstMatch
    }
    var portsDescription: String { "\(ports.label) \(ports.value.map { String(describing: $0) } ?? "")" }
    var ports: XCUIElement { app.buttons["serverStatusWell.url"].firstMatch }
    func inspectorShowsPort(_ port: Int) -> Bool {
        // Native accessibility may flatten the overview into the first section's text.
        let candidates = [
            app.staticTexts["inspector.overview.port"].firstMatch,
            app.staticTexts["ds.sectionheader.overview.server"].firstMatch,
        ]
        return candidates.contains { element in
            guard element.exists else { return false }
            return [element.label, element.value as? String ?? ""].contains { text in
                guard let marker = text.range(of: "Port:") else { return false }
                let value = text[marker.upperBound...].drop(while: \.isWhitespace).prefix(while: \.isNumber)
                return Int(value) == port
            }
        }
    }
    var error: XCUIElement { app.staticTexts["backend.error"].firstMatch }
    func additional(_ suffix: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND NOT identifier BEGINSWITH %@", "backend.", "." + suffix, "backend.primary.")).firstMatch
    }
    func additionalState(_ suffix: String) -> XCUIElement {
        app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND NOT identifier BEGINSWITH %@", "backend.", "." + suffix, "backend.primary.")).firstMatch
    }
    func replace(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        let clipboard = UITestClipboardSnapshot()
        defer { clipboard.restore() }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        app.typeKey("v", modifierFlags: .command)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 3) { field.value as? String == value },
                      "The field must contain the exact fixture value before validation")
        field.typeKey(.tab, modifierFlags: [])
    }
}

final class BackendSettingsUITests: MimicUITestCase {
    @MainActor
    func testConfigureTwoBackendsAndValidateAtomically() {
        launchApp()
        createProjectViaUI(name: "Two backends")
        let page = BackendSettingsPage(app: app)
        XCTAssertTrue(page.open.waitForExistence(timeout: 5))
        page.open.click()
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["http://localhost:8080"].exists,
                      "The displayed URL must use the literal port without grouping separators")
        XCTAssertFalse(page.primaryUpstream.exists, "Pass-through fields should stay hidden until enabled")
        let singleBackendHeight = app.sheets.firstMatch.frame.height
        XCTAssertLessThan(singleBackendHeight, 600, "A single backend should not open a mostly empty sheet")
        page.replace(page.primaryName, with: "Catalog")
        page.primaryEnabled.click()
        page.replace(page.primaryUpstream, with: "https://catalog.example.com/api")
        page.primaryCapture.click()
        XCTAssertTrue(page.captureHelp.waitForExistence(timeout: 5))
        let captureHelp = "\(page.captureHelp.label) \(page.captureHelp.value as? String ?? "")"
        XCTAssertTrue(captureHelp.contains("5 MiB"), captureHelp)
        XCTAssertTrue(captureHelp.contains("64 KiB"), captureHelp)
        page.add.click()
        XCTAssertTrue(
            page.additional("name").waitForExistence(timeout: 5),
            "Added backend detail is absent after selection: \(app.debugDescription)"
        )
        XCTAssertTrue(page.apply.isHittable, "The action row must stay on-screen when the form grows")
        XCTAssertGreaterThanOrEqual(
            app.sheets.firstMatch.frame.height, singleBackendHeight,
            "Adding a backend should not shrink the sheet"
        )
        page.replace(page.additional("name"), with: "Accounts")
        page.replace(page.additional("port"), with: "8080")
        page.apply.click()
        XCTAssertTrue(page.additionalPortError.waitForExistence(timeout: 5))
        page.replace(page.additional("port"), with: "18081")
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.ports.waitForExistence(timeout: 5))
        XCTAssertTrue(page.portsDescription.contains("2 ports configured"), "\(page.portsDescription)\n\(app.debugDescription)")
        XCTAssertTrue(page.portsDescription.contains("Accounts: 18081"))
        app.activate()
        page.ports.click()
        XCTAssertTrue(page.portMenuItem(18081).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(page.portMenuItem(18081).value as? String, "http://localhost:18081")
        let portListShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        portListShot.name = "Configured port list"
        portListShot.lifetime = .keepAlways
        add(portListShot)
        app.typeKey(.escape, modifierFlags: [])
        let toolbarShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        toolbarShot.name = "Toolbar — two configured ports"
        toolbarShot.lifetime = .keepAlways
        add(toolbarShot)
        page.open.click()
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        XCTAssertEqual(page.primaryName.value as? String, "Catalog")
        XCTAssertTrue(page.additionalSelection.waitForExistence(timeout: 5))
        page.additionalSelection.click()
        XCTAssertEqual(page.additional("port").value as? String, "18081")
        let screenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        screenshot.name = "Backend settings — saved configuration"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        page.primarySelection.click()
        XCTAssertTrue(page.primaryUpstream.waitForExistence(timeout: 5))
        let passthroughScreenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        passthroughScreenshot.name = "Backend settings — pass-through and capture"
        passthroughScreenshot.lifetime = .keepAlways
        add(passthroughScreenshot)
        page.cancel.click()
    }

    @MainActor
    func testBackendListSelectionAndRemoval() {
        launchApp()
        createProjectViaUI(name: "Backend selection")
        workspace.fillWindow()
        let page = BackendSettingsPage(app: app)
        XCTAssertTrue(page.open.waitForExistence(timeout: 5))
        page.open.click()
        XCTAssertTrue(page.primarySelection.waitForExistence(timeout: 5))
        page.add.click()
        XCTAssertTrue(page.additional("name").waitForExistence(timeout: 5))
        page.replace(page.additional("name"), with: "Accounts")
        page.primarySelection.click()
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        XCTAssertFalse(page.additional("name").exists, "Only the selected listener's fields should be shown")
        page.additionalSelection.click()
        XCTAssertEqual(page.additional("name").value as? String, "Accounts")
        XCTAssertTrue(page.removeSelected.isEnabled)
        page.removeSelected.click()
        XCTAssertFalse(page.additionalSelection.exists)
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        XCTAssertFalse(page.portsDescription.contains("2 ports configured"))
    }

    @MainActor
    func testInvalidPortCannotBeAppliedOrCopied() {
        launchApp()
        createProjectViaUI(name: "Port validation")
        let page = BackendSettingsPage(app: app)
        page.open.click()
        XCTAssertTrue(page.primaryPort.waitForExistence(timeout: 5))
        page.replace(page.primaryPort, with: "abc")
        XCTAssertTrue(page.primaryPortError.waitForExistence(timeout: 5))
        XCTAssertFalse(page.apply.isEnabled)
        XCTAssertFalse(page.primaryCopy.isEnabled)
        XCTAssertFalse(app.staticTexts["http://localhost:0"].exists)
        let screenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        screenshot.name = "Backend settings — invalid local port"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        page.replace(page.primaryPort, with: "18081")
        XCTAssertFalse(page.primaryPortError.exists)
        XCTAssertTrue(page.apply.isEnabled)
        XCTAssertTrue(page.primaryCopy.isEnabled)
        page.cancel.click()
    }

    @MainActor
    func testPassThroughRefusesEquivalentLoopbackListenerBeforeApplying() {
        launchApp()
        createProjectViaUI(name: "Loopback validation")
        let page = BackendSettingsPage(app: app)
        page.open.click()
        XCTAssertTrue(page.primaryEnabled.waitForExistence(timeout: 5))
        page.primaryEnabled.click()
        XCTAssertTrue(page.primaryUpstream.waitForExistence(timeout: 5))

        for upstream in ["http://localhost.:8080", "http://[::1]:8080"] {
            page.replace(page.primaryUpstream, with: upstream)
            page.apply.click()
            XCTAssertTrue(page.primaryUpstreamError.waitForExistence(timeout: 5),
                          "Loopback equivalents need the same inline refusal as localhost")
            XCTAssertEqual(page.primaryUpstreamError.label,
                           "Enter an HTTP or HTTPS base URL outside these local listeners")
            XCTAssertEqual(page.primaryUpstream.value as? String, upstream,
                           "Refusal must retain the URL so it can be corrected")
            XCTAssertTrue(page.apply.exists, "An invalid draft must stay open")
        }

        page.replace(page.primaryUpstream, with: "http://localhost.:8081")
        XCTAssertTrue(page.primaryUpstreamError.waitForNonExistence(timeout: 5))
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5),
                      "A different local server remains a supported upstream")
        page.open.click()
        XCTAssertTrue(page.primaryUpstream.waitForExistence(timeout: 5))
        XCTAssertEqual(page.primaryUpstream.value as? String, "http://localhost.:8081")
        page.cancel.click()
    }

    @MainActor
    func testToolbarDistinguishesListeningAndPendingPorts() throws {
        let clipboard = UITestClipboardSnapshot()
        defer { clipboard.restore() }
        func distinctFreePorts() throws -> [Int] {
            var descriptors: [Int32] = []
            defer { for descriptor in descriptors { Darwin.close(descriptor) } }
            // Keep all four bound until allocation completes so the OS cannot hand back a
            // just-released port for the next listener or its replacement.
            return try (0..<4).map { _ in
                let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
                guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
                descriptors.append(descriptor)
                var address = sockaddr_in()
                address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
                address.sin_family = sa_family_t(AF_INET)
                address.sin_addr.s_addr = inet_addr("127.0.0.1")
                var length = socklen_t(MemoryLayout<sockaddr_in>.size)
                try withUnsafeMutablePointer(to: &address) { pointer in
                    try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                        guard Darwin.bind(descriptor, socketAddress, length) == 0,
                              getsockname(descriptor, socketAddress, &length) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                    }
                }
                return Int(UInt16(bigEndian: address.sin_port))
            }
        }
        let ports = try distinctFreePorts()
        let primary = ports[0], secondary = ports[1], replacement = ports[2]
        let primaryReplacement = ports[3]
        launchApp()
        createProjectViaUI(name: "Listening ports")
        workspace.fillWindow()
        XCTAssertTrue(workspace.centerAddEndpointMessage.waitForExistence(timeout: 5),
                      "An empty project must explain how to create its first endpoint")
        XCTAssertFalse(workspace.centerSelectEndpointMessage.exists,
                       "There is no endpoint available to select yet")
        XCTAssertTrue(workspace.drawerStoppedMessage.waitForExistence(timeout: 5))
        XCTAssertFalse(workspace.drawerRunningMessage.exists)
        let page = BackendSettingsPage(app: app)
        page.open.click()
        XCTAssertTrue(page.primaryPort.waitForExistence(timeout: 5))
        page.replace(page.primaryPort, with: String(primary))
        page.add.click()
        XCTAssertTrue(page.additional("port").waitForExistence(timeout: 5))
        page.replace(page.additional("name"), with: "Accounts")
        page.replace(page.additional("port"), with: String(secondary))
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        workspace.serverToggleButton.click()
        XCTAssertTrue(workspace.waitForServerURL(port: primary))
        XCTAssertTrue(page.portsDescription.contains("2 ports listening"))
        XCTAssertTrue(workspace.drawerRunningMessage.waitForExistence(timeout: 5),
                      "A running server must invite a request without asking to start again")
        XCTAssertFalse(workspace.drawerStoppedMessage.exists)
        workspace.compactWindow()
        XCTAssertLessThan(app.windows.firstMatch.frame.width, 1180,
                          "This assertion must exercise the compact toolbar")
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { page.ports.isHittable },
                      "Server details must remain reachable without enlarging the compact window")
        XCTAssertTrue(workspace.serverURLText(port: primary).isHittable)
        page.ports.click()
        let copy = page.portMenuItem(secondary, copying: true)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "http://localhost:\(secondary)")
        ServerStatusWellPage(app: app).closeDetails()
        let compactShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        compactShot.name = "Toolbar — two ports in a compact window"
        compactShot.lifetime = .keepAlways
        add(compactShot)
        workspace.fillWindow()
        if !InspectorPage(app: app).header.exists {
            workspace.toggleInspectorButton.click()
        }
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { page.inspectorShowsPort(primary) })
        page.open.click()
        XCTAssertTrue(page.primaryPort.waitForExistence(timeout: 5))
        page.replace(page.primaryPort, with: String(primaryReplacement))
        XCTAssertTrue(page.additionalSelection.waitForExistence(timeout: 5))
        page.additionalSelection.click()
        XCTAssertTrue(page.additional("port").waitForExistence(timeout: 5))
        page.replace(page.additional("port"), with: String(replacement))
        XCTAssertTrue(page.additionalState("pendingRestart").waitForExistence(timeout: 5))
        let pendingShot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        pendingShot.name = "Backend settings — listener pending restart"
        pendingShot.lifetime = .keepAlways
        add(pendingShot)
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.portsDescription.contains("Restart required"))
        XCTAssertTrue(page.portsDescription.contains("Accounts: \(secondary)"))
        XCTAssertTrue(page.portsDescription.contains("Accounts: \(replacement)"))
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { page.inspectorShowsPort(primary) },
                      "While running, the inspector must show the bound port, not the pending configuration")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Toolbar — running ports with restart required"
        shot.lifetime = .keepAlways
        add(shot)
        workspace.serverToggleButton.click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 10) { page.portsDescription.contains("Server is not running") })
        XCTAssertTrue(workspace.drawerStoppedMessage.waitForExistence(timeout: 5))
        XCTAssertFalse(workspace.drawerRunningMessage.exists)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { page.inspectorShowsPort(primaryReplacement) },
                      "A stopped server shows the port configured for its next start")
        workspace.serverToggleButton.click()
        XCTAssertTrue(workspace.waitForServerURL(port: primaryReplacement))
        XCTAssertTrue(UITestApp.waitUntil(timeout: 5) { page.inspectorShowsPort(primaryReplacement) },
                      "After restart, the inspector must show the newly bound port")
        XCTAssertTrue(page.portsDescription.contains("Accounts: \(replacement)"))
        XCTAssertFalse(page.portsDescription.contains("Restart required"))
        workspace.serverToggleButton.click()
    }

    @MainActor
    func testCancelDiscardsChangesAndDisableKeepsURL() {
        launchApp()
        createProjectViaUI(name: "Settings draft")
        let page = BackendSettingsPage(app: app)
        page.open.click()
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        page.replace(page.primaryName, with: "Discarded")
        page.cancel.click()
        page.open.click()
        XCTAssertTrue(page.primaryName.waitForExistence(timeout: 5))
        XCTAssertEqual(page.primaryName.value as? String, "Primary")
        page.primaryEnabled.click()
        page.replace(page.primaryUpstream, with: "https://api.example.com")
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        page.open.click()
        XCTAssertTrue(page.primaryEnabled.waitForExistence(timeout: 5))
        page.primaryEnabled.click()
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        page.open.click()
        XCTAssertFalse(page.primaryUpstream.exists)
        page.primaryEnabled.click()
        XCTAssertTrue(page.primaryUpstream.waitForExistence(timeout: 5))
        XCTAssertEqual(page.primaryUpstream.value as? String, "https://api.example.com")
        page.cancel.click()
    }
}
