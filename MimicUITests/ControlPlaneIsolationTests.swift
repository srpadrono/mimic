import AppKit
import Foundation
import XCTest

/// The discovery-file half of UI-test isolation: a run must never touch the shared `control.json`.
///
/// The shared file is credential material — the app writes its `X-Mimic-Token` there on every
/// control-plane bind and removes the file on shutdown. Before the launch contract exported
/// `MIMIC_CONTROL_FILE`, every UI test launch therefore overwrote the developer's live
/// advertisement, and every teardown deleted it, leaving a still-running Mimic that no `mimic`
/// command could discover until relaunch — the `mimic.sqlite` failure class, applied to a
/// credential.
final class ControlPlaneIsolationTests: XCTestCase {

    /// Every suite launches through `UITestApp.launchAndBringToForeground`. This launch checks the
    /// exported override, the isolated file's actual existence, and a live authenticated health
    /// request on the app's assigned loopback port. File permissions are covered by the separate
    /// `ControlEndpointFileTests`; macOS denies the UI runner read access to the app container.
    @MainActor
    func testLaunchContractExportsAThrowawayDiscoveryFile() async throws {
        let application = XCUIApplication()
        application.launchArguments = [
            "-MimicResetForTesting",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        application.launchEnvironment["MIMIC_DEFAULTS_SUITE"] = "com.devxa.Mimic.UITests"
        let token = "UITest-\(UUID().uuidString)"
        application.launchEnvironment["MIMIC_CONTROL_TOKEN"] = token
        let preexistingPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: UITestApp.bundleIdentifier
        ).map(\.processIdentifier))
        defer { application.terminate() }

        XCTAssertTrue(
            UITestApp.launchAndBringToForeground(application) { true },
            "App should reach the foreground through the shared launch contract"
        )

        // The key is a literal, like the two the suites export above: this test predates nothing —
        // written against the un-isolated launch path it would compile cleanly and fail on this
        // unwrap, because no suite and no shared helper exported the override.
        let override = try XCTUnwrap(
            application.launchEnvironment["MIMIC_CONTROL_FILE"],
            "Every UI launch must export MIMIC_CONTROL_FILE; without it the app advertises into the shared control.json and deletes it on the way out"
        )

        // `ControlEndpointDiscovery.overrideURL` treats an empty value as unset, so an empty export
        // would fall through to the shared path while this test still saw the key present.
        XCTAssertFalse(
            override.isEmpty,
            "The exported override must name a path — the app treats an empty value as unset"
        )

        // The name is the guard, as with mimic-uitests.sqlite: whichever directory the sandboxed
        // app expands the path into, a file not called control.json can never be the shared
        // advertisement.
        XCTAssertNotEqual(
            URL(fileURLWithPath: (override as NSString).expandingTildeInPath).lastPathComponent,
            "control.json",
            "The override must not resolve to the shared discovery file's own name"
        )

        XCTAssertEqual(
            application.launchEnvironment["MIMIC_CONTROL_PORT"], "0",
            "The shared launch helper must choose an ephemeral port when the suite did not name one"
        )

        // The app's tilde resolves inside its container. The runner can observe this file's
        // existence but macOS denies reading its contents, which is the boundary the app relies on.
        let advertisedFile = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/devxa.Mimic/Data/Library/Application Support/devxa.Mimic")
            .appendingPathComponent(URL(fileURLWithPath: override).lastPathComponent)
        XCTAssertTrue(UITestApp.waitUntil(timeout: 10) {
            FileManager.default.fileExists(atPath: advertisedFile.path)
        }, "The running app should publish its isolated discovery file")
        let launched = try XCTUnwrap(NSRunningApplication.runningApplications(
            withBundleIdentifier: UITestApp.bundleIdentifier
        ).first { !preexistingPIDs.contains($0.processIdentifier) })
        var assignedPort: Int?
        XCTAssertTrue(UITestApp.waitUntil(timeout: 10) {
            assignedPort = UITestApp.listeningLoopbackPort(of: launched.processIdentifier)
            return assignedPort != nil
        }, "The launched app should bind an ephemeral loopback control port")
        let port = try XCTUnwrap(assignedPort)
        let healthURL = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)/v1/health"))
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 5
        request.setValue(token, forHTTPHeaderField: "X-Mimic-Token")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
}
