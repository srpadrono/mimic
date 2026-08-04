import AppKit
import SwiftUI

// MARK: - DSSplitPane

/// Two panes and a divider between them, drawn and driven by AppKit.
///
/// This is `NSSplitViewController` with an `NSHostingController` in each pane. It exists because the
/// window's other two panels — the navigator and the inspector — are already `NSSplitViewItem`s,
/// produced by `NavigationSplitView` and `.inspector` respectively. A third panel resized by a
/// SwiftUI `DragGesture` could not match them: it had its own hover treatment, its own double-click
/// behaviour, its own idea of what happens when you drag a panel shut, and its own persistence. Three
/// dividers in one window answered the pointer three different ways, and none of that was a decision.
///
/// It is also the only shape of this that is stable. A drag that writes a `@Binding<CGFloat>` feeding
/// a `.frame(height:)` is a control loop — gesture writes state, state changes layout, layout
/// re-measures the anchor the gesture reads — and SwiftUI promises no ordering between those steps.
/// The version this replaces crashed inside that loop (`NSInternalInconsistencyException` out of
/// `_postWindowNeedsUpdateConstraints`, while the mouse was still down) and was rewritten to use the
/// pointer's absolute position so that handling the same event twice yielded the same size. That made
/// the loop idempotent; it did not remove it. `NSSplitView` has no loop to remove: the divider drag
/// never round-trips through SwiftUI state at all.
///
/// What comes with the platform, rather than being written here: the divider's drawing, its hit
/// target and its resize cursor; minimum and maximum thickness; drag-to-collapse; double-click to
/// restore the default; which pane absorbs a window resize; and a collapse that *remembers* the
/// thickness it collapsed from.
///
/// **Environment does not cross a hosting boundary.** `NSHostingController` starts a new SwiftUI
/// hierarchy, so anything the panes read from `@Environment` — `AppState` above all — has to be
/// re-injected inside the `primary:`/`secondary:` builders. System values that AppKit itself carries
/// (`colorScheme` from `effectiveAppearance`, the accessibility settings) arrive on their own.
public struct DSSplitPane<Primary: View, Secondary: View>: NSViewControllerRepresentable {

    /// The axis the panes are laid out along, read the way `VStack`/`HStack` read: `.vertical` stacks
    /// the secondary *below* the primary behind a horizontal divider.
    private let axis: Axis
    @Binding private var isSecondaryPresented: Bool
    @Binding private var secondaryThickness: CGFloat
    private let minimumPrimaryThickness: CGFloat
    private let minimumSecondaryThickness: CGFloat
    private let defaultSecondaryThickness: CGFloat
    private let identifier: String
    private let primary: Primary
    private let secondary: Secondary

    /// - Parameters:
    ///   - axis: `.vertical` stacks the panes; `.horizontal` sets them side by side.
    ///   - isSecondaryPresented: Two-way. AppKit writes back when the user drags the pane shut.
    ///   - secondaryThickness: Two-way, and *coalesced* — AppKit reports a settled size rather than
    ///     every frame of a drag, so a binding wired to a store does not write once per event.
    ///   - defaultSecondaryThickness: What double-clicking the divider restores.
    public init(
        axis: Axis,
        isSecondaryPresented: Binding<Bool>,
        secondaryThickness: Binding<CGFloat>,
        minimumPrimaryThickness: CGFloat,
        minimumSecondaryThickness: CGFloat,
        defaultSecondaryThickness: CGFloat,
        identifier: String,
        @ViewBuilder primary: () -> Primary,
        @ViewBuilder secondary: () -> Secondary
    ) {
        self.axis = axis
        self._isSecondaryPresented = isSecondaryPresented
        self._secondaryThickness = secondaryThickness
        self.minimumPrimaryThickness = minimumPrimaryThickness
        self.minimumSecondaryThickness = minimumSecondaryThickness
        self.defaultSecondaryThickness = defaultSecondaryThickness
        self.identifier = identifier
        self.primary = primary()
        self.secondary = secondary()
    }

    public func makeNSViewController(context: Context) -> DSSplitPaneController<Primary, Secondary> {
        let controller = DSSplitPaneController(
            isVertical: axis == .horizontal,
            primary: primary,
            secondary: secondary,
            minimumPrimaryThickness: minimumPrimaryThickness,
            minimumSecondaryThickness: minimumSecondaryThickness,
            defaultSecondaryThickness: defaultSecondaryThickness,
            restoredSecondaryThickness: secondaryThickness,
            isSecondaryCollapsed: !isSecondaryPresented,
            paneIdentifier: identifier
        )
        attachCallbacks(to: controller)
        return controller
    }

    public func updateNSViewController(
        _ controller: DSSplitPaneController<Primary, Secondary>,
        context: Context
    ) {
        // Bindings are values captured at the time the closure was made, so they are re-attached on
        // every update rather than only at construction — a stale one would write into a state
        // container SwiftUI has already replaced.
        attachCallbacks(to: controller)
        controller.apply(
            primary: primary,
            secondary: secondary,
            isSecondaryCollapsed: !isSecondaryPresented,
            // A whole panel sliding open is the largest motion in the window. `DSEmptyState` gates a
            // 4% scale on this setting; a panel cannot be exempt from what a 4% scale respects.
            animated: !context.environment.accessibilityReduceMotion
        )
    }

    private func attachCallbacks(to controller: DSSplitPaneController<Primary, Secondary>) {
        controller.onSecondaryThicknessChange = { thickness in
            guard secondaryThickness != thickness else { return }
            secondaryThickness = thickness
        }
        controller.onSecondaryCollapseChange = { isCollapsed in
            guard isSecondaryPresented == isCollapsed else { return }
            isSecondaryPresented = !isCollapsed
        }
    }
}

// MARK: - DSSplitPaneController

/// The `NSSplitViewController` behind `DSSplitPane`. Public only because it is the representable's
/// `NSViewControllerType`; nothing outside the design system should need to name it.
public final class DSSplitPaneController<Primary: View, Secondary: View>: NSSplitViewController {

    /// Called when the secondary pane settles at a new thickness — not on every event of a drag.
    var onSecondaryThicknessChange: (CGFloat) -> Void = { _ in }
    /// Called when the user collapses or reveals the secondary pane themselves.
    var onSecondaryCollapseChange: (Bool) -> Void = { _ in }

    private let primaryHost: NSHostingController<Primary>
    private let secondaryHost: NSHostingController<Secondary>
    private let minimumPrimaryThickness: CGFloat
    private let minimumSecondaryThickness: CGFloat
    private let defaultSecondaryThickness: CGFloat
    private let restoredSecondaryThickness: CGFloat
    private let initialSecondaryCollapsed: Bool
    /// Not `identifier`: `NSViewController` already has one of those, of a different type.
    private let paneIdentifier: String

    /// Set while SwiftUI's own update is being applied. AppKit answers a programmatic change with the
    /// same delegate callbacks a user drag produces, and writing a binding from inside SwiftUI's
    /// update pass is the "Modifying state during view update" fault — so those echoes are dropped.
    private var isApplyingExternalState = false
    private var hasRestoredPosition = false
    /// Coalesces a drag's stream of resize callbacks into one report. The previous implementation
    /// wrote four `UserDefaults` keys per event, which at 120Hz is roughly 480 synchronous writes a
    /// second on the main thread, inside the gesture that was also driving layout.
    private var thicknessReportTask: Task<Void, Never>?

    init(
        isVertical: Bool,
        primary: Primary,
        secondary: Secondary,
        minimumPrimaryThickness: CGFloat,
        minimumSecondaryThickness: CGFloat,
        defaultSecondaryThickness: CGFloat,
        restoredSecondaryThickness: CGFloat,
        isSecondaryCollapsed: Bool,
        paneIdentifier: String
    ) {
        self.primaryHost = NSHostingController(rootView: primary)
        self.secondaryHost = NSHostingController(rootView: secondary)
        self.minimumPrimaryThickness = minimumPrimaryThickness
        self.minimumSecondaryThickness = minimumSecondaryThickness
        self.defaultSecondaryThickness = defaultSecondaryThickness
        self.restoredSecondaryThickness = restoredSecondaryThickness
        self.initialSecondaryCollapsed = isSecondaryCollapsed
        self.paneIdentifier = paneIdentifier
        super.init(nibName: nil, bundle: nil)
        splitView.isVertical = isVertical
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Setup

    public override func viewDidLoad() {
        super.viewDidLoad()

        // A hosting controller sizes itself from its content by default, which in a split pane means
        // a SwiftUI view arguing with the divider about how much room it is owed. The split view is
        // the authority here.
        primaryHost.sizingOptions = []
        secondaryHost.sizingOptions = []

        splitView.dividerStyle = .thin
        splitView.setAccessibilityIdentifier("ds.splitpane.\(paneIdentifier)")

        let primaryItem = NSSplitViewItem(viewController: primaryHost)
        primaryItem.minimumThickness = minimumPrimaryThickness
        // The pane that gives up room first when the window shrinks. Pairing this with a high hold on
        // the secondary is what makes "the log keeps its height, the editor absorbs the resize" a
        // property of the layout rather than a clamp recomputed against a measured container.
        primaryItem.holdingPriority = .defaultLow

        let secondaryItem = NSSplitViewItem(viewController: secondaryHost)
        secondaryItem.minimumThickness = minimumSecondaryThickness
        secondaryItem.canCollapse = true
        // Dragging a panel shut is a deliberate act; having it vanish because the window got shorter
        // is not. The window shrinking past the point where both fit narrows this pane instead.
        secondaryItem.canCollapseFromWindowResize = false
        secondaryItem.holdingPriority = .defaultHigh
        secondaryItem.isCollapsed = initialSecondaryCollapsed
        secondaryItem.collapseBehavior = .preferResizingSiblingsWithFixedSplitView

        addSplitViewItem(primaryItem)
        addSplitViewItem(secondaryItem)
    }

    public override func viewDidLayout() {
        super.viewDidLayout()

        let available = thickness(of: splitView.bounds)
        guard available > 0 else { return }

        // `preferredThicknessFraction` is what AppKit consults when a divider is double-clicked. It is
        // a fraction rather than a size, so it is recomputed as the window changes — which is what
        // keeps "restore the default" meaning the same number of points at any window height.
        let preferred = min(max(defaultSecondaryThickness / available, 0), 1)
        if abs(secondaryItem.preferredThicknessFraction - preferred) > 0.001 {
            secondaryItem.preferredThicknessFraction = preferred
        }

        guard !hasRestoredPosition else { return }
        hasRestoredPosition = true
        applyExternally {
            setSecondaryThickness(restoredSecondaryThickness, available: available)
        }
    }

    // MARK: SwiftUI → AppKit

    func apply(primary: Primary, secondary: Secondary, isSecondaryCollapsed: Bool, animated: Bool) {
        applyExternally {
            primaryHost.rootView = primary
            secondaryHost.rootView = secondary

            guard secondaryItem.isCollapsed != isSecondaryCollapsed else { return }
            if animated {
                secondaryItem.animator().isCollapsed = isSecondaryCollapsed
            } else {
                secondaryItem.isCollapsed = isSecondaryCollapsed
            }
        }
    }

    // MARK: AppKit → SwiftUI

    public override func splitViewDidResizeSubviews(_ notification: Notification) {
        super.splitViewDidResizeSubviews(notification)
        guard !isApplyingExternalState else { return }

        let isCollapsed = secondaryItem.isCollapsed
        onSecondaryCollapseChange(isCollapsed)

        // A collapsed pane measures zero, and reporting that would overwrite the thickness the user
        // chose with the fact that they hid it — the exact way the old drawer forgot your size every
        // time you dragged it shut.
        guard !isCollapsed else { return }
        let settled = thickness(of: secondaryHost.view.frame)
        guard settled > 0 else { return }

        thicknessReportTask?.cancel()
        thicknessReportTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled, let self else { return }
            self.onSecondaryThicknessChange(settled)
        }
    }

    // MARK: Geometry

    private var secondaryItem: NSSplitViewItem { splitViewItems[1] }

    private func thickness(of rect: CGRect) -> CGFloat {
        splitView.isVertical ? rect.width : rect.height
    }

    /// Places the divider so the secondary pane measures `thickness`. AppKit clamps the result
    /// against both items' minimums, so an oversized restored value narrows to fit rather than
    /// squeezing the primary pane out — and the stored preference is left alone for the next window
    /// that *is* tall enough.
    private func setSecondaryThickness(_ thickness: CGFloat, available: CGFloat) {
        splitView.setPosition(available - thickness, ofDividerAt: 0)
    }

    private func applyExternally(_ work: () -> Void) {
        let wasApplying = isApplyingExternalState
        isApplyingExternalState = true
        defer { isApplyingExternalState = wasApplying }
        work()
    }
}
