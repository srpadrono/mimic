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
        ///
        /// **260, not 220, and the number is measured.** The inspector's three-mode rail sets
        /// Request · Scenarios · Overview at 12pt semibold with 9pt padding each side; read back from
        /// AppKit those are 66.4, 76.4 and 73.0pt, which with the active-mode dot, the inter-item
        /// gaps and `DSPanelHeader`'s 24pt of insets totals **256.7pt**. At 220 the rail overflowed on
        /// the first inward drag — and an over-committed `HStack` in this window does not truncate,
        /// it pushes its *leading* edge out of view, which is the "narios instead of Scenarios" bug
        /// `DSPanelHeader` documents. 260 clears it with three points to spare.
        ///
        /// Raising a floor is safe here precisely *because* this is not a stored value: AppKit
        /// restores the column width and the split view clamps it against this minimum, so an
        /// existing install that had dragged to 230 comes back at 260 rather than being stranded.
        /// The request log's height is stored, and that one is clamped on read below.
        ///
        /// Ideal moves 280 → 320 to match the redesign's default.
        public static let minimumInspectorWidth: CGFloat = 260
        public static let idealInspectorWidth: CGFloat = 320

        /// The navigator's preferred width, handed to `.navigationSplitViewColumnWidth`.
        ///
        /// 300, down from the previous 391. The width policy in `docs/redesign/decisions.md` derives
        /// the trailing slot's 80pt cap from this number: at 300, after 16pt of insets, a 44pt badge
        /// and a 9pt gap, the path column gets 143pt — enough for `/api/v1/orders/{id}` at 147pt to
        /// truncate by a character rather than by half. Moving this moves that cap.
        public static let idealNavigatorWidth: CGFloat = 300

        /// The narrowest the window's content may get, handed to `WorkspaceView`'s `minWidth` and
        /// enforced by `.windowResizability(.contentMinSize)`.
        ///
        /// Two independent constraints converge near this number, both from measured advances rather
        /// than estimates:
        ///
        /// - The request log's header carries **394.3pt** of incompressible controls — title, count,
        ///   method popup, unmatched toggle, Clear, dividers and insets — plus a filter field with a
        ///   160pt floor. That saturates the centre pane at a 1174pt window.
        /// - The log's row carries **380pt** of fixed columns once Latency is cut, and Path needs a
        ///   180pt minimum to show `/api/v1/orders/{id}` (146.8pt at 12.5pt SF Mono). With the
        ///   navigator at 300 and the inspector at its 260 floor, that needs 1120.
        ///
        /// 1140 clears both. Below it the Path column collapses and, because the row is an `HStack`,
        /// the method badges leave the window before anything visibly runs out of room.
        public static let minimumWindowContentWidth: CGFloat = 1140

        /// Toolbar, one panel header, the centre pane's floor and the request log's floor, plus the
        /// dividers between them. Enough that the window can never be dragged to a state where the
        /// log is present but has no rows in it.
        public static let minimumWindowContentHeight: CGFloat = 600

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
                default: PanelLayout.default.requestLogHeight,
                floor: Bounds.minimumRequestLogHeight
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
    /// Only the sanity ceiling and the floor are applied. A size that is too *large* for the current
    /// window is not nonsense — it is a preference that a bigger window will honour again — so
    /// narrowing it is layout's job, not the store's.
    ///
    /// A size below the floor is different, and this is the case a raised floor creates. The request
    /// log's minimum went up with the redesign; without the clamp, an install that had dragged the
    /// log to 100pt would restore a value the split view no longer permits, and AppKit resolves that
    /// by snapping on the first interaction — so the panel appears to jump for no reason the user
    /// caused. Clamping on read means the stored preference is honoured where it can be and quietly
    /// corrected where it cannot.
    private func size(forKey key: String, default fallback: CGFloat, floor: CGFloat = 0) -> CGFloat {
        guard defaults.object(forKey: key) != nil else { return fallback }
        let stored = CGFloat(defaults.double(forKey: key))
        guard stored.isFinite, stored > 0 else { return fallback }
        return stored.clamped(to: floor...Bounds.storedSizeLimit)
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
