import Foundation

/// Where the workspace's panels were left: how big each one was, and whether it was open.
///
/// Panel geometry was previously plain `@State`, so every launch reset the request log to 220pt and
/// the inspector to 280pt no matter how the window had been arranged. Someone who works with the log
/// collapsed had to collapse it again every morning. Window arrangement is a preference, and a tool
/// people keep open all day should remember it.
///
/// Backed by `UserDefaults` rather than the project database on purpose: this is a property of *this
/// machine's window*, not of the mock configuration, so it must not travel through project
/// export/import or make a project file dirty.
///
/// The inspector's *width* is deliberately not here. It is an `.inspector` column, which means AppKit
/// restores it with the window; a copy in this store was read at launch and written straight back
/// untouched, so `panel.inspector.width` had become a value nothing decided and nothing consulted.
/// Two records of one number is how they drift.
public struct PanelLayout: Equatable, Sendable {
    public var requestLogHeight: CGFloat
    public var isRequestLogVisible: Bool
    public var isInspectorVisible: Bool

    public static let `default` = PanelLayout(
        requestLogHeight: 220,
        isRequestLogVisible: true,
        isInspectorVisible: true
    )

    public init(
        requestLogHeight: CGFloat = PanelLayout.default.requestLogHeight,
        isRequestLogVisible: Bool = PanelLayout.default.isRequestLogVisible,
        isInspectorVisible: Bool = PanelLayout.default.isInspectorVisible
    ) {
        self.requestLogHeight = requestLogHeight
        self.isRequestLogVisible = isRequestLogVisible
        self.isInspectorVisible = isInspectorVisible
    }
}

/// Persists `PanelLayout` in `UserDefaults`.
///
/// Takes the defaults instance rather than reaching for `.standard`, so a UI test run gets its own
/// suite and cannot inherit — or corrupt — the developer's real window arrangement. That is the same
/// arrangement `RecentProjectsStore` uses, and the reason `@AppStorage` is not used here: it binds to
/// `.standard` unless every call site remembers to pass a store.
// @unchecked Sendable: UserDefaults is documented as thread-safe for get/set, and every method here
// is a stateless read or write.
public final class PanelLayoutStore: @unchecked Sendable {

    private enum Key {
        static let requestLogHeight = "panel.requestLog.height"
        static let requestLogVisible = "panel.requestLog.visible"
        static let inspectorVisible = "panel.inspector.visible"
    }

    /// How small a panel may get, and how much room the centre pane keeps for itself.
    ///
    /// These used to be closed ranges — `120...500` and `220...400` — applied on save *and* on load.
    /// That did more than refuse an oversized drag: it forgot the size you chose. Shrink the window
    /// far enough for a panel to be clamped, and your preference was overwritten in `UserDefaults`
    /// with the clamped value, so growing the window back did not bring it back.
    ///
    /// A panel's real ceiling is not a constant anyway — it is "whatever leaves the centre pane
    /// usable", which depends on the window. So the ceiling moved to layout time (see
    /// `WorkspaceView`), the floor stayed here, and the store now records what you actually chose.
    public enum Bounds {
        /// The request log's floor. Handed to `NSSplitViewItem.minimumThickness`, so a drag stops
        /// here and a further drag collapses the pane — AppKit's behaviour, not a threshold this
        /// codebase compares against.
        public static let minimumRequestLogHeight: CGFloat = 120

        /// What the centre pane keeps no matter how far the request log is dragged. Enough for the
        /// editor's header and a few rows — it scrolls, so it does not need room for a whole form.
        ///
        /// This is the *other* item's `minimumThickness`, which is why there is no longer a
        /// `maximumRequestLogHeight` beside it: a panel's ceiling is whatever leaves this much
        /// behind, and expressing it as the neighbour's floor means the split view enforces it
        /// during the drag instead of a view recomputing it from a measured container one frame late.
        public static let minimumCentreHeight: CGFloat = 240

        /// The inspector's floor and preferred width, handed to `.inspectorColumnWidth`. They are
        /// constants rather than stored values because AppKit restores that column's width with the
        /// window — see the note on `PanelLayout`.
        public static let minimumInspectorWidth: CGFloat = 220
        public static let idealInspectorWidth: CGFloat = 280

        /// A last-resort sanity ceiling for a stored value, guarding against a hand-edited plist
        /// rather than against a normal drag. Layout does the real clamping.
        public static let storedSizeLimit: CGFloat = 4000
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func load() -> PanelLayout {
        PanelLayout(
            requestLogHeight: size(
                forKey: Key.requestLogHeight,
                default: PanelLayout.default.requestLogHeight
            ),
            isRequestLogVisible: flag(
                forKey: Key.requestLogVisible,
                default: PanelLayout.default.isRequestLogVisible
            ),
            isInspectorVisible: flag(
                forKey: Key.inspectorVisible,
                default: PanelLayout.default.isInspectorVisible
            )
        )
    }

    /// Records the arrangement as chosen.
    ///
    /// Deliberately does not clamp to a usable range. The size that is right for a panel depends on
    /// the window it is in, and this store outlives any particular window — clamping here is how the
    /// old implementation lost people's layouts when they resized. Only the sanity ceiling applies.
    public func save(_ layout: PanelLayout) {
        defaults.set(
            Double(layout.requestLogHeight.clamped(to: 0...Bounds.storedSizeLimit)),
            forKey: Key.requestLogHeight
        )
        defaults.set(layout.isRequestLogVisible, forKey: Key.requestLogVisible)
        defaults.set(layout.isInspectorVisible, forKey: Key.inspectorVisible)
    }

    // MARK: - Reading

    /// A stored size, falling back to the default when absent or nonsensical.
    ///
    /// `UserDefaults.double(forKey:)` returns 0 for a missing key, which is indistinguishable from a
    /// deliberately stored zero — hence the explicit `object(forKey:)` check.
    ///
    /// Only the sanity ceiling is applied. A size that is too large for the *current* window is not
    /// nonsense — it is a preference that a bigger window will honour again — so narrowing it is
    /// layout's job, not the store's.
    private func size(forKey key: String, default fallback: CGFloat) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let stored = CGFloat(defaults.double(forKey: key))
        guard stored.isFinite, stored > 0 else { return fallback }
        return stored.clamped(to: 0...Bounds.storedSizeLimit)
    }

    private func flag(forKey key: String, default fallback: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return fallback }
        return defaults.bool(forKey: key)
    }
}

extension CGFloat {
    func clamped(to bounds: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, bounds.lowerBound), bounds.upperBound)
    }
}
