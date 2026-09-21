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
    var primaryUpstream: XCUIElement { app.textFields["backend.primary.upstream"].firstMatch }
    var primaryEnabled: XCUIElement { app.descendants(matching: .any)["backend.primary.enabled"].firstMatch }
    var add: XCUIElement { app.buttons["backend.add"].firstMatch }
    var apply: XCUIElement { app.buttons["backend.apply"].firstMatch }
    var cancel: XCUIElement { app.buttons["backend.cancel"].firstMatch }
    func portMenuItem(_ port: Int, copying: Bool = false) -> XCUIElement {
        app.descendants(matching: .any)["serverStatusWell.\(copying ? "copyPort" : "configuredPort").\(port)"].firstMatch
    }
    var portsDescription: String { "\(ports.label) \(ports.value.map { String(describing: $0) } ?? "")" }
    var ports: XCUIElement { app.buttons["serverStatusWell.backends"].firstMatch }
    var error: XCUIElement { app.staticTexts["backend.error"].firstMatch }
    func additional(_ suffix: String) -> XCUIElement {
        app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND identifier ENDSWITH %@ AND NOT identifier BEGINSWITH %@", "backend.", "." + suffix, "backend.primary.")).firstMatch
    }
    func replace(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        app.typeKey("v", modifierFlags: .command)
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
        XCTAssertTrue(page.captureHelp.waitForExistence(timeout: 5))
        let captureHelp = "\(page.captureHelp.label) \(page.captureHelp.value as? String ?? "")"
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        XCTAssertTrue(captureHelp.contains("5 MiB"), captureHelp)
        XCTAssertTrue(captureHelp.contains("64 KiB"), captureHelp)
        let captureHelpImage = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        captureHelpImage.name = "capture-limit-help"
        captureHelpImage.lifetime = .keepAlways
        add(captureHelpImage)
        let singleBackendHeight = app.sheets.firstMatch.frame.height
        XCTAssertLessThan(singleBackendHeight, 600, "A single backend should not open a mostly empty sheet")
        page.replace(page.primaryName, with: "Catalog")
        page.primaryEnabled.click()
        page.replace(page.primaryUpstream, with: "https://catalog.example.com/api")
        page.add.click()
        // Grouped Form lazily realizes the new card below the viewport on a short display.
        // Scroll the form, not the sheet's fixed action row, before addressing its fields.
        let form = app.sheets.firstMatch.scrollViews.firstMatch
        for _ in 0..<4 where !page.additional("name").exists {
            form.swipeUp()
        }
        XCTAssertTrue(
            page.additional("name").waitForExistence(timeout: 5),
            "Added backend name is absent after scrolling: \(app.debugDescription)"
        )
        XCTAssertTrue(page.apply.isHittable, "The action row must stay on-screen when the form grows")
        XCTAssertGreaterThanOrEqual(
            app.sheets.firstMatch.frame.height, singleBackendHeight,
            "Adding a backend should not shrink the sheet"
        )
        page.replace(page.additional("name"), with: "Accounts")
        page.replace(page.additional("port"), with: "8080")
        page.apply.click()
        XCTAssertTrue(page.error.waitForExistence(timeout: 5))
        page.replace(page.additional("port"), with: "18081")
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.ports.waitForExistence(timeout: 5))
        XCTAssertTrue(page.portsDescription.contains("2 ports configured"), "\(page.portsDescription)\n\(app.debugDescription)")
        XCTAssertTrue(page.portsDescription.contains("Accounts: 18081"))
        app.activate()
        page.ports.click()
        XCTAssertTrue(page.portMenuItem(18081).waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertEqual(page.portMenuItem(18081).value as? String, "Accounts: 18081")
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
        XCTAssertEqual(page.additional("port").value as? String, "18081")
        let screenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        screenshot.name = "Backend settings — saved configuration"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        page.cancel.click()
    }

    @MainActor
    func testToolbarDistinguishesListeningAndPendingPorts() throws {
        func freePort() throws -> Int {
            let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            defer { Darwin.close(descriptor) }
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
        let primary = try freePort(), secondary = try freePort(), replacement = try freePort()
        launchApp()
        createProjectViaUI(name: "Listening ports")
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
        workspace.compactWindow()
        XCTAssertTrue(page.ports.isHittable)
        XCTAssertTrue(workspace.serverURLText(port: primary).isHittable)
        page.ports.click()
        let copy = page.portMenuItem(secondary, copying: true)
        XCTAssertTrue(copy.waitForExistence(timeout: 5), app.debugDescription)
        copy.click()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "http://localhost:\(secondary)")
        let compactShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        compactShot.name = "Toolbar — two ports in a compact window"
        compactShot.lifetime = .keepAlways
        add(compactShot)
        workspace.fillWindow()
        page.open.click()
        XCTAssertTrue(page.additional("port").waitForExistence(timeout: 5))
        page.replace(page.additional("port"), with: String(replacement))
        page.apply.click()
        XCTAssertTrue(page.apply.waitForNonExistence(timeout: 5))
        XCTAssertTrue(page.portsDescription.contains("Restart required"))
        XCTAssertTrue(page.portsDescription.contains("Accounts: \(secondary)"))
        XCTAssertTrue(page.portsDescription.contains("Accounts: \(replacement)"))
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Toolbar — running ports with restart required"
        shot.lifetime = .keepAlways
        add(shot)
        workspace.serverToggleButton.click()
        XCTAssertTrue(UITestApp.waitUntil(timeout: 10) { page.portsDescription.contains("Server is not running") })
        workspace.serverToggleButton.click()
        XCTAssertTrue(workspace.waitForServerURL(port: primary))
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
        XCTAssertTrue(page.primaryUpstream.waitForExistence(timeout: 5))
        XCTAssertEqual(page.primaryUpstream.value as? String, "https://api.example.com")
        XCTAssertFalse(page.primaryUpstream.isEnabled)
        page.cancel.click()
    }
}
