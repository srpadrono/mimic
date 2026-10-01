import DesignSystem
import SwiftUI

/// The sizes the workspace's three resizable panels keep to.
///
/// Passed in rather than read from the app's layout store, so the skeleton renders the same way in
/// the gallery, a snapshot test, and the app.
public struct WorkspacePanelMetrics: Equatable, Sendable {
    public var minimumCentreHeight: CGFloat
    public var minimumRequestLogHeight: CGFloat
    public var defaultRequestLogHeight: CGFloat
    public var minimumInspectorWidth: CGFloat
    public var idealInspectorWidth: CGFloat

    public init(
        minimumCentreHeight: CGFloat,
        minimumRequestLogHeight: CGFloat,
        defaultRequestLogHeight: CGFloat,
        minimumInspectorWidth: CGFloat,
        idealInspectorWidth: CGFloat
    ) {
        self.minimumCentreHeight = minimumCentreHeight
        self.minimumRequestLogHeight = minimumRequestLogHeight
        self.defaultRequestLogHeight = defaultRequestLogHeight
        self.minimumInspectorWidth = minimumInspectorWidth
        self.idealInspectorWidth = idealInspectorWidth
    }
}

/// The workspace skeleton: a full-height navigator, an editor column with the request log docked
/// below it, and a full-height inspector. It owns the panel geometry and chrome and nothing about
/// what the panels hold, so each section can be dropped into it on its own.
///
/// Xcode's arrangement, and for Xcode's reason. Both side panels own their full column top to
/// bottom; the bottom panel is a tenant of the centre column only. Mimic once had the inverse: the
/// request log spanned the whole detail column, so the inspector had to stop short to make room for
/// it, which cost the panel whose job is showing a payload the height the log was not using.
public struct WorkspaceShellLayout<
    Navigator: View, JumpBar: View, Center: View, RequestLog: View, Takeover: View, Inspector: View,
    Toolbar: ToolbarContent
>: View {
    let metrics: WorkspacePanelMetrics
    @Binding var isRequestLogPresented: Bool
    @Binding var requestLogHeight: CGFloat
    /// The centre content's own height, so the request log can sit right below it.
    let preferredCenterHeight: CGFloat?
    @Binding var isInspectorPresented: Bool
    /// When set, the takeover replaces the jump bar, the editor, and the docked log.
    let showsTakeover: Bool
    let onToolbarLayoutChange: (WorkspaceToolbarLayout) -> Void
    let navigator: Navigator
    let jumpBar: JumpBar
    let center: Center
    let requestLog: RequestLog
    let takeover: Takeover
    let inspector: Inspector
    let toolbar: Toolbar

    public init(
        metrics: WorkspacePanelMetrics,
        isRequestLogPresented: Binding<Bool>,
        requestLogHeight: Binding<CGFloat>,
        preferredCenterHeight: CGFloat? = nil,
        isInspectorPresented: Binding<Bool>,
        showsTakeover: Bool = false,
        onToolbarLayoutChange: @escaping (WorkspaceToolbarLayout) -> Void = { _ in },
        @ViewBuilder navigator: () -> Navigator,
        @ViewBuilder jumpBar: () -> JumpBar,
        @ViewBuilder center: () -> Center,
        @ViewBuilder requestLog: () -> RequestLog,
        @ViewBuilder takeover: () -> Takeover,
        @ViewBuilder inspector: () -> Inspector,
        @ToolbarContentBuilder toolbar: () -> Toolbar
    ) {
        self.metrics = metrics
        self._isRequestLogPresented = isRequestLogPresented
        self._requestLogHeight = requestLogHeight
        self.preferredCenterHeight = preferredCenterHeight
        self._isInspectorPresented = isInspectorPresented
        self.showsTakeover = showsTakeover
        self.onToolbarLayoutChange = onToolbarLayoutChange
        self.navigator = navigator()
        self.jumpBar = jumpBar()
        self.center = center()
        self.requestLog = requestLog()
        self.takeover = takeover()
        self.inspector = inspector()
        self.toolbar = toolbar()
    }

    public var body: some View {
        NavigationSplitView {
            navigator
                .navigationSplitViewColumnWidth(
                    min: DSNavigatorMetrics.minimumWidth,
                    ideal: DSNavigatorMetrics.idealWidth,
                    max: DSNavigatorMetrics.maximumWidth
                )
                // `.contain` matters: a bare `.accessibilityIdentifier` on a container *overrides*
                // its descendants' identifiers, which once took `sidebar.searchField` out of the tree.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("sidebar")
        } detail: {
            detailColumn
        }
        .navigationSplitViewStyle(.balanced)
        // Outside the navigation structure, the inspector owns a full-height column and its own
        // toolbar section, which holds its header. That section is what keeps the centre column's
        // actions over the centre column.
        .inspector(isPresented: $isInspectorPresented) {
            inspector
                .inspectorColumnWidth(
                    min: metrics.minimumInspectorWidth,
                    ideal: metrics.idealInspectorWidth,
                    max: DSLayout.inspectorMaximumWidth
                )
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("inspector")
        }
    }

    private var detailColumn: some View {
        VStack(spacing: 0) {
            if showsTakeover {
                takeover
            } else {
                // Xcode's jump bar. Sits above the editor area rather than inside any one editor,
                // because it describes where you are, not what you are editing.
                jumpBar
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: DSStroke.hairline)
                    .accessibilityHidden(true)

                // The pair that shares the space below the jump bar, as one `NSSplitViewItem` pair —
                // so the divider between them is the same divider the navigator and the inspector
                // already wear, and the centre pane's floor is a constraint AppKit enforces.
                DSSplitPane(
                    axis: .vertical,
                    isSecondaryPresented: $isRequestLogPresented,
                    secondaryThickness: $requestLogHeight,
                    minimumPrimaryThickness: metrics.minimumCentreHeight,
                    minimumSecondaryThickness: metrics.minimumRequestLogHeight,
                    defaultSecondaryThickness: metrics.defaultRequestLogHeight,
                    preferredPrimaryThickness: preferredCenterHeight,
                    identifier: "requestLog"
                ) {
                    center
                        // Anchored to the top, not centred. An editor taller than its pane is
                        // centred by default, which pushes its first row out of sight under the
                        // toolbar. Clipping the bottom of a long editor is recoverable; losing the
                        // top is not.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("centerPane")
                } secondary: {
                    requestLog
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
        }
        // The one content surface: a rounded card inset from the window, under the toolbar.
        .background(DSColors.content)
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
        .padding(.top, DSSpacing.xs)
        .padding([.horizontal, .bottom], DSLayout.panelInset)
        .background(DSColors.window.ignoresSafeArea())
        .onGeometryChange(for: WorkspaceToolbarLayout.self) {
            WorkspaceToolbarLayout(centerWidth: $0.size.width)
        } action: { layout in
            // The toolbar changes its intrinsic width at each breakpoint. During a live window
            // resize, animating that change lets the Run button and its neighbours occupy the same
            // space for a frame while AppKit rearranges native items.
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { onToolbarLayoutChange(layout) }
        }
        // Editor actions belong to this column, before the inspector divides the toolbar.
        .toolbar { toolbar }
        // The toolbar sits on the window colour, as the design draws it. Left visible, AppKit
        // backs this column's title bar with its own lighter material.
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
    }
}
