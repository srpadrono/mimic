import AppKit
import Foundation
import XCTest

/// Regenerates the two screenshots `docs/` embeds, from real application state.
///
/// Not a test of behaviour — it asserts only enough to know the frame it captured is the screen it
/// meant to capture. It exists because `docs/images/workspace.png` and `journeys.png` had drifted a
/// whole redesign behind the app, and a hand-taken screenshot drifts again the moment anything moves.
///
/// **Skipped unless `MIMIC_CAPTURE_DOCS=1`.** It writes into the working tree, which no ordinary test
/// run should do, and it is slower than the tests around it. Run it deliberately:
///
/// ```
/// MIMIC_CAPTURE_DOCS=1 xcodebuild -workspace Mimic.xcworkspace -scheme Mimic test \
///   -destination 'platform=macOS' -only-testing:MimicUITests/DocScreenshotTests
/// ```
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

    override func configureLaunchEnvironment(_ app: XCUIApplication) {
        // Light, per issue #48: both screenshots at the same size in the same appearance.
        app.launchArguments += [
            "-AppleInterfaceStyle", "Light",
            "-NSRequiresAquaSystemAppearance", "YES",
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

    @MainActor
    func testCaptureWorkspaceAndJourneys() throws {
        launchApp()
        createProjectViaUI(name: "Acme API")

        // Enough endpoints for the sidebar to look like a real project rather than an empty one, and
        // varied enough that the method column shows more than GET.
        createEndpointViaUI(name: "List users", path: "/api/v1/users")
        createEndpointViaUI(name: "Create user", path: "/api/v1/users", method: "POST")
        createEndpointViaUI(name: "User detail", path: "/api/v1/users/{id}")
        createEndpointViaUI(name: "List orders", path: "/api/v1/orders")

        XCTAssertTrue(workspace.assertVisible(), "The workspace should be on screen before capturing it")

        // Let the window settle. A capture taken mid-transition catches a half-drawn panel, and that
        // is the kind of defect nobody notices until the image is in the README.
        //
        // Polled, not paused: `UITestApp.waitForStableFrame` returns as soon as the window reports
        // the same frame twice a poll apart, which is what "settled" actually means. The fixed 1.5s
        // this replaced was both slower than it needed to be on a quiet machine and no guarantee at
        // all on a loaded CI runner — and the house rules forbid it for exactly that reason.
        UITestApp.waitForStableFrame(app.windows.firstMatch)
        try capture(named: "workspace.png")

        // Journeys. The navigator tab, not a menu item — the same route a reader of the docs takes.
        let journeys = app.buttons["Show journeys"].firstMatch
        XCTAssertTrue(journeys.waitForExistence(timeout: 5), "The navigator should offer a Journeys tab")
        journeys.click()

        UITestApp.waitForStableFrame(app.windows.firstMatch)
        try capture(named: "journeys.png")
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
