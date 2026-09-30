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
    @State private var isRequestLogPresented = true
    @State private var requestLogHeight: CGFloat = 319
    @State private var isInspectorPresented = true
    @State private var toolbarLayout: WorkspaceToolbarLayout = .expanded

    var body: some View {
        WorkspaceShellLayout(
            metrics: WorkspacePanelMetrics(
                minimumCentreHeight: 200,
                minimumRequestLogHeight: 120,
                defaultRequestLogHeight: 319,
                minimumInspectorWidth: 260,
                idealInspectorWidth: 300
            ),
            isRequestLogPresented: $isRequestLogPresented,
            requestLogHeight: $requestLogHeight,
            isInspectorPresented: $isInspectorPresented,
            onToolbarLayoutChange: { toolbarLayout = $0 },
            navigator: { GalleryNavigator() },
            jumpBar: {
                BreadcrumbJumpBar(
                    crumbs: Self.crumbs,
                    autosaveStatus: .saved,
                    history: BreadcrumbJumpBar.History(canGoBack: true, canGoForward: false,
                                                       onBack: {}, onForward: {}),
                    onSelectOption: { _, _ in }
                )
            },
            center: { Self.editor },
            requestLog: { Self.requestLog(showsDetail: false) },
            takeover: { EmptyView() },
            inspector: { Self.inspector },
            toolbar: {
                ToolbarItem(placement: .navigation) {
                    ServerToggleButton(serverState: .running(port: DesignFixtures.port), onStart: {}, onStop: {})
                }
                ToolbarItem(placement: .principal) {
                    ServerStatusWell(
                        serverState: .running(port: DesignFixtures.port),
                        projectName: DesignFixtures.projectName,
                        requestCount: 142,
                        unmatchedCount: 3,
                        compact: toolbarLayout.usesCompactSummary,
                        configuration: DesignFixtures.serverConfiguration
                    )
                }
            }
        )
    }

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

    @MainActor
    static var inspector: some View {
        let endpoint = DesignFixtures.products
        let configuration = DesignFixtures.serverConfiguration
        return EndpointInspectorContent(
            endpoint: endpoint,
            traffic: EndpointTrafficQuery.logs(forEndpoint: endpoint.id, in: DesignFixtures.requestLogs),
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
            onRenameScenario: { _, _, _ in }
        )
    }

    @MainActor
    static func requestLog(showsDetail: Bool) -> some View {
        let logs = DesignFixtures.requestLogs
        return RequestLogDrawerView(
            requestLogs: logs,
            endpoints: DesignFixtures.endpoints,
            serverState: .running(port: DesignFixtures.port),
            onClear: {},
            selectedLogIDs: .constant(showsDetail ? Set(logs.suffix(1).map(\.id)) : []),
            journeys: DesignFixtures.journeys,
            showsDetail: showsDetail
        )
        .background(DSColors.content)
    }
}

/// The navigator column as the window draws it: the window controls' row, the mode picker, the
/// endpoint or journey list, and the pinned filter.
struct GalleryNavigator: View {
    @State private var tab: String
    @State private var endpointSelection: UUID? = DesignFixtures.products.id
    @State private var journeySelection: UUID? = DesignFixtures.paymentRetry.id
    @State private var filter = ""
    @State private var scope = SidebarView.anyMethodScopeID
    @State private var collapsed: Set<String> = []

    init(tab: NavigatorTab = .endpoints) {
        _tab = State(initialValue: tab.id)
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
                        activeStatus: JourneyStatus.make(journey: DesignFixtures.paymentRetry, state: nil),
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
                        endpoints: DesignFixtures.endpoints,
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
        .background(DSColors.window)
    }
}
