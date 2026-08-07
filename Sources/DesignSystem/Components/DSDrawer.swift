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

/// A fixed-size panel that attaches to any edge of its container.
///
/// Place `DSDrawer` inside an `HStack(spacing: 0)` (leading/trailing)
/// or `VStack(spacing: 0)` (top/bottom) alongside your main content.
/// Toggle `isPresented` with `withAnimation(DSAnimation.drawerToggle)`
/// for a consistent feel across the entire app.
///
/// **This component does not resize.** It used to, through a `DragGesture` on its divider, and that
/// is now `DSSplitPane` — an `NSSplitViewController` pair. The reason is in that file: a drag that
/// writes a binding feeding a `.frame(height:)` is a control loop SwiftUI gives no ordering
/// guarantees about, and the window's other two panels were already `NSSplitViewItem`s, so a third
/// mechanism could only ever disagree with them. Anything a user drags belongs in `DSSplitPane`.
public struct DSDrawer<Content: View>: View {
    private let edge: DSDrawerEdge
    @Binding private var isPresented: Bool
    private let identifier: String
    private let showDivider: Bool
    private let content: Content

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
    }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        if edge.isHorizontal {
            HStack(spacing: 0) { parts }
                .frame(maxHeight: .infinity)
        } else {
            VStack(spacing: 0) { parts }
                .frame(maxWidth: .infinity)
        }
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
            .clipped()
            .background(DSColors.surfaceContent)

        if showDivider && !edge.dividerLeads {
            dividerView
        }
    }

    private var dividerView: some View {
        Rectangle()
            .fill(DSColors.panelSeparator)
            .frame(
                width: edge.isHorizontal ? 1 : nil,
                height: edge.isHorizontal ? nil : 1
            )
            .accessibilityIdentifier("ds.divider.drawer.\(identifier)")
    }
}

// MARK: - DSAnimation extension

extension DSAnimation {
    /// Standard animation for toggling any drawer open or closed.
    public static var drawerToggle: Animation {
        spring(slow)
    }
}
