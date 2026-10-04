import AppKit
import Foundation
import Testing
@testable import AppFeatures

/// The app's half of running every UI test on CI's screen and from a clean window frame: reading
/// the pinned screen size, and forgetting the frames AppKit autosaved. The pinning arithmetic is in
/// `WorkspaceFeatureLogicTests`, beside the window frames it feeds.
@Suite("UI test screen and window isolation")
@MainActor
struct UITestWindowIsolationTests {

    /// The harness spells this key itself (`UITestEnvironment` in `MimicUITests` links no app code),
    /// so it is written here as a literal: renaming it on one side alone must fail somewhere.
    private let screenKey = "MIMIC_UITEST_SCREEN"
    private let uiTestSuite = ["MIMIC_DEFAULTS_SUITE": "com.devxa.Mimic.UITests"]

    @Test("A UI test launch pins the screen to the size it names")
    func aUITestLaunchPinsTheScreen() {
        #expect(UITestSupport.pinnedScreenEnvironmentKey == screenKey)
        #expect(UITestSupport.pinnedScreenSize(
            environment: uiTestSuite.merging([screenKey: "1024x674"]) { $1 }, arguments: []
        ) == CGSize(width: 1024, height: 674))
        // The reset argument is the other half of the UI test gate.
        #expect(UITestSupport.pinnedScreenSize(
            environment: [screenKey: "1280X800"], arguments: ["-MimicResetForTesting"]
        ) == CGSize(width: 1280, height: 800))
    }

    @Test("Nothing but a well-formed size on a UI test launch pins the screen")
    func onlyAWellFormedUITestValuePins() {
        // Not a UI test launch: a stray variable must not shrink a developer's windows.
        #expect(UITestSupport.pinnedScreenSize(environment: [screenKey: "1024x674"], arguments: []) == nil)
        // A UI test launch that pinned nothing.
        #expect(UITestSupport.pinnedScreenSize(environment: uiTestSuite, arguments: []) == nil)
        let malformedValues = ["", "1024", "1024x", "x677", "1024x677x2", "1024 x 677", "wide",
                               "0x677", "1024x-1", "nanxnan", "infx677"]
        for malformed in malformedValues {
            #expect(UITestSupport.pinnedScreenSize(
                environment: uiTestSuite.merging([screenKey: malformed]) { $1 }, arguments: []
            ) == nil, "\(malformed) should pin nothing")
        }
        // This process is a unit test run, so the size the app actually uses is no size at all, and
        // the window code sees the real screen.
        #expect(UITestSupport.pinnedScreenSize == nil)
        #expect(ScreenGeometry.visibleFrame(of: NSScreen.main) == NSScreen.main?.visibleFrame)
    }

    @Test("Forgetting autosaved window frames removes those, the split views, and nothing else")
    func autosavedWindowFramesAreForgotten() throws {
        // A suite of its own, never `.standard`: this test's host is the app, whose `.standard` is
        // the developer's real one.
        let suiteName = "UITestWindowFrames.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        // The shapes AppKit writes: the frame, then the screen it was on.
        defaults.set("344 31 680 677 0 0 1024 768 ", forKey: "NSWindow Frame SwiftUI.ModifiedContent-1-AppWindow-1")
        defaults.set("0 60 1024 677 0 0 1024 768 ", forKey: "NSWindow Frame main-AppWindow-1")
        // A navigator a test collapsed: SwiftUI's split view, then each pane's frame and state.
        defaults.set(
            ["0.000000, 0.000000, 264.000000, 674.000000, YES, NO",
             "0.000000, 0.000000, 1024.000000, 674.000000, NO, NO"],
            forKey: "NSSplitView Subview Frames SwiftUI.ModifiedContent-1-AppWindow-1, SidebarNavigationSplitView"
        )
        defaults.set(["Shell Layout"], forKey: "recentProjects")
        defaults.set("kept", forKey: "NSWindowFrameWithoutTheSpace")
        defaults.set("kept", forKey: "NSSplitViewSubviewFramesWithoutTheSpace")

        UITestSupport.removeAutosavedWindowFrames(from: defaults)

        #expect(defaults.object(forKey: "NSWindow Frame SwiftUI.ModifiedContent-1-AppWindow-1") == nil)
        #expect(defaults.object(forKey: "NSWindow Frame main-AppWindow-1") == nil)
        #expect(defaults.object(
            forKey: "NSSplitView Subview Frames SwiftUI.ModifiedContent-1-AppWindow-1, SidebarNavigationSplitView"
        ) == nil)
        #expect(defaults.stringArray(forKey: "recentProjects") == ["Shell Layout"])
        #expect(defaults.string(forKey: "NSWindowFrameWithoutTheSpace") == "kept")
        #expect(defaults.string(forKey: "NSSplitViewSubviewFramesWithoutTheSpace") == "kept")
    }
}
