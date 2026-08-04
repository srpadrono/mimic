import SwiftUI

/// Edge from which a drawer slides into its container.
public enum DSDrawerEdge {
    case leading, trailing, top, bottom

    var swiftUIEdge: Edge {
        switch self {
        case .leading:  .leading
        case .trailing: .trailing
        case .top:      .top
        case .bottom:   .bottom
        }
    }

    var isHorizontal: Bool {
        self == .leading || self == .trailing
    }

    /// Whether the divider sits *before* the content in reading order.
    var dividerLeads: Bool {
        self == .trailing || self == .bottom
    }
}

// MARK: - DSDrawer

/// A slide-in panel that attaches to any edge of its container.
///
/// Place `DSDrawer` inside an `HStack(spacing: 0)` (leading/trailing)
/// or `VStack(spacing: 0)` (top/bottom) alongside your main content.
/// Toggle `isPresented` with `withAnimation(DSAnimation.drawerToggle)`
/// for a consistent feel across the entire app.
///
/// Resizable drawers can be dragged to collapse — dragging below the
/// minimum snaps the drawer closed automatically.
public struct DSDrawer<Content: View>: View {
    private let edge: DSDrawerEdge
    @Binding private var isPresented: Bool
    private let identifier: String
    private let showDivider: Bool
    private let content: Content

    // Resizable support
    private let resizable: Bool
    @Binding private var size: CGFloat
    private let minSize: CGFloat
    private let maxSize: CGFloat
    private let defaultSize: CGFloat

    /// Creates a fixed-size drawer.
    public init(
        edge: DSDrawerEdge,
        isPresented: Binding<Bool>,
        identifier: String,
        showDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.edge = edge
        self._isPresented = isPresented
        self.identifier = identifier
        self.showDivider = showDivider
        self.content = content()
        self.resizable = false
        self._size = .constant(0)
        self.minSize = 0
        self.maxSize = 0
        self.defaultSize = 0
    }

    /// Creates a resizable drawer with a drag handle on the attachment edge.
    ///
    /// Dragging below `minSize` snaps the drawer closed; double-clicking the divider restores
    /// `defaultSize`.
    ///
    /// `defaultSize` is a separate parameter rather than "whatever `size` was at init" on purpose.
    /// SwiftUI re-runs `init` on every `body` evaluation, so reading the binding captured the
    /// *current* size — which made "restore the default" a no-op once the panel had been dragged, and
    /// silently did the same to the size restored after a snap-to-close.
    public init(
        edge: DSDrawerEdge,
        isPresented: Binding<Bool>,
        size: Binding<CGFloat>,
        minSize: CGFloat,
        maxSize: CGFloat,
        defaultSize: CGFloat,
        identifier: String,
        showDivider: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.edge = edge
        self._isPresented = isPresented
        self.identifier = identifier
        self.showDivider = showDivider
        self.content = content()
        self.resizable = true
        self._size = size
        self.minSize = minSize
        self.maxSize = maxSize
        self.defaultSize = defaultSize
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Where the drawer's attached edge currently sits, in global coordinates.
    @State private var dragAnchor: CGFloat = 0

    public var body: some View {
        if isPresented {
            drawerBody
                // The largest motion in the app — a whole panel sliding in with a spring bounce.
                // `DSEmptyState` gates a 4% scale on this setting; a panel transition cannot be
                // exempt from what a 4% scale respects.
                .transition(reduceMotion
                            ? .opacity
                            : .move(edge: edge.swiftUIEdge).combined(with: .opacity))
                .accessibilityIdentifier("ds.drawer.\(identifier)")
        }
    }

    @ViewBuilder
    private var drawerBody: some View {
        Group {
            if edge.isHorizontal {
                HStack(spacing: 0) { parts }
                    .frame(maxHeight: .infinity)
            } else {
                VStack(spacing: 0) { parts }
                    .frame(maxWidth: .infinity)
            }
        }
        // The divider resizes by absolute pointer position, so it needs to know where the drawer's
        // fixed edge is. Measuring it here rather than tracking it in the gesture is what keeps the
        // drag idempotent — see `DSDrawerDivider.size(forLocation:anchor:edge:maxSize:)`.
        //
        // This settles immediately instead of oscillating, because the edge being measured is the
        // one a resize does not move: dragging changes the drawer's *other* side.
        .onGeometryChange(for: CGFloat.self) { proxy in
            DSDrawerDivider.anchorValue(forFrame: proxy.frame(in: .global), edge: edge)
        } action: { dragAnchor = $0 }
    }

    @ViewBuilder
    private var parts: some View {
        if showDivider && edge.dividerLeads {
            dividerView
        }

        content
            .frame(
                maxWidth: edge.isHorizontal ? nil : .infinity,
                maxHeight: edge.isHorizontal ? .infinity : nil,
                alignment: .topLeading
            )
            .frame(
                width: resizable && edge.isHorizontal ? renderedSize : nil,
                height: resizable && !edge.isHorizontal ? renderedSize : nil,
                alignment: .topLeading
            )
            .clipped()
            .background(DSColors.secondary)

        if showDivider && !edge.dividerLeads {
            dividerView
        }
    }

    /// The size actually drawn: the chosen size, narrowed to whatever currently fits.
    ///
    /// Clamped for display only — the binding keeps the size the user chose. `maxSize` now shrinks
    /// with the window, and writing the clamped value back would mean resizing the window smaller
    /// permanently discarded the arrangement, which is exactly the bug this pair of changes fixes.
    /// Shrink the window and the panel narrows; grow it again and the preference comes back.
    private var renderedSize: CGFloat {
        min(max(size, 0), max(maxSize, 0))
    }

    @ViewBuilder
    private var dividerView: some View {
        if resizable {
            DSDrawerDivider(
                axis: edge.isHorizontal ? .horizontal : .vertical,
                size: $size,
                isPresented: $isPresented,
                minSize: minSize,
                maxSize: maxSize,
                defaultSize: defaultSize,
                edge: edge,
                anchor: dragAnchor
            )
        } else {
            Rectangle()
                .fill(DSColors.panelSeparator)
                .frame(
                    width: edge.isHorizontal ? 1 : nil,
                    height: edge.isHorizontal ? nil : 1
                )
                .accessibilityIdentifier("ds.divider.drawer.\(identifier)")
        }
    }
}

// MARK: - DSAnimation extension

extension DSAnimation {
    /// Standard animation for toggling any drawer open or closed.
    public static var drawerToggle: Animation {
        spring(slow)
    }
}

// MARK: - Resizable Divider (internal)

/// Draggable divider for resizing a drawer along its attachment edge.
/// Supports snap-to-close: dragging below `minSize` dismisses the drawer.
struct DSDrawerDivider: View {
    let axis: Axis
    @Binding var size: CGFloat
    @Binding var isPresented: Bool
    let minSize: CGFloat
    let maxSize: CGFloat
    let defaultSize: CGFloat
    let edge: DSDrawerEdge

    /// The drawer's attached edge in global coordinates — the fixed side a resize never moves.
    let anchor: CGFloat

    @State private var isHovered: Bool
    @State private var isDragging: Bool

    init(
        axis: Axis,
        size: Binding<CGFloat>,
        isPresented: Binding<Bool>,
        minSize: CGFloat,
        maxSize: CGFloat,
        defaultSize: CGFloat,
        edge: DSDrawerEdge,
        anchor: CGFloat
    ) {
        self.axis = axis
        self._size = size
        self._isPresented = isPresented
        self.minSize = minSize
        self.maxSize = maxSize
        self.defaultSize = defaultSize
        self.edge = edge
        self.anchor = anchor
        _isHovered = State(initialValue: false)
        _isDragging = State(initialValue: false)
    }

    var body: some View {
        ZStack(alignment: .center) {
            Rectangle()
                .fill(lineColor)
                .frame(
                    width: axis == .horizontal ? lineThickness : nil,
                    height: axis == .vertical ? lineThickness : nil
                )

            // A short grip that fades in under the pointer. The divider used to be a 1pt hairline
            // that only changed colour on hover, so nothing about the panel said it could be
            // resized — you had to already know. The grip is the smallest honest hint, and it stays
            // out of the way when the pointer is elsewhere.
            Capsule()
                .fill(gripColor)
                .frame(
                    width: axis == .horizontal ? 3 : 28,
                    height: axis == .horizontal ? 28 : 3
                )
                .opacity(isHovered || isDragging ? 1 : 0)
        }
        .frame(
            width: axis == .horizontal ? 1 : nil,
            height: axis == .vertical ? 1 : nil
        )
        .zIndex(10)
        .overlay {
            // The hit target is deliberately much larger than the line. A 1pt target is a fine
            // thing to look at and a miserable thing to grab.
            Color.clear
                .frame(
                    width: axis == .horizontal ? Self.hitTargetThickness : nil,
                    height: axis == .vertical ? Self.hitTargetThickness : nil
                )
                .contentShape(Rectangle())
                // `.pointerStyle`, not `NSCursor.push()`/`.pop()`. The cursor stack has no owner:
                // SwiftUI does not promise an `onHover(false)` when a view is *removed*, and this
                // divider is removed while the pointer is still on it every time a drawer snaps
                // closed or ⌥⌘L/⌥⌘I hides one. The `pop()` never ran, so the ↕ resize cursor stuck
                // over the entire window until something else pushed. This modifier is scoped to the
                // view's lifetime, so it cannot leak.
                .pointerStyle(axis == .vertical ? .rowResize : .columnResize)
                .onHover(perform: updateHoverState)
                .gesture(dragGesture)
                // Double-click restores the size the panel shipped with — the standard way out of a
                // layout you dragged into a corner, and faster than pixel-hunting back to it.
                .simultaneousGesture(TapGesture(count: 2).onEnded { resetToDefaultSize() })
                .accessibilityIdentifier("ds.drawer.divider.\(axis == .horizontal ? "vertical" : "horizontal")")
        }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .animation(.easeOut(duration: DSAnimation.micro), value: isDragging)
    }

    /// Wide enough to grab without hunting, narrow enough not to steal clicks from panel content.
    static let hitTargetThickness: CGFloat = 10

    private var gripColor: Color {
        isDragging ? DSColors.accent : DSColors.labelTertiary
    }

    func resetToDefaultSize() {
        withAnimation(DSAnimation.spring()) {
            size = defaultSize
            isPresented = true
        }
    }

    private var lineThickness: CGFloat {
        Self.lineThickness(isDragging: isDragging)
    }

    private var lineColor: Color {
        Self.lineColor(isDragging: isDragging, isHovered: isHovered)
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { updateDragState(toward: $0.location) }
            .onEnded(handleDragEnded)
    }

    func updateHoverState(_ hovering: Bool) {
        isHovered = Self.handleHover(hovering: hovering, axis: axis)
    }

    func updateDragState(toward location: CGPoint) {
        isDragging = true
        // No anchor yet means the drawer has not been measured, and a size derived from an anchor of
        // zero would collapse the panel on the first drag. Better to ignore the event than to act on
        // a position we cannot interpret; the next layout pass supplies the anchor.
        guard anchor > 0 else { return }
        size = Self.size(forLocation: location, anchor: anchor, edge: edge, maxSize: maxSize)
    }

    func handleDragEnded(_: DragGesture.Value) {
        finishDragging()
    }

    func finishDragging() {
        isDragging = false
        let result = Self.resolvedDragEnd(
            size: size,
            minSize: minSize,
            defaultSize: defaultSize
        )
        size = result.size
        if let shouldPresent = result.isPresented {
            withAnimation(DSAnimation.drawerToggle) {
                isPresented = shouldPresent
            }
        }
        if result.shouldSnapToMinimum {
            withAnimation(DSAnimation.spring()) {
                size = minSize
            }
        }
    }

    static func lineThickness(isDragging: Bool) -> CGFloat {
        isDragging ? 2.5 : 1
    }

    static func lineColor(isDragging: Bool, isHovered: Bool) -> Color {
        if isDragging { return DSColors.accent }
        if isHovered { return DSColors.accent.opacity(0.6) }
        return DSColors.panelSeparator
    }

    /// Kept as a pure predicate so the hover state stays testable; the cursor itself is now
    /// `.pointerStyle`'s business, which is why nothing here touches `NSCursor`.
    static func handleHover(hovering: Bool, axis: Axis) -> Bool {
        hovering
    }

    /// The size implied by the pointer being *at* `location` — never by how far it has travelled.
    ///
    /// This is the whole fix for a crash, so it is worth being precise about. The divider used to
    /// resize from `DragGesture.translation`, which is cumulative: `size = sizeWhenTheDragBegan +
    /// translation`. That needs an anchor (`sizeWhenTheDragBegan`) held in `@State`, and `@State`
    /// captured during a gesture is not safe to depend on — writing it re-runs layout, layout can
    /// re-deliver the gesture, and a re-delivery re-captures the anchor from a size the same drag
    /// had already moved. The delta then applies twice, and again, and the panel's height walks away
    /// under a `maxSize` that clamps it back. Each round trip dirties the window's constraints, and
    /// AppKit aborts a window that needs more constraint passes than it has views —
    /// `NSInternalInconsistencyException` out of `_postWindowNeedsUpdateConstraints`, which is a
    /// `SIGABRT` while you are still holding the mouse down.
    ///
    /// Reading the pointer's absolute position removes the anchor and with it the accumulation:
    /// handling the same event twice yields the same size, so the loop has nothing to feed on. This
    /// is the pattern Apple's own guidance gives for a layout-affecting drag — `.location` in a
    /// known coordinate space, not `.translation`.
    ///
    /// `anchor` is the drawer's *attached* edge in global coordinates, which is the one edge a
    /// resize cannot move: a bottom drawer grows upward from the window's bottom, a trailing drawer
    /// leftward from its right. That is what makes a global pointer position mean a size at all.
    static func size(
        forLocation location: CGPoint,
        anchor: CGFloat,
        edge: DSDrawerEdge,
        maxSize: CGFloat
    ) -> CGFloat {
        let proposed: CGFloat = switch edge {
        case .bottom: anchor - location.y
        case .top: location.y - anchor
        case .trailing: anchor - location.x
        case .leading: location.x - anchor
        }
        return min(max(proposed, 0), max(maxSize, 0))
    }

    /// The drawer edge that a resize leaves in place, in global coordinates.
    static func anchorValue(forFrame frame: CGRect, edge: DSDrawerEdge) -> CGFloat {
        switch edge {
        case .bottom: frame.maxY
        case .top: frame.minY
        case .trailing: frame.maxX
        case .leading: frame.minX
        }
    }

    static func dragEndState(
        size: CGFloat,
        minSize: CGFloat,
        defaultSize: CGFloat,
        snapCloseThreshold: CGFloat
    ) -> (size: CGFloat, isPresented: Bool?, shouldSnapToMinimum: Bool) {
        if size < snapCloseThreshold {
            return (size: defaultSize, isPresented: false, shouldSnapToMinimum: false)
        }
        if size < minSize {
            return (size: size, isPresented: nil, shouldSnapToMinimum: true)
        }
        return (size: size, isPresented: nil, shouldSnapToMinimum: false)
    }

    static func resolvedDragEnd(
        size: CGFloat,
        minSize: CGFloat,
        defaultSize: CGFloat
    ) -> (size: CGFloat, isPresented: Bool?, shouldSnapToMinimum: Bool) {
        dragEndState(
            size: size,
            minSize: minSize,
            defaultSize: defaultSize,
            snapCloseThreshold: minSize * 0.6
        )
    }
}
