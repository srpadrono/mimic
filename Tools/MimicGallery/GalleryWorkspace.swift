import AppKit
import DesignSystem
import Domain
import EndpointsFeature
import FeatureSupport
import JourneysFeature
import MimicFixtures
import RequestLogFeature
import ServerFeature
import SwiftUI
import WorkspaceShell

/// The endpoint editor window assembled from its sections, the way the app assembles it, with the
/// design fixtures in place of a session. Each slot is the same view its own gallery entry shows.
struct GalleryWorkspaceWindow: View {
    /// Whether this is the real shell with its toolbar installed, in its own window. On the gallery
    /// canvas the toolbar items would land in the gallery's own toolbar, and an offscreen render
    /// draws the split view's glass blank, so the canvas draws `GalleryWindowCanvas` instead.
    let showsToolbar: Bool
    /// The toolbar state this window draws; the layout follows the window's width.
    let toolbarState: GalleryToolbarFixture
    @State private var isRequestLogPresented = true
    @State private var requestLogHeight: CGFloat = 319
    @State private var isInspectorPresented = true
    @State private var toolbarLayout: WorkspaceToolbarLayout = .expanded

    init(showsToolbar: Bool = false, toolbar: GalleryToolbarFixture = .running) {
        self.showsToolbar = showsToolbar
        self.toolbarState = toolbar
    }

    var body: some View {
        if showsToolbar {
            shell
        } else {
            GalleryWindowCanvas(tab: .endpoints, toolbar: toolbarState) {
                WorkspaceDetailColumn(
                    metrics: Self.metrics,
                    isRequestLogPresented: $isRequestLogPresented,
                    requestLogHeight: $requestLogHeight,
                    jumpBar: { Self.jumpBar },
                    center: { Self.editor },
                    requestLog: { Self.requestLog(showsDetail: false) },
                    takeover: { EmptyView() }
                )
            } inspector: {
                GalleryEndpointInspectorPanel()
            }
        }
    }

    /// The real shell, in its own window, where the split view's glass and the toolbar draw.
    private var shell: some View {
        WorkspaceShellLayout(
            metrics: Self.metrics,
            isRequestLogPresented: $isRequestLogPresented,
            requestLogHeight: $requestLogHeight,
            isInspectorPresented: $isInspectorPresented,
            onToolbarLayoutChange: { toolbarLayout = $0 },
            navigator: { GalleryNavigator() },
            jumpBar: { Self.jumpBar },
            center: { Self.editor },
            requestLog: { Self.requestLog(showsDetail: false) },
            takeover: { EmptyView() },
            inspector: {
                Self.inspector
                    .toolbar {
                        if showsToolbar {
                            GalleryInspectorHeader(title: "Scenarios", toolbar: toolbarFixture.state,
                                                   action: AnyView(Self.addScenarioButton))
                        }
                    }
            },
            toolbar: {
                if showsToolbar { toolbarFixture.toolbar }
            }
        )
    }

    /// The window's toolbar state, at whatever width the window gives the centre column.
    private var toolbarFixture: GalleryToolbarFixture {
        var fixture = toolbarState
        fixture.layout = toolbarLayout
        fixture.isInspectorPresented = isInspectorPresented
        return fixture
    }

    /// The app's panel sizes, written out: the gallery has no layout store.
    static let metrics = WorkspacePanelMetrics(
        minimumCentreHeight: 200,
        minimumRequestLogHeight: 120,
        defaultRequestLogHeight: 319,
        minimumInspectorWidth: 260,
        idealInspectorWidth: 300
    )

    static let crumbs: [BreadcrumbJumpBar.Crumb] = [
        .init(id: "group", title: "Catalog", systemImage: "folder",
              options: [.init(title: "Catalog", isSelected: true), .init(title: "Account"), .init(title: "Payments")]),
        .init(id: "endpoint", title: "GET /products",
              options: DesignFixtures.endpoints.prefix(4).map {
                  .init(id: $0.id, title: "\($0.method.rawValue) \($0.path)", isSelected: $0.id == DesignFixtures.products.id)
              }),
        .init(id: "scenario", title: DesignFixtures.editedScenario.name,
              options: DesignFixtures.products.scenarios.map {
                  .init(id: $0.id, title: $0.name, isSelected: $0.id == DesignFixtures.editedScenario.id)
              }),
    ]

    @MainActor
    static var jumpBar: some View {
        BreadcrumbJumpBar(
            crumbs: crumbs,
            autosaveStatus: .saved,
            history: BreadcrumbJumpBar.History(canGoBack: true, canGoForward: false, onBack: {}, onForward: {}),
            onSelectOption: { _, _ in }
        )
    }

    @MainActor
    static var editor: some View {
        let configuration = DesignFixtures.serverConfiguration
        return EndpointEditorView(
            endpoint: DesignFixtures.products,
            activeScenario: DesignFixtures.editedScenario,
            globalDelayMs: configuration.globalDelayMs,
            backends: configuration.listeners,
            baseAddress: "localhost:\(DesignFixtures.port)",
            actions: EndpointEditorActions(
                onDuplicate: {},
                onDelete: {},
                onUpdateScenario: { _, _, _ in },
                onUpdateDelay: { _ in },
                onUpdateGroupTag: { _ in }
            )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DSColors.content)
    }

    /// The scenario inspector as the Main artboard draws it: two ports, so Port is a live menu, and
    /// fifteen minutes of traffic ending at the fixtures' moment.
    @MainActor
    static var inspector: some View {
        let endpoint = DesignFixtures.products
        let configuration = DesignFixtures.serverSettingsConfiguration
        return EndpointInspectorContent(
            endpoint: endpoint,
            traffic: EndpointTrafficQuery.logs(forEndpoint: endpoint.id, in: DesignFixtures.productsTraffic),
            settings: EndpointInspectorSettings.Context(
                editedScenarioID: DesignFixtures.editedScenario.id,
                onEditScenario: { _, _ in },
                globalDelayMs: configuration.globalDelayMs,
                backends: configuration.listeners,
                groups: ["Account", "Catalog", "Payments"],
                onUpdateGroupTag: { _, _ in },
                onUpdateBackend: { _, _ in }
            ),
            onSetActiveScenario: { _, _ in },
            onDuplicateScenario: { _, _ in },
            onDeleteScenario: { _, _ in },
            onRenameScenario: { _, _, _ in },
            now: DesignFixtures.now
        )
    }

    /// The header's add button, as the window's inspector title bar draws it.
    @MainActor
    static var addScenarioButton: some View {
        DSPanelHeaderButton(systemImage: "plus", help: "Add scenario", identifier: "gallery.addScenario") {}
    }

    /// The log as the Main board docks it, or, with `showsDetail`, as the RequestDetail board
    /// opens it: Unmatched on and the unmatched `/recommendations` call selected. In a 24-hour
    /// locale, as both boards print their times.
    @MainActor
    static func requestLog(showsDetail: Bool) -> some View {
        RequestLogDrawerView(
            requestLogs: DesignFixtures.requestLogHistory,
            endpoints: DesignFixtures.requestLogEndpoints,
            serverState: .running(port: DesignFixtures.port),
            onClear: {},
            selectedLogIDs: .constant(showsDetail ? [DesignFixtures.requestLogDetailID] : []),
            unmatchedOnly: .constant(showsDetail),
            onCreateEndpoint: { _, _ in },
            journeys: DesignFixtures.journeys,
            showsDetail: showsDetail
        )
        .environment(\.locale, Locale(identifier: "en_GB"))
        .background(DSColors.content)
    }
}

/// The journey editor window, as the Journeys artboard draws it: the journey navigator, Payment
/// retry three steps into its run, and step 3 in the inspector. The request log is closed, as there.
struct GalleryJourneysWindow: View {
    /// Whether this is the real shell in its own window; see `GalleryWorkspaceWindow.showsToolbar`.
    let showsToolbar: Bool
    @State private var isRequestLogPresented = false
    @State private var requestLogHeight: CGFloat = 319
    @State private var isInspectorPresented = true
    @State private var toolbarLayout: WorkspaceToolbarLayout = .expanded

    init(showsToolbar: Bool = false) {
        self.showsToolbar = showsToolbar
    }

    var body: some View {
        if showsToolbar {
            shell
        } else {
            GalleryWindowCanvas(tab: .journeys, toolbar: .running) {
                WorkspaceDetailColumn(
                    metrics: GalleryWorkspaceWindow.metrics,
                    isRequestLogPresented: $isRequestLogPresented,
                    requestLogHeight: $requestLogHeight,
                    jumpBar: { Self.jumpBar },
                    center: { Self.editor },
                    requestLog: { GalleryWorkspaceWindow.requestLog(showsDetail: false) },
                    takeover: { EmptyView() }
                )
            } inspector: {
                GalleryJourneyInspectorPanel()
            }
        }
    }

    /// The real shell, in its own window, where the split view's glass and the toolbar draw.
    private var shell: some View {
        WorkspaceShellLayout(
            metrics: GalleryWorkspaceWindow.metrics,
            isRequestLogPresented: $isRequestLogPresented,
            requestLogHeight: $requestLogHeight,
            isInspectorPresented: $isInspectorPresented,
            onToolbarLayoutChange: { toolbarLayout = $0 },
            navigator: { GalleryNavigator(tab: .journeys) },
            jumpBar: { Self.jumpBar },
            center: { Self.editor },
            requestLog: { GalleryWorkspaceWindow.requestLog(showsDetail: false) },
            takeover: { EmptyView() },
            inspector: {
                Self.inspector
                    .toolbar {
                        if showsToolbar {
                            GalleryInspectorHeader(title: Self.inspectorContext.title, toolbar: toolbarFixture.state,
                                                   action: AnyView(Self.stepActions))
                        }
                    }
            },
            toolbar: {
                if showsToolbar { toolbarFixture.toolbar }
            }
        )
    }

    private var toolbarFixture: GalleryToolbarFixture {
        var fixture = GalleryToolbarFixture.running
        fixture.layout = toolbarLayout
        fixture.isInspectorPresented = isInspectorPresented
        return fixture
    }

    /// "Checkout › Payment retry", built the way the window builds a journey's crumbs.
    static var crumbs: [BreadcrumbJumpBar.Crumb] {
        let journeys = DesignFixtures.journeys
        let groups = Set(journeys.compactMap(\.groupTag)).sorted()
        return [
            .init(id: "journeyGroup", title: "Checkout",
                  options: groups.compactMap { name in
                      journeys.first { $0.groupTag == name }.map {
                          BreadcrumbJumpBar.Option(id: $0.id, title: name, isSelected: name == "Checkout")
                      }
                  }),
            .init(id: "journey", title: DesignFixtures.paymentRetry.name,
                  options: journeys.map {
                      .init(id: $0.id, title: $0.name, isSelected: $0.id == DesignFixtures.paymentRetry.id)
                  }),
        ]
    }

    @MainActor
    static var jumpBar: some View {
        BreadcrumbJumpBar(
            crumbs: crumbs,
            autosaveStatus: .saved,
            history: BreadcrumbJumpBar.History(canGoBack: true, canGoForward: false, onBack: {}, onForward: {}),
            onSelectOption: { _, _ in }
        )
    }

    @MainActor
    static var editor: some View {
        JourneyEditorView(
            model: GalleryModels.journeys,
            journey: DesignFixtures.paymentRetry,
            isActive: true,
            status: DesignFixtures.paymentRetryStatus
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(DSColors.content)
    }

    /// Step 3 selected, as the inspector artboard shows it.
    static var inspectorContext: JourneyInspector.Context {
        let status = DesignFixtures.paymentRetryStatus
        return JourneyInspector.Context(
            selected: DesignFixtures.paymentRetry,
            active: DesignFixtures.paymentRetry,
            progress: status.currentStepIndex.map { "Step \($0 + 1) of \(status.totalSteps)" },
            serverState: .running(port: DesignFixtures.port),
            selectedStepID: DesignFixtures.paymentRetry.steps[2].id
        )
    }

    @MainActor
    static var inspector: some View {
        JourneyInspector(model: GalleryModels.journeys, context: inspectorContext)
    }

    @MainActor
    static var stepActions: some View {
        JourneyStepActionsMenu(model: GalleryModels.journeys, context: inspectorContext)
    }
}

/// The inspector panel off the window, for the canvas and the fidelity report: the header the
/// window's toolbar draws above it, laid out as a strip, over the panel's glass. "Open in a window"
/// on the journeys window shows the real header.
struct GalleryJourneyInspectorPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            // The request log is closed on the Journeys board, so its toggle offers to show it.
            GalleryInspectorPanelHeader(title: GalleryJourneysWindow.inspectorContext.title,
                                        isRequestLogShown: false) {
                GalleryJourneysWindow.stepActions
            }
            GalleryJourneysWindow.inspector
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .galleryGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The scenario inspector off the window, for the canvas and the fidelity report: the header the
/// window's toolbar draws above it, laid out as a strip, over the panel's glass.
struct GalleryEndpointInspectorPanel: View {
    var body: some View {
        VStack(spacing: 0) {
            GalleryInspectorPanelHeader(title: "Scenarios", isRequestLogShown: true) {
                GalleryWorkspaceWindow.addScenarioButton
            }
            GalleryWorkspaceWindow.inspector
                .frame(maxHeight: .infinity, alignment: .top)
        }
        .galleryGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// The inspector header as a strip, as the Main and Journeys boards draw it: the mode's title, its
/// own action, and the window's panel toggles in one glass capsule. In a window, the inspector's
/// toolbar section draws the same items (`GalleryInspectorHeader`).
private struct GalleryInspectorPanelHeader<Action: View>: View {
    let title: String
    let isRequestLogShown: Bool
    let action: Action

    init(title: String, isRequestLogShown: Bool, @ViewBuilder action: () -> Action) {
        self.title = title
        self.isRequestLogShown = isRequestLogShown
        self.action = action()
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text(title)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
            Spacer(minLength: DSSpacing.sm)
            action
            HStack(spacing: 0) {
                WorkspaceRequestLogToggle(isShown: isRequestLogShown, action: {})
                    .frame(width: Self.toggleWidth, height: Self.toggleHeight)
                WorkspaceInspectorToggle(isPresented: true, canPresent: true, action: {})
                    .frame(width: Self.toggleWidth, height: Self.toggleHeight)
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .font(.system(size: DSGlyph.toolbar))
            .foregroundStyle(DSColors.labelPrimary)
            .padding(.horizontal, DSSpacing.xxs)
            .frame(height: Self.capsuleHeight)
            .galleryGlass(in: Capsule())
        }
        .padding(.horizontal, DSSpacing.lg)
        .frame(height: DSBarHeight.column)
    }

    /// The boards' toggle capsule: 32pt of glass, 2pt in from 30pt buttons that pad a 16pt glyph
    /// by 8pt each side. Smaller than the toolbar's 36pt groups, as it sits in the 44pt header
    /// rather than the 52pt toolbar row. (Computed: a generic type cannot store statics.)
    private static var capsuleHeight: CGFloat { 32 }
    private static var toggleHeight: CGFloat { 30 }
    private static var toggleWidth: CGFloat { 32 }
}

/// The window as the boards draw it, for the canvas and the fidelity report: the floating navigator
/// and inspector glass, the toolbar strip over the centre column, and the shell's own detail
/// column (`WorkspaceDetailColumn`) between them. Glass and a title-bar toolbar draw only on screen,
/// so an offscreen render of the real split view came out blank; "Open in a window" shows the real
/// `WorkspaceShellLayout`.
///
/// At 1440 × 900 this puts the navigator at x 8–272, the toolbar at x 280–1124 and y 0–52, the
/// content card at x 280–1124 and y 56–892, and the inspector at x 1132–1432, as the boards do.
struct GalleryWindowCanvas<Detail: View, Inspector: View>: View {
    let tab: NavigatorTab
    let toolbar: GalleryToolbarFixture
    let detail: Detail
    let inspector: Inspector

    init(
        tab: NavigatorTab,
        toolbar: GalleryToolbarFixture,
        @ViewBuilder detail: () -> Detail,
        @ViewBuilder inspector: () -> Inspector
    ) {
        self.tab = tab
        self.toolbar = toolbar
        self.detail = detail()
        self.inspector = inspector()
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            GalleryNavigatorPanel(tab: tab)
                .frame(width: DSLayout.sidebarWidth)
                .padding([.leading, .vertical], DSLayout.panelInset)
            VStack(spacing: 0) {
                GalleryToolbarStrip(fixture: toolbar)
                    .frame(height: GalleryToolbarStrip.rowHeight)
                    .padding(.horizontal, DSLayout.panelInset)
                detail
            }
            inspector
                .frame(width: DSLayout.inspectorWidth)
                .padding([.trailing, .vertical], DSLayout.panelInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DSColors.window)
    }
}

/// The navigator column as the window draws it: the window controls' row, the mode picker, the
/// endpoint or journey list, and the pinned filter.
struct GalleryNavigator: View {
    @State private var tab: String
    @State private var endpointSelection: UUID?
    @State private var journeySelection: UUID? = DesignFixtures.paymentRetry.id
    @State private var filter = ""
    @State private var scope = SidebarView.anyMethodScopeID
    @State private var collapsed: Set<String> = []
    /// Whether the column paints the window colour behind itself. A panel draws glass instead.
    private let drawsBackground: Bool
    /// The endpoints the list shows; none draws the empty navigator.
    private let endpoints: [Endpoint]

    init(tab: NavigatorTab = .endpoints, drawsBackground: Bool = true,
         endpoints: [Endpoint] = DesignFixtures.endpoints) {
        _tab = State(initialValue: tab.id)
        _endpointSelection = State(initialValue: endpoints.first { $0.id == DesignFixtures.products.id }?.id)
        self.drawsBackground = drawsBackground
        self.endpoints = endpoints
    }

    private var showsJourneys: Bool { tab == NavigatorTab.journeys.id }

    var body: some View {
        VStack(spacing: 0) {
            // The window controls' row, which the navigator column sits under.
            Color.clear.frame(height: 44)
            DSNavigatorHeader(
                modes: NavigatorTab.allCases.map { DSNavigatorMode(id: $0.id, title: $0.title, help: $0.help) },
                selection: $tab
            )
            Group {
                if showsJourneys {
                    JourneyNavigatorList(
                        journeys: DesignFixtures.journeys,
                        activeJourneyID: DesignFixtures.paymentRetry.id,
                        activeStatus: DesignFixtures.paymentRetryStatus,
                        selectedJourneyID: $journeySelection,
                        onActivate: { _ in },
                        onAdd: {},
                        onDuplicate: { _ in },
                        onDelete: { _ in },
                        searchText: filter,
                        collapsedGroups: $collapsed
                    )
                } else {
                    SidebarView(
                        projectName: DesignFixtures.projectName,
                        endpoints: endpoints,
                        serverConfiguration: DesignFixtures.serverConfiguration,
                        selectedEndpointID: $endpointSelection,
                        onDeleteEndpoint: { _ in },
                        onDuplicateEndpoint: { _ in nil },
                        onAddEndpoint: {},
                        searchText: $filter,
                        methodScopeID: $scope,
                        collapsedSections: $collapsed
                    )
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
            DSNavigatorFooter(
                text: $filter,
                scopeID: $scope,
                scopes: showsJourneys ? [] : SidebarView.methodScopes,
                placeholder: "Filter",
                label: showsJourneys ? "Filter journeys" : "Filter endpoints",
                identifier: "gallery.navigatorFilter"
            ) {
                DSPanelHeaderButton(
                    systemImage: "plus",
                    help: showsJourneys ? "Add journey" : "Add endpoint",
                    identifier: "gallery.navigatorAdd"
                ) {}
            }
            .id(tab)
        }
        .background(drawsBackground ? DSColors.window : Color.clear)
    }
}

/// The navigator as the boards draw it, on its own: the floating glass column with the window's
/// controls over it. In a window, the split view draws both, so `GalleryNavigator` leaves them out.
struct GalleryNavigatorPanel: View {
    let tab: NavigatorTab
    var endpoints: [Endpoint] = DesignFixtures.endpoints

    var body: some View {
        GalleryNavigator(tab: tab, drawsBackground: false, endpoints: endpoints)
            .overlay(alignment: .top) { GalleryWindowControls() }
            .galleryGlass(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

/// Stand-ins for what the window draws over the navigator: the close, minimise and zoom buttons,
/// and the sidebar toggle, as the boards place them in the 44pt row above the mode switch.
private struct GalleryWindowControls: View {
    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            ForEach(Self.lights, id: \.self) { hex in
                Circle()
                    .fill(Color(nsColor: NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                                                 green: CGFloat((hex >> 8) & 0xFF) / 255,
                                                 blue: CGFloat(hex & 0xFF) / 255, alpha: 1)))
                    .frame(width: 12, height: 12)
            }
            Spacer(minLength: 0)
            Image(systemName: "sidebar.left")
                .font(.system(size: DSGlyph.button))
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: 28, height: 24)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: 44)
    }

    /// The system's traffic-light colours, as the boards paint them.
    private static let lights: [UInt32] = [0xFF5F57, 0xFEBC2E, 0x28C840]
}

/// The window's skeleton with nothing in it: the navigator, the jump bar, the editor, the request
/// log and the inspector each name their slot, under the toolbar a window with no project shows.
/// What `WorkspaceShellLayout` owns, the panels' geometry, chrome and dividers, is all there is.
struct GalleryEmptyWindow: View {
    /// Whether the toolbar is installed. Only in its own window: on the gallery canvas the items
    /// would land in the gallery's own toolbar instead.
    let showsToolbar: Bool
    @State private var isRequestLogPresented = true
    @State private var requestLogHeight: CGFloat = 319
    @State private var isInspectorPresented = true
    @State private var toolbarLayout: WorkspaceToolbarLayout = .expanded

    init(showsToolbar: Bool = false) {
        self.showsToolbar = showsToolbar
    }

    var body: some View {
        WorkspaceShellLayout(
            metrics: GalleryWorkspaceWindow.metrics,
            isRequestLogPresented: $isRequestLogPresented,
            requestLogHeight: $requestLogHeight,
            isInspectorPresented: $isInspectorPresented,
            onToolbarLayoutChange: { toolbarLayout = $0 },
            navigator: {
                VStack(spacing: 0) {
                    // The window controls' row, which the navigator column sits under.
                    Color.clear.frame(height: 44)
                    GallerySlot(title: "Navigator")
                }
                .background(DSColors.window)
            },
            jumpBar: { GallerySlot(title: "Jump bar").frame(height: 32) },
            center: { GallerySlot(title: "Editor") },
            requestLog: { GallerySlot(title: "Request log") },
            takeover: { EmptyView() },
            inspector: {
                GallerySlot(title: "Inspector")
                    .background(DSColors.window)
                    .toolbar {
                        if showsToolbar { GalleryInspectorHeader(title: "Inspector", toolbar: toolbarFixture.state) }
                    }
            },
            toolbar: {
                if showsToolbar { toolbarFixture.toolbar }
            }
        )
    }

    private var toolbarFixture: GalleryToolbarFixture {
        var fixture = GalleryToolbarFixture.empty
        fixture.layout = toolbarLayout
        fixture.isInspectorPresented = isInspectorPresented
        return fixture
    }
}

/// An empty panel that says which slot it is.
struct GallerySlot: View {
    let title: String

    var body: some View {
        Text(title)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelTertiary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The inspector's toolbar section, as the app gives it: the mode's title, then the window's panel
/// toggles, which leave the centre toolbar while the inspector shows.
struct GalleryInspectorHeader: ToolbarContent {
    let title: String
    let toolbar: WorkspaceToolbarState
    /// The mode's own action, after the spacer: the journey step's "…" menu.
    var action: AnyView? = nil

    @ToolbarContentBuilder
    var body: some ToolbarContent {
        ToolbarItem(id: "inspector.header") {
            Text(title)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .padding(.leading, DSSpacing.xs)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible)

        if let action {
            ToolbarItem(id: "inspector.action") { action }
                .sharedBackgroundVisibility(.hidden)
        }

        ToolbarItemGroup {
            WorkspaceRequestLogToggle(isShown: toolbar.isRequestLogShown, action: {})
                .labelStyle(.iconOnly)
            WorkspaceInspectorToggle(isPresented: toolbar.isInspectorPresented,
                                     canPresent: toolbar.canPresentInspector, action: {})
                .labelStyle(.iconOnly)
        }
    }
}
