import XCTest

/// The update sheet, driven through the menu item a user actually reaches it from.
///
/// The feed is a **bundled fixture**, never the network: the runner passes a resource *name* through
/// `MIMIC_UPDATE_FEED_FIXTURE` and the app reads it out of `Bundle.main`. That is the same
/// arrangement `MIMIC_IMPORT_FILE` arrived at, and for the same reason — the app is sandboxed, so a
/// path the runner writes cannot be read, and a suite that reached GitHub would fail whenever the
/// network did and would go stale the day a real release shipped.
final class UpdateUITests: MimicUITestCase {

    /// Which fixture this test wants. Set before `launchApp()`, because the environment a process was
    /// launched with cannot be changed once it is running.
    private var feedFixture: String = UpdateFixtures.available
    private var installFixture: String?

    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        app.launchEnvironment["MIMIC_UPDATE_FEED_FIXTURE"] = feedFixture
        app.launchEnvironment["MIMIC_UPDATE_INSTALL_FIXTURE"] = installFixture
    }

    private var updateSheet: UpdateSheetPage { UpdateSheetPage(app: app) }

    @MainActor
    func testQuitAndInstallTerminatesAfterHandoff() {
        installFixture = "success"
        launchApp()
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.downloadButton.waitForExistence(timeout: 10))
        updateSheet.downloadButton.click()
        XCTAssertTrue(updateSheet.installButton.waitForExistence(timeout: 10))
        captureUpdateEvidence("Ready to quit — simulated installer")
        updateSheet.installButton.click()
        XCTAssertTrue(app.wait(for: .notRunning, timeout: 15), "Successful handoff must actually quit Mimic")
    }

    @MainActor
    func testFailedInstallerHandoffKeepsAppOpenAndExplainsFailure() {
        installFixture = "failure"
        launchApp()
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.downloadButton.waitForExistence(timeout: 10))
        updateSheet.downloadButton.click()
        XCTAssertTrue(updateSheet.installButton.waitForExistence(timeout: 10))
        updateSheet.installButton.click()
        XCTAssertTrue(updateSheet.failure.waitForExistence(timeout: 10))
        XCTAssertTrue(updateSheet.text(of: updateSheet.failure).contains("Fixture handoff refused"))
        XCTAssertNotEqual(app.state, .notRunning)
        captureUpdateEvidence("Installer handoff failure — app remains open")
    }

    @MainActor
    private func captureUpdateEvidence(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - The menu item

    @MainActor
    func testCheckForUpdatesMenuItemExists() {
        launchApp()

        XCTAssertTrue(
            updateSheet.menuItem.waitForExistence(timeout: 5),
            "Mimic ▸ Check for Updates… should exist"
        )
    }

    // MARK: - An update is available

    @MainActor
    func testAnAvailableUpdateIsOffered() {
        feedFixture = UpdateFixtures.available
        launchApp()

        updateSheet.openFromMenu()

        XCTAssertTrue(updateSheet.title.waitForExistence(timeout: 10), "the sheet should appear")
        let title = updateSheet.text(of: updateSheet.title)
        XCTAssertTrue(title.contains("99.0.0"), "expected the fixture's version in the title, got \(title)")
        XCTAssertTrue(updateSheet.downloadButton.waitForExistence(timeout: 5))
        XCTAssertTrue(updateSheet.skipButton.exists)
        XCTAssertTrue(updateSheet.laterButton.exists)
        XCTAssertTrue(updateSheet.notes.exists, "the release notes should be shown")
        let screenshot = XCTAttachment(screenshot: app.sheets.firstMatch.screenshot())
        screenshot.name = "update-available-sheet"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    /// The control label that was truncated to "Skip this versi…" the first time this sheet was
    /// built, because four controls shared a row narrower than they needed.
    @MainActor
    func testEveryButtonLabelIsWholeRatherThanTruncated() {
        feedFixture = UpdateFixtures.available
        launchApp()
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.downloadButton.waitForExistence(timeout: 10))

        for button in [updateSheet.skipButton, updateSheet.laterButton, updateSheet.downloadButton] {
            XCTAssertFalse(
                button.label.contains("\u{2026}"),
                "\"\(button.label)\" is truncated — the row is too narrow for its controls"
            )
        }
    }

    @MainActor
    func testLaterClosesTheSheetWithoutDownloading() {
        feedFixture = UpdateFixtures.available
        launchApp()
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.laterButton.waitForExistence(timeout: 10))

        updateSheet.laterButton.click()

        XCTAssertTrue(
            updateSheet.waitForDisappearance(of: updateSheet.title, timeout: 5),
            "the sheet should close"
        )
    }

    @MainActor
    func testSkippingClosesTheSheet() {
        feedFixture = UpdateFixtures.available
        launchApp()
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.skipButton.waitForExistence(timeout: 10))

        updateSheet.skipButton.click()

        XCTAssertTrue(updateSheet.waitForDisappearance(of: updateSheet.title, timeout: 5))
        updateSheet.openFromMenu()
        XCTAssertTrue(updateSheet.downloadButton.waitForExistence(timeout: 10),
                      "A manual check must offer the newer version even after it was skipped")
        XCTAssertTrue(updateSheet.text(of: updateSheet.title).contains("99.0.0"))
        XCTAssertFalse(updateSheet.upToDate.exists)
        captureUpdateEvidence("Skipped release offered by manual check")
    }

    // MARK: - Nothing to install

    /// A manual check that finds nothing still has to say so — swallowing the answer makes the menu
    /// item look broken.
    @MainActor
    func testAnUpToDateInstanceStillAnswers() {
        feedFixture = UpdateFixtures.upToDate
        launchApp()

        updateSheet.openFromMenu()

        XCTAssertTrue(updateSheet.title.waitForExistence(timeout: 10))
        XCTAssertTrue(updateSheet.upToDate.waitForExistence(timeout: 5),
                      "an up-to-date check should say so rather than closing silently")
        XCTAssertTrue(updateSheet.doneButton.exists)
        XCTAssertFalse(updateSheet.downloadButton.exists, "there is nothing to download")
    }

    // MARK: - Failure

    /// A release with nothing installable attached is not an update, and the sheet has to say what
    /// went wrong rather than sitting on a spinner.
    @MainActor
    func testAFeedWithNoInstallerReportsAFailure() {
        feedFixture = UpdateFixtures.noInstaller
        launchApp()

        updateSheet.openFromMenu()

        XCTAssertTrue(updateSheet.failure.waitForExistence(timeout: 10),
                      "the sheet should report the failure")
        // Asserting *which* failure, because this test passed for months of a single afternoon while
        // the fixture could not be found at all: every check failed as "could not reach the release
        // feed", which is also a failure, and the branch this test names was never run.
        let reason = updateSheet.text(of: updateSheet.failure)
        XCTAssertTrue(reason.contains("no .pkg installer"), "expected the no-installer refusal, got \(reason)")
        XCTAssertTrue(updateSheet.releasesLink.exists,
                      "a failed check should still offer a way to the releases page")
    }
}

/// The fixture names, which are the whole of what the app is told.
///
/// The bytes live in `App/Resources/UITestFixtures/`; these are the file names. Written out rather
/// than derived, so a renamed resource fails here by name instead of as a mysterious timeout.
enum UpdateFixtures {
    static let available = "mimic-uitest-update-available.json"
    static let upToDate = "mimic-uitest-update-uptodate.json"
    static let noInstaller = "mimic-uitest-update-noinstaller.json"
}

/// Page object for the update sheet. No raw queries in test bodies.
struct UpdateSheetPage {
    let app: XCUIApplication

    /// The menu item, reached through the app menu rather than by keyboard shortcut — it has none,
    /// deliberately, because it is not something you invoke often enough to need one.
    var menuItem: XCUIElement { app.menuBars.menuItems["Check for Updates…"] }

    var title: XCUIElement { app.staticTexts["update.title"] }
    var upToDate: XCUIElement { app.staticTexts["update.upToDate"] }
    var notes: XCUIElement { app.descendants(matching: .any)["update.notes"] }
    var failure: XCUIElement { app.staticTexts["update.failure"] }
    var releasesLink: XCUIElement { app.descendants(matching: .any)["update.releasesLink"] }

    var skipButton: XCUIElement { app.buttons["update.skipButton"] }
    var laterButton: XCUIElement { app.buttons["update.laterButton"] }
    var downloadButton: XCUIElement { app.buttons["update.downloadButton"] }
    var installButton: XCUIElement { app.buttons["update.installButton"] }
    var doneButton: XCUIElement { app.buttons["update.doneButton"] }
    var automaticToggle: XCUIElement { app.checkBoxes["update.automaticToggle"] }

    /// The string an element is showing, wherever AppKit put it.
    ///
    /// A short `Text` arrives with its string as the element's `label`; a long or wrapping one
    /// arrives with an empty label and the string in `value` instead — the same trap
    /// `DSEmptyState` set, recorded in the UI-test skill. Asserting on `label` alone therefore
    /// compares against `""` and fails with a message that shows nothing, which reads as the view
    /// being missing rather than as the query being wrong.
    @MainActor
    func text(of element: XCUIElement) -> String {
        if !element.label.isEmpty { return element.label }
        return element.value as? String ?? ""
    }

    /// Opens the sheet the way a person does.
    @MainActor
    func openFromMenu() {
        let mimicMenu = app.menuBars.menuBarItems.element(boundBy: 1)
        XCTAssertTrue(mimicMenu.waitForExistence(timeout: 5), "the Mimic menu should exist")
        mimicMenu.click()
        XCTAssertTrue(menuItem.waitForExistence(timeout: 5), "Check for Updates… should be in the menu")
        menuItem.click()
    }

    /// `waitForExistence` has no negative form, and `!exists` alone races a sheet that is still
    /// animating out.
    @MainActor
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !element.exists { return true }
            _ = element.waitForExistence(timeout: 0.1)
        }
        return !element.exists
    }
}
