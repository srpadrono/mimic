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
    }

    @Test("A stored height below the floor is clamped on read, not restored and then snapped")
    func storedHeightBelowTheFloorIsClamped() {
        let defaults = Self.makeDefaults()
        // Written by a build whose floor was lower than today's. Not hand-edited nonsense — a
        // perfectly good preference that the current split view no longer permits.
        defaults.set(Double(60), forKey: "panel.requestLog.height")

        let loaded = PanelLayoutStore(defaults: defaults).load()

        #expect(loaded.requestLogHeight == PanelLayoutStore.Bounds.minimumRequestLogHeight)
        // The failure this prevents is not a crash: AppKit would restore the 60, then snap the pane
        // to its minimum on the first interaction, so the panel appears to jump for no reason the
        // user caused.
        #expect(loaded.requestLogHeight >= PanelLayoutStore.Bounds.minimumRequestLogHeight)
    }

    @Test("A stored height above the floor is honoured exactly — the clamp is a floor, not a resize")
    func storedHeightAboveTheFloorIsUntouched() {
        let defaults = Self.makeDefaults()
        defaults.set(Double(700), forKey: "panel.requestLog.height")

        // Too tall for a small window is not nonsense; it is a preference a bigger window will
        // honour again, so narrowing it stays layout's job rather than the store's.
        #expect(PanelLayoutStore(defaults: defaults).load().requestLogHeight == 700)
    }

    @Test("The measured bounds the redesign's width policy depends on")
    func boundsMatchTheRecordedWidthPolicy() {
        // These are not preferences, they are the arithmetic in docs/redesign/decisions.md §1.
        // Changing one without re-measuring is how the request log quietly loses its Path column.
        #expect(PanelLayoutStore.Bounds.minimumInspectorWidth == 260)
        #expect(PanelLayoutStore.Bounds.minimumWindowContentWidth == 1140)

        // The floor has to leave room for the navigator, the inspector at its own floor, the log's
        // 380pt of fixed columns and a 180pt minimum path.
        let navigator: CGFloat = 300
        let logFixedColumns: CGFloat = 380
        let minimumPath: CGFloat = 180
        let needed = navigator
            + PanelLayoutStore.Bounds.minimumInspectorWidth
            + logFixedColumns
            + minimumPath
        #expect(PanelLayoutStore.Bounds.minimumWindowContentWidth >= needed)
    }

    @Test("An arrangement survives a save and reload")
    func roundTrip() {
        let defaults = Self.makeDefaults()
        let saved = PanelLayout(
            requestLogHeight: 340,
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
        // Someone on a 6K display who dragged the panel out past 1000pt. The store used to clamp this
        // to 400 on the way in *and* on the way out, so the arrangement was not merely refused, it was
        // destroyed. Narrowing an oversized value to fit is now the split view's job, and it does it
        // without writing back — so the preference survives a spell in a smaller window.
        defaults.set(1_200.0, forKey: "panel.requestLog.height")

        let layout = PanelLayoutStore(defaults: defaults).load()
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

    @Test("Both panes keep a usable floor, and the two floors cannot exceed a real window")
    func floorsLeaveRoomForBothPanes() {
        // These two are the split view items' `minimumThickness` values, so together they are the
        // shortest editor column the layout can produce. A pair that did not fit a small window would
        // make the divider undraggable rather than merely tight.
        let combined = PanelLayoutStore.Bounds.minimumCentreHeight
            + PanelLayoutStore.Bounds.minimumRequestLogHeight
        #expect(combined <= 400)
        #expect(PanelLayoutStore.Bounds.minimumRequestLogHeight > 0)
        #expect(PanelLayoutStore.Bounds.minimumCentreHeight > 0)
    }

    @Test("The inspector's bounds are constants, not stored values")
    func inspectorBoundsAreConstants() {
        // `panel.inspector.width` used to be read at launch and written straight back untouched, so
        // the store held a number nothing decided. AppKit restores that column with the window; only
        // the floor and the preferred width are ours to state.
        #expect(PanelLayoutStore.Bounds.minimumInspectorWidth > 0)
        #expect(PanelLayoutStore.Bounds.idealInspectorWidth >= PanelLayoutStore.Bounds.minimumInspectorWidth)
    }

    @Test("A nonsensical stored size falls back to the default")
    func nonsenseSizesFallBack() {
        let defaults = Self.makeDefaults()
        defaults.set(0.0, forKey: "panel.requestLog.height")

        let layout = PanelLayoutStore(defaults: defaults).load()
        #expect(layout.requestLogHeight == PanelLayout.default.requestLogHeight)

        let nonFinite = Self.makeDefaults()
        nonFinite.set(Double.nan, forKey: "panel.requestLog.height")
        #expect(
            PanelLayoutStore(defaults: nonFinite).load().requestLogHeight
                == PanelLayout.default.requestLogHeight
        )
    }

    @Test("Saving records what was chosen, bar the sanity ceiling")
    func savingKeepsTheChosenSize() {
        let defaults = Self.makeDefaults()
        PanelLayoutStore(defaults: defaults).save(PanelLayout(requestLogHeight: 640))
        // 640 is a perfectly reasonable panel on a large display and comes back untouched.
        #expect(PanelLayoutStore(defaults: defaults).load().requestLogHeight == 640)

        let absurd = Self.makeDefaults()
        PanelLayoutStore(defaults: absurd).save(PanelLayout(requestLogHeight: 9_000))
        // 9000 is not a window anyone has.
        #expect(
            PanelLayoutStore(defaults: absurd).load().requestLogHeight
                == PanelLayoutStore.Bounds.storedSizeLimit
        )
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
