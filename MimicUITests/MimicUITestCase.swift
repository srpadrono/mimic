import AppKit
import Foundation
import XCTest

/// Shared isolated launch, page objects, and UI state builders.
/// Override `configureLaunchEnvironment` to choose fixtures before spawning the app.
class MimicUITestCase: XCTestCase {

    /// The defaults suite every UI run reads and writes, and the only one a reset may clear.
    ///
    /// Same string as the original suites: `UITestSupport.defaultResetContext` names
    /// `com.devxa.Mimic.UITests` as the one domain it is allowed to remove, so a suite that invented
    /// its own name would leave its defaults behind for the next run to inherit.
    static let testSuite = "com.devxa.Mimic.UITests"

    private(set) var app: XCUIApplication!

    private(set) var welcome: WelcomePage!
    private(set) var newProjectSheet: NewProjectSheetPage!
    private(set) var workspace: WorkspacePage!
    private(set) var newEndpointSheet: NewEndpointSheetPage!
    private(set) var endpointEditor: EndpointEditorPage!
    private(set) var inspector: InspectorPage!
    private(set) var newScenarioSheet: NewScenarioSheetPage!
    private(set) var deleteConfirmation: DeleteConfirmationPage!
    private(set) var requestLogDrawer: RequestLogDrawerPage!
    private(set) var requestDetail: RequestDetailPage!
    private(set) var harImportPage: HARImportPage!
    private(set) var openAPIImportPage: OpenAPIImportPage!
    private(set) var captureSheet: CaptureJourneySheetPage!

    override func setUpWithError() throws {
        continueAfterFailure = false
        // XCTest calls this on the main thread.
        MainActor.assumeIsolated { UITestEnvironment.failUnlessDisplayFitsPinnedScreen() }
        // No reset of `testSuite` from here. This used to remove it, but the app is sandboxed, so
        // its copy of the suite lives in its own container, and the runner's removal reached a
        // different file (~/Library/Preferences, as this target is not sandboxed) that nothing
        // writes. The app clears its own copy at launch (`UITestSupport.resetAppIfNeeded`), before
        // anything reads it.
    }

    override func tearDownWithError() throws {
        app = nil
        welcome = nil
        newProjectSheet = nil
        workspace = nil
        newEndpointSheet = nil
        endpointEditor = nil
        inspector = nil
        newScenarioSheet = nil
        deleteConfirmation = nil
        requestLogDrawer = nil
        requestDetail = nil
        harImportPage = nil
        openAPIImportPage = nil
        captureSheet = nil
    }

    /// Hook for a suite that needs an extra launch key. Called once, before `launch()`.
    ///
    /// The base implementation does nothing. Override it rather than mutating
    /// `app.launchEnvironment` from a test body: by the time a test runs the process has already
    /// spawned, and the environment it was given cannot be changed.
    @MainActor
    func configureLaunchEnvironment(_ app: XCUIApplication) {}

    @MainActor
    private func prepareApp() {
        guard app == nil else { return }

        let application = XCUIApplication()
        application.launchArguments = [
            "-MimicResetForTesting",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        application.launchEnvironment["MIMIC_DEFAULTS_SUITE"] = Self.testSuite
        configureLaunchEnvironment(application)

        app = application
        welcome = WelcomePage(app: application)
        newProjectSheet = NewProjectSheetPage(app: application)
        workspace = WorkspacePage(app: application)
        newEndpointSheet = NewEndpointSheetPage(app: application)
        endpointEditor = EndpointEditorPage(app: application)
        inspector = InspectorPage(app: application)
        newScenarioSheet = NewScenarioSheetPage(app: application)
        deleteConfirmation = DeleteConfirmationPage(app: application)
        requestLogDrawer = RequestLogDrawerPage(app: application)
        requestDetail = RequestDetailPage(app: application)
        harImportPage = HARImportPage(app: application)
        openAPIImportPage = OpenAPIImportPage(app: application)
        captureSheet = CaptureJourneySheetPage(app: application)
    }

    /// Launches the app and drives it to the foreground until the welcome window is visible.
    @MainActor
    func launchApp() {
        prepareApp()
        XCTAssertTrue(
            // A timeout of 0 looks once: the launch loop does the polling.
            UITestApp.launchAndBringToForeground(app) { self.welcome.assertVisible(timeout: 0) },
            "Welcome screen should be accessible after repeated activation attempts"
        )
    }

    /// Launches for a suite whose subject is a launch that does *not* reach a usable welcome window —
    /// the store-failure alert comes up over it, so asserting the window first would fail the test
    /// before it reached the thing it is testing.
    ///
    /// `isReady` is the caller's own readiness condition, usually "the alert is up". It goes through
    /// `UITestApp.launchAndBringToForeground` like every other launch, because the first version of
    /// this method open-coded `launch()` plus one activation and dropped the five-attempt retry with
    /// it — reintroducing, in the one suite that cannot fall back on the welcome assertion, exactly
    /// the "launched but not frontmost" failure that rule 6 of the UI Definition of Done exists to
    /// prevent. A launch helper that skips the retry is not a variant of the contract; it is the bug
    /// the contract was written about.
    ///
    /// Returns whether `isReady` ever held, so the caller can assert with its own message.
    @MainActor
    @discardableResult
    func launchApp(waitingFor isReady: () -> Bool) -> Bool {
        prepareApp()
        return UITestApp.launchAndBringToForeground(app, isReady: isReady)
    }

    // MARK: - State builders

    /// Creates a project via the UI and waits for the workspace to appear.
    ///
    /// The sheet is opened with `UITestApp.click(_:expecting:)`, like every click here that opens
    /// something: it used to be clicked and waited for without an assertion, so a sheet that never
    /// opened surfaced as a failed click on a name field that was not there.
    @MainActor
    func createProjectViaUI(name: String, port: Int? = nil) {
        let newProject = welcome.newProjectButton
        XCTAssertTrue(
            UITestApp.click(newProject, expecting: { self.newProjectSheet.nameField.exists }),
            "New project should open its sheet — the button is \(UITestApp.describe(newProject))"
        )
        newProjectSheet.nameField.click()
        newProjectSheet.nameField.typeText(name)
        if let port {
            _ = newProjectSheet.portField.waitToExist(timeout: 2)
            newProjectSheet.portField.click()
            newProjectSheet.portField.typeKey("a", modifierFlags: .command)
            newProjectSheet.portField.typeText(String(port))
        }
        _ = newProjectSheet.createButton.waitToExist(timeout: 2)
        newProjectSheet.createButton.click()
        _ = workspace.assertVisible()
    }

    /// Creates an endpoint via the UI and waits for the editor to appear.
    ///
    /// `method` is honoured, unlike the original suite's helper, which took the parameter and dropped
    /// it — so every endpoint that suite created was a GET and no test ever proved the method picker
    /// does anything.
    @MainActor
    func createEndpointViaUI(name: String, path: String, method: String = "GET") {
        // Opening or creating a project can preserve a collapsed navigator. The endpoint action
        // lives in that navigator, so make the page object restore it before querying the button.
        workspace.showSidebarIfNeeded()
        XCTAssertTrue(workspace.addEndpointButton.waitToExist(timeout: 5), "Add endpoint should be reachable")
        let addEndpoint = workspace.addEndpointButton
        XCTAssertTrue(
            UITestApp.click(addEndpoint, expecting: { self.newEndpointSheet.nameField.exists }),
            "Add endpoint should open the new-endpoint sheet — it is \(UITestApp.describe(addEndpoint))"
        )
        newEndpointSheet.nameField.click()
        newEndpointSheet.nameField.typeText(name)
        newEndpointSheet.pathField.click()
        newEndpointSheet.pathField.typeKey("a", modifierFlags: .command)
        newEndpointSheet.pathField.typeText(path)

        if method != "GET" {
            selectMethod(method)
        }

        newEndpointSheet.createButton.click()
        _ = endpointEditor.pathLabel.waitToExist(timeout: 5)
    }

    /// Picks a method in the new-endpoint sheet, and proves it took by the picker's value.
    ///
    /// The method is a menu button inside the request field, so the menu has to be opened before its
    /// items exist — `app.menuItems` matches nothing while it is closed. Through
    /// `UITestApp.chooseMenuOption`, not a click on the item: a menu item is looked up twice per
    /// click, and the open menu can move between the two, which left a journey picker on the value
    /// it already had (run 37147249690). The picker's accessibility value is the method it shows, so
    /// the choice is checked rather than assumed; before, a click on the wrong row went unnoticed
    /// until something later read the endpoint's method.
    @MainActor
    func selectMethod(_ method: String) {
        let picker = newEndpointSheet.methodPicker
        XCTAssertTrue(picker.waitToExist(timeout: 2), "The requested HTTP method must be selectable")
        XCTAssertTrue(
            UITestApp.chooseMenuOption(method, in: picker, of: app) {
                picker.exists && (picker.value as? String) == method
            },
            "The method picker must offer \(method) and show it once chosen — it reads "
                + "\"\(UITestApp.spoken(picker))\", and \(UITestApp.describeOpenMenus(in: app))"
        )
    }

    /// Closes the open project via File ▸ Close Project, returning to the welcome window.
    @MainActor
    func closeProjectViaMenu() {
        let item = app.menuItems["Close Project"]
        XCTAssertTrue(item.waitToExist(timeout: 5), "File ▸ Close Project should exist")
        item.click()
    }

    /// Sends a real HTTP request to the running mock so the log has something in it.
    ///
    /// Driving traffic from the test process rather than seeding the log through a launch hook keeps
    /// the test honest: it exercises the same path a client would, so what lands in the inspector is
    /// what the engine actually recorded.
    // `@nonobjc` works around a swift-frontend crash on Xcode 26.0 (17A324): emitting the
    // native-to-foreign thunk for this `async` method on an `XCTestCase` subclass segfaults the
    // compiler in SILGen. Nothing calls it from Objective-C — XCTest only needs runtime visibility
    // for `test*` methods, and this is a helper — so hiding it from the ObjC runtime costs nothing.
    @nonobjc func sendRequest(port: Int, path: String, method: String = "GET", body: String? = nil) async {
        guard let url = URL(string: "http://127.0.0.1:\(port)\(path)") else {
            XCTFail("Could not build a request URL for \(path)")
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
        }
        request.timeoutInterval = 10
        do {
            _ = try await URLSession.shared.data(for: request)
        } catch {
            XCTFail("Request to \(path) on port \(port) failed: \(error.localizedDescription)")
        }
    }

    /// Waits for the debounced autosave to settle before the test proceeds.
    ///
    /// Deliberately does not assert on catching the transient states — `.saving` lasts only as long
    /// as a SQLite write and `.saved` clears after two seconds, so a test that required seeing them
    /// would be racing the disk.
    @MainActor
    func waitForAsyncSave() {
        if UITestApp.waitForAny(
            [workspace.autosaveSavingIndicator, workspace.autosaveSavedIndicator],
            timeout: 4
        ) {
            _ = workspace.autosaveSavedIndicator.waitToExist(timeout: 4)
            _ = workspace.autosaveSavingIndicator.waitToDisappear(timeout: 4)
        }
    }

    /// Attaches a screenshot to the result bundle.
    @MainActor
    func captureScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
