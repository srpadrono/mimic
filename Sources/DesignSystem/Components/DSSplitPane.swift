import AppKit
import SwiftUI

// MARK: - DSSplitPane

/// Two panes and a divider between them, drawn and driven by AppKit.
///
/// This is `NSSplitViewController` with a SwiftUI hosting view in each pane. It exists because the
/// window's other two panels — the navigator and the inspector — are already `NSSplitViewItem`s,
/// produced by `NavigationSplitView` and `.inspector`. A third panel resized by a SwiftUI
/// `DragGesture` could not match them: it had its own hover treatment, its own double-click
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
/// What comes with the platform rather than being written here: the divider's drawing and its resize
/// cursor, minimum thickness on both sides, drag-to-collapse, double-click to restore the default,
/// which pane absorbs a window resize, and a collapse that *remembers* the thickness it collapsed
/// from.
///
/// **Environment does not cross a hosting boundary.** A hosting view starts a new SwiftUI hierarchy,
/// so anything the panes read from `@Environment` — `AppState` above all — has to be re-injected
/// inside the `primary:`/`secondary:` builders. System values AppKit itself carries (`colorScheme`
/// from `effectiveAppearance`, the accessibility settings) arrive on their own.
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
    ///     every frame of a drag, so a binding wired to a store is not written once per event.
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

    public func makeNSViewController(context: Context) -> DSSplitPaneController {
        let controller = DSSplitPaneController(
            isVertical: axis == .horizontal,
            primary: AnyView(primary),
            secondary: AnyView(secondary),
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

    public func updateNSViewController(_ controller: DSSplitPaneController, context: Context) {
        // Bindings are values captured when the closure was made, so they are re-attached on every
        // update rather than only at construction — a stale one would write into a state container
        // SwiftUI has already replaced.
        attachCallbacks(to: controller)
        controller.apply(
            primary: AnyView(primary),
            secondary: AnyView(secondary),
            isSecondaryCollapsed: !isSecondaryPresented,
            // A whole panel sliding open is the largest motion in the window. `DSEmptyState` gates a
            // 4% scale on this setting; a panel cannot be exempt from what a 4% scale respects.
            animated: !context.environment.accessibilityReduceMotion
        )
    }

    private func attachCallbacks(to controller: DSSplitPaneController) {
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
///
/// **Not generic.** It installs `DSHairlineSplitView` from `loadView`, which needs an `@objc`
/// override; the panes are erased to `AnyView` so this class can stay non-generic, which costs a
/// little diffing on two views that change rarely.
///
/// Installing a custom split view is what makes the divider grabbable at all — see
/// `DSHairlineSplitView` — and it is also what makes `splitView(_:shouldHideDividerAt:)` below
/// mandatory. Without that guard the app does not launch.
public final class DSSplitPaneController: NSSplitViewController {

    /// Called when the secondary pane settles at a new thickness — not on every event of a drag.
    var onSecondaryThicknessChange: (CGFloat) -> Void = { _ in }
    /// Called when the user collapses or reveals the secondary pane themselves.
    var onSecondaryCollapseChange: (Bool) -> Void = { _ in }

    private let primaryHost: DSPaneViewController
    private let secondaryHost: DSPaneViewController
    private let minimumPrimaryThickness: CGFloat
    private let minimumSecondaryThickness: CGFloat
    private let defaultSecondaryThickness: CGFloat
    private let restoredSecondaryThickness: CGFloat
    private let initialSecondaryCollapsed: Bool
    /// Not `identifier`: `NSViewController` already has one of those, of a different type.
    private let paneIdentifier: String
    /// Applied in `viewDidLoad`, not `init`. Touching `splitView` from an initialiser forces the view
    /// to load before the controller has a parent, running the whole item setup with nothing to lay
    /// out against.
    private let isVerticalSplit: Bool

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
        primary: AnyView,
        secondary: AnyView,
        minimumPrimaryThickness: CGFloat,
        minimumSecondaryThickness: CGFloat,
        defaultSecondaryThickness: CGFloat,
        restoredSecondaryThickness: CGFloat,
        isSecondaryCollapsed: Bool,
        paneIdentifier: String
    ) {
        self.primaryHost = DSPaneViewController(rootView: primary)
        self.secondaryHost = DSPaneViewController(rootView: secondary)
        self.minimumPrimaryThickness = minimumPrimaryThickness
        self.minimumSecondaryThickness = minimumSecondaryThickness
        self.defaultSecondaryThickness = defaultSecondaryThickness
        self.restoredSecondaryThickness = restoredSecondaryThickness
        self.initialSecondaryCollapsed = isSecondaryCollapsed
        self.paneIdentifier = paneIdentifier
        self.isVerticalSplit = isVertical
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func loadView() {
        splitView = DSHairlineSplitView()
        super.loadView()
    }

    // MARK: Setup

    public override func viewDidLoad() {
        super.viewDidLoad()

        splitView.isVertical = isVerticalSplit
        splitView.setAccessibilityIdentifier("ds.splitpane.\(paneIdentifier)")

        let primaryItem = NSSplitViewItem(viewController: primaryHost)
        primaryItem.minimumThickness = minimumPrimaryThickness
        // The pane that gives up room first when the window shrinks — it holds its size *less* firmly
        // than the secondary. What matters is the order of the two, not the numbers, and both have to
        // stay low: see `secondaryHoldingPriority`.
        primaryItem.holdingPriority = .defaultLow

        let secondaryItem = NSSplitViewItem(viewController: secondaryHost)
        secondaryItem.minimumThickness = minimumSecondaryThickness
        secondaryItem.canCollapse = true
        // Dragging a panel shut is a deliberate act; having it vanish because the window got shorter
        // is not. A window too short for both narrows this pane instead.
        secondaryItem.canCollapseFromWindowResize = false
        secondaryItem.holdingPriority = Self.secondaryHoldingPriority
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
        // a fraction rather than a size, so recomputing it as the window changes is what keeps
        // "restore the default" meaning the same number of points at any window height.
        let preferred = min(max(defaultSecondaryThickness / available, 0), 1)
        if abs(secondaryItem.preferredThicknessFraction - preferred) > 0.001 {
            secondaryItem.preferredThicknessFraction = preferred
        }

        guard !hasRestoredPosition else { return }

        // What the request becomes once both panes' floors are honoured. Asking for anything outside
        // this is silently clamped by AppKit, and a clamped no-op is indistinguishable from a divider
        // that refuses to move — which is how this was misread once already.
        let ceiling = available - minimumPrimaryThickness - splitView.dividerThickness
        let want = min(max(restoredSecondaryThickness, minimumSecondaryThickness), ceiling)
        guard want >= minimumSecondaryThickness else { return }

        // Latch on the *result*, not on the attempt. `viewDidLayout` fires several times before the
        // pane is really in a window at its real size, and an attempt made during one of those passes
        // is discarded by the pass already running — so latching on "we tried" left the panel on its
        // minimum for good. Checking what landed makes the restore self-correcting: it re-applies each
        // layout until it takes, then stops, and never fights the user's own drag.
        if abs(thickness(of: secondaryHost.view.frame) - want) < 1 {
            hasRestoredPosition = true
            return
        }

        applyExternally {
            splitView.setPosition(available - want - splitView.dividerThickness, ofDividerAt: 0)
        }
    }

    /// Guards a crash AppKit walks into on its own.
    ///
    /// Installing a custom `splitView` from `loadView` costs one extra constraint pass before any
    /// items exist, and `NSSplitViewController`'s own implementation of this delegate method reads
    /// `splitViewItems[dividerIndex]` without checking — so it throws
    /// `-[__NSArrayM objectAtIndex:]: index 0 beyond bounds for empty array` out of
    /// `_updateStackConstraints`, and `NSApplication` turns that into a launch crash with no logged
    /// reason and a backtrace naming only AppKit frames. There is no divider to hide when there are
    /// no items, so answering for that case is both correct and enough.
    public override func splitView(
        _ splitView: NSSplitView,
        shouldHideDividerAt dividerIndex: Int
    ) -> Bool {
        guard splitViewItems.count > dividerIndex + 1 else { return false }
        return super.splitView(splitView, shouldHideDividerAt: dividerIndex)
    }

    // MARK: SwiftUI → AppKit

    func apply(primary: AnyView, secondary: AnyView, isSecondaryCollapsed: Bool, animated: Bool) {
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

    /// Ten points of priority above the primary pane's, and nothing like `.defaultHigh`.
    ///
    /// AppKit expresses a divider drag as a layout constraint at
    /// `NSLayoutPriorityDragThatCannotResizeWindow` — 490 — so a pane holding its thickness *above*
    /// that outranks the user. At `.defaultHigh` (750) the pane could not be dragged, could not be
    /// moved by `setPosition`, and came up pinned to its own `minimumThickness`: three symptoms, one
    /// cause, none of them reported. Only the *order* of the two priorities decides who absorbs a
    /// window resize, so the pair sits just above `.defaultLow`, where it cannot compete with a
    /// gesture.
    static var secondaryHoldingPriority: NSLayoutConstraint.Priority {
        NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.defaultLow.rawValue + 10)
    }

    private var secondaryItem: NSSplitViewItem { splitViewItems[1] }

    private func thickness(of rect: CGRect) -> CGFloat {
        splitView.isVertical ? rect.width : rect.height
    }

    private func applyExternally(_ work: () -> Void) {
        let wasApplying = isApplyingExternalState
        isApplyingExternalState = true
        defer { isApplyingExternalState = wasApplying }
        work()
    }
}

// MARK: - Divider

/// An `NSSplitView` whose divider reads as a hairline and grabs like a real target.
///
/// The band between the panes has to be wider than the line drawn in it. AppKit's grab slop normally
/// reaches a couple of points either side of a 1pt divider and *into* the neighbouring panes, which
/// works because an ordinary pane view declines points it does not draw. A SwiftUI pane does not: a
/// hosting view claims every point in its bounds, and `NSSplitViewItem` wraps it in a view that
/// claims whatever is left. At `.thin` there is nothing of the divider left to press, and the
/// mouse-down goes to the pane instead.
///
/// The failure is quiet and convincing: the divider renders, the frames are right, the minimums are
/// enforced, `setPosition` works from code — and it will not drag. Declining the point from the
/// hosting view does not help; the item's wrapper answers instead. Only a wider band does.
///
/// So the band is 10pt — the same hit target the hand-rolled divider used, for the reason stated
/// there: a 1pt target is a fine thing to look at and a miserable thing to grab. It does not *look*
/// 10pt, because it is painted in the panel surface and closed with a hairline at the primary pane's
/// edge. The extra points read as the top of the panel below, which is what they are.
///
/// **This class must not touch Auto Layout in its initialiser**, and the controller that installs it
/// must guard `splitView(_:shouldHideDividerAt:)` — see the note there.
final class DSHairlineSplitView: NSSplitView {
    /// Wide enough to grab without hunting, and no wider than the panel padding it hides inside.
    static let bandThickness: CGFloat = 10

    override var dividerThickness: CGFloat { Self.bandThickness }

    override func drawDivider(in rect: NSRect) {
        // The band belongs to the pane after it, so it takes that pane's surface and the seam is the
        // hairline closing the pane before it. Drawn rather than left to `dividerColor`, because
        // AppKit would paint the whole band as divider and the window would grow a gutter.
        NSColor(DSColors.secondary).setFill()
        rect.fill()

        let seam = isVertical
            ? NSRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
            : NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: 1)
        NSColor(DSColors.panelSeparator).setFill()
        seam.fill()
    }
}

// MARK: - Pane hosting

/// Hosts one pane's SwiftUI content.
///
/// Deliberately not `NSHostingController`: `sizingOptions` has to be `[]` on the hosting *view* — the
/// split view decides how big a pane is, and left to itself the hosting view reports an ideal size
/// and argues with the divider about how much room it is owed — and the controller gives no way to
/// reach the view it makes.
final class DSPaneViewController: NSViewController {
    private let hostingView: NSHostingView<AnyView>

    var rootView: AnyView {
        get { hostingView.rootView }
        set { hostingView.rootView = newValue }
    }

    init(rootView: AnyView) {
        hostingView = NSHostingView(rootView: rootView)
        hostingView.sizingOptions = []
        // A hosting view still publishes an intrinsic content size and defends it at the default
        // compression resistance of 750 — above the 490 AppKit uses for a divider drag, so a pane
        // could in principle refuse to shrink. The split view is the authority on how big a pane is;
        // these priorities say so. (Belt and braces: the one-way divider this was reached for turned
        // out to be a mis-aimed grab, not a priority fight. It is still the correct setting.)
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            hostingView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            hostingView.setContentHuggingPriority(.defaultLow, for: axis)
        }
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = hostingView
    }
}
