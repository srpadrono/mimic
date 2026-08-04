import Foundation
import Testing
@testable import Persistence

/// The window arrangement has to survive a quit, and has to survive a *bad* stored value.
@Suite("Panel layout persistence")
struct PanelLayoutStoreTests {

    /// A throwaway suite per test, so cases cannot see each other's writes.
    static func makeDefaults() -> UserDefaults {
        let suite = "panel.layout.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test("An empty store returns the shipped defaults rather than zeros")
    func emptyStoreUsesDefaults() {
        let layout = PanelLayoutStore(defaults: Self.makeDefaults()).load()
        #expect(layout == PanelLayout.default)
        // The trap this guards: `UserDefaults.double(forKey:)` returns 0 for a missing key, which
        // would collapse both panels to nothing on first launch.
        #expect(layout.requestLogHeight > 0)
        #expect(layout.inspectorWidth > 0)
    }

    @Test("An arrangement survives a save and reload")
    func roundTrip() {
        let defaults = Self.makeDefaults()
        let saved = PanelLayout(
            requestLogHeight: 340,
            inspectorWidth: 320,
            isRequestLogVisible: false,
            isInspectorVisible: true
        )
        PanelLayoutStore(defaults: defaults).save(saved)

        // A second store over the same defaults stands in for the next launch.
        #expect(PanelLayoutStore(defaults: defaults).load() == saved)
    }

    @Test("Hiding a panel is remembered — false is a value, not an absent key")
    func hiddenPanelsAreRemembered() {
        let defaults = Self.makeDefaults()
        PanelLayoutStore(defaults: defaults).save(
            PanelLayout(isRequestLogVisible: false, isInspectorVisible: false)
        )
        let reloaded = PanelLayoutStore(defaults: defaults).load()
        // `bool(forKey:)` also returns false for a missing key, so "hidden" and "never set" have to
        // be told apart — otherwise the default of `true` would quietly reopen the panel.
        #expect(reloaded.isRequestLogVisible == false)
        #expect(reloaded.isInspectorVisible == false)
    }

    @Test("A large stored size is kept — the window decides what fits, not the store")
    func largeSizesSurviveTheStore() {
        let defaults = Self.makeDefaults()
        // Someone on a 6K display who dragged a panel out past 900pt. The store used to clamp this to
        // 400 on the way in *and* on the way out, so the arrangement was not merely refused, it was
        // destroyed. Whoever lays the panel out narrows it when a window is too small — for the
        // request log that is `maximumRequestLogHeight`, for the inspector it is now SwiftUI's own
        // column — and the preference survives either way.
        defaults.set(900.0, forKey: "panel.inspector.width")
        defaults.set(1_200.0, forKey: "panel.requestLog.height")

        let layout = PanelLayoutStore(defaults: defaults).load()
        #expect(layout.inspectorWidth == 900)
        #expect(layout.requestLogHeight == 1_200)
    }

    @Test("An absurd stored size is still refused")
    func absurdSizesHitTheSanityCeiling() {
        let defaults = Self.makeDefaults()
        // A hand-edited plist, not a drag. There is no window this could be right for.
        defaults.set(999_999.0, forKey: "panel.requestLog.height")

        let layout = PanelLayoutStore(defaults: defaults).load()
        #expect(layout.requestLogHeight == PanelLayoutStore.Bounds.storedSizeLimit)
    }

    @Test("The request log may grow until the centre pane hits its minimum")
    func layoutLimitsLeaveRoomForTheCentre() {
        // 900pt of column, 240pt reserved for the editor.
        #expect(PanelLayoutStore.maximumRequestLogHeight(containerHeight: 900) == 660)
    }

    @Test("A window too small for the reserve still leaves the panel its minimum")
    func layoutLimitsNeverGoBelowTheFloor() {
        // The subtraction goes negative here; the floor has to win, or the panel would be told its
        // maximum is smaller than its minimum and collapse.
        #expect(
            PanelLayoutStore.maximumRequestLogHeight(containerHeight: 100)
                == PanelLayoutStore.Bounds.minimumRequestLogHeight
        )
    }

    @Test("An unmeasured container does not clamp anything")
    func unmeasuredContainerIsUnbounded() {
        // Zero means "not laid out yet". Treating that as a real bound would squash a restored panel
        // to its minimum for a frame on every launch.
        #expect(
            PanelLayoutStore.maximumRequestLogHeight(containerHeight: 0)
                == PanelLayoutStore.Bounds.storedSizeLimit
        )
    }

    @Test("A nonsensical stored size falls back to the default")
    func nonsenseSizesFallBack() {
        let defaults = Self.makeDefaults()
        defaults.set(0.0, forKey: "panel.requestLog.height")
        defaults.set(Double.nan, forKey: "panel.inspector.width")

        let layout = PanelLayoutStore(defaults: defaults).load()
        #expect(layout.requestLogHeight == PanelLayout.default.requestLogHeight)
        #expect(layout.inspectorWidth == PanelLayout.default.inspectorWidth)
    }

    @Test("Saving records what was chosen, bar the sanity ceiling")
    func savingKeepsTheChosenSize() {
        let defaults = Self.makeDefaults()
        PanelLayoutStore(defaults: defaults).save(
            PanelLayout(requestLogHeight: 9_000, inspectorWidth: 640)
        )
        let reloaded = PanelLayoutStore(defaults: defaults).load()
        // 640 is a perfectly reasonable inspector on a large display and comes back untouched.
        #expect(reloaded.inspectorWidth == 640)
        // 9000 is not a window anyone has.
        #expect(reloaded.requestLogHeight == PanelLayoutStore.Bounds.storedSizeLimit)
    }

    @Test("Two stores over different suites do not see each other")
    func suitesAreIsolated() {
        // This is what keeps a UI test run from overwriting the developer's real window arrangement.
        let a = PanelLayoutStore(defaults: Self.makeDefaults())
        let b = PanelLayoutStore(defaults: Self.makeDefaults())
        a.save(PanelLayout(requestLogHeight: 480))
        #expect(b.load().requestLogHeight == PanelLayout.default.requestLogHeight)
    }
}
