import AppKit
import Foundation
import XCTest

@MainActor
private struct BackendSettingsPage {
    let app: XCUIApplication

    var openButton: XCUIElement { app.buttons["backend.settingsButton"].firstMatch }
    var sheet: XCUIElement { app.descendants(matching: .any)["backend.settings"].firstMatch }
    var primaryPort: XCUIElement { app.textFields["backend.primary.port"].firstMatch }
    var primaryUpstream: XCUIElement { app.textFields["backend.primary.upstream"].firstMatch }
    var savePrimary: XCUIElement { app.buttons["backend.primary.save"].firstMatch }
    var name: XCUIElement { app.textFields["backend.name"].firstMatch }
    var port: XCUIElement { app.textFields["backend.port"].firstMatch }
    var upstream: XCUIElement { app.textFields["backend.upstream"].firstMatch }
    var saveBackend: XCUIElement { app.buttons["backend.save"].firstMatch }
    var error: XCUIElement { app.staticTexts["backend.error"].firstMatch }
    var done: XCUIElement { app.buttons["backend.done"].firstMatch }

    func replace(_ field: XCUIElement, with value: String) {
        field.click()
        field.typeKey("a", modifierFlags: .command)
        // Pasting keeps punctuation intact across keyboard layouts (notably the colon in a URL).
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        _ = pasteboard.setString(value, forType: .string)
        app.typeKey("v", modifierFlags: .command)
    }
}

final class BackendSettingsUITests: MimicUITestCase {
    @MainActor
    func testConfigureTwoBackendPortsAndRejectDuplicatePort() {
        launchApp()
        createProjectViaUI(name: "Two backends")
        let settings = BackendSettingsPage(app: app)
        XCTAssertTrue(settings.openButton.waitForExistence(timeout: 5))
        settings.openButton.click()
        XCTAssertTrue(settings.primaryPort.waitForExistence(timeout: 5))
        settings.replace(settings.primaryUpstream, with: "https://api.example.com")
        settings.savePrimary.click()

        settings.replace(settings.name, with: "Accounts")
        settings.replace(settings.port, with: "8081")
        settings.replace(settings.upstream, with: "https://accounts.example.com")
        settings.saveBackend.click()
        XCTAssertTrue(app.buttons.matching(NSPredicate(
            format: "label == %@", "Edit Accounts"
        )).firstMatch.waitForExistence(timeout: 5), app.debugDescription)

        settings.replace(settings.name, with: "Duplicate")
        settings.replace(settings.port, with: "8081")
        settings.saveBackend.click()
        XCTAssertTrue(settings.error.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons.matching(NSPredicate(
            format: "label == %@", "Edit Duplicate"
        )).firstMatch.exists)
        settings.done.click()
    }
}
