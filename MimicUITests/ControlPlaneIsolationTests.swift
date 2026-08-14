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

    /// Asserts the mechanism, not the file system: every suite launches through
    /// `UITestApp.launchAndBringToForeground` (UI DoD rule 6), so one launch here stands in for
    /// every suite. Watching the shared path itself would race the developer's own instance, which
    /// is free to rewrite its advertisement mid-run — and the sandboxed runner could not reach the
    /// unsandboxed copy anyway.
    @MainActor
    func testLaunchContractExportsAThrowawayDiscoveryFile() throws {
        let application = XCUIApplication()
        application.launchArguments = [
            "-MimicResetForTesting",
            "-ApplePersistenceIgnoreState",
            "YES",
        ]
        application.launchEnvironment["MIMIC_DEFAULTS_SUITE"] = "com.devxa.Mimic.UITests"
        // Port 0 for the reason the journeys suite sets it: the OS picks a free port, so this
        // launch neither collides with a developer's running instance nor with a parallel run.
        application.launchEnvironment["MIMIC_CONTROL_PORT"] = "0"
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
            "The isolation must not clobber environment a suite set deliberately"
        )
    }
}
