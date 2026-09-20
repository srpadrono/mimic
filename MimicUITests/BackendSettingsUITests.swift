import AppKit
import Foundation
import XCTest

@MainActor
struct BackendSettingsPage {
    let app: XCUIApplication
    var open: XCUIElement { WorkspacePage(app: app).toolbarAction("backend.settingsButton") }
    var primaryName: XCUIElement { app.textFields["backend.primary.name"].firstMatch }
    var primaryPort: XCUIElement { app.textFields["backend.primary.port"].firstMatch }
    var primaryUpstream: XCUIElement { app.textFields["backend.primary.upstream"].firstMatch }
    var primaryEnabled: XCUIElement { app.descendants(matching: .any)["backend.primary.enabled"].firstMatch }
    var add: XCUIElement { app.buttons["backend.add"].firstMatch }
    var apply: XCUIElement { app.buttons["backend.apply"].firstMatch }
    var cancel: XCUIElement { app.buttons["backend.cancel"].firstMatch }
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
