import DesignSystem
import Domain
import EndpointsFeature
import JourneysFeature
import SwiftUI
import WorkspaceShell

/// The right-hand column. It shows one thing at a time: an endpoint's scenarios, a journey, or the
/// project overview. A logged request opens beside the request log in the centre column instead, and
/// the inspector steps aside while it is open.
struct InspectorPanelView: View {
    let endpoint: Endpoint?
    let journey: JourneyInspector.Context?
    /// What the journey inspector reads and edits; the journey shows only when both are set.
    let journeyModel: (any JourneyEditingModel)?
    /// Whether the column is on screen. Its header lives in the inspector's own toolbar section,
    /// level with the window's toolbar, and must leave with the column.
    let showsHeader: Bool
    /// The window's request log and inspector toggles, which sit beside the header's own action.
    let panelToggles: PanelToggles?

    /// Two views, not one, so the toolbar draws them as two buttons in one glass group.
    public struct PanelToggles {
        let requestLog: AnyView
        let inspector: AnyView

        public init(requestLog: AnyView, inspector: AnyView) {
            self.requestLog = requestLog
            self.inspector = inspector
        }
    }
    let overview: InspectorOverview.Summary?
    let onShowJourneys: () -> Void
    let onAddScenario: (_ endpointID: UUID, _ name: String) -> Void
    let onSetActiveScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDuplicateScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onDeleteScenario: (_ endpointID: UUID, _ scenarioID: UUID) -> Void
    let onRenameScenario: (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void
    let endpointTraffic: [RequestLog]
    let endpointSettings: EndpointInspectorSettings.Context?

    @State private var addScenarioTarget: ScenarioTarget?

    struct ScenarioTarget: Identifiable {
        let id: UUID
    }

    public init(
        endpoint: Endpoint?,
        overview: InspectorOverview.Summary? = nil,
        journey: JourneyInspector.Context? = nil,
        journeyModel: (any JourneyEditingModel)? = nil,
        showsHeader: Bool = true,
        panelToggles: PanelToggles? = nil,
        endpointTraffic: [RequestLog] = [],
        endpointSettings: EndpointInspectorSettings.Context? = nil,
        onShowJourneys: @escaping () -> Void = {},
        onAddScenario: @escaping (_ endpointID: UUID, _ name: String) -> Void,
        onSetActiveScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDuplicateScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onDeleteScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID) -> Void,
        onRenameScenario: @escaping (_ endpointID: UUID, _ scenarioID: UUID, _ name: String) -> Void = { _, _, _ in }
    ) {
        self.endpoint = endpoint
        self.overview = overview
        self.journey = journey
        self.journeyModel = journeyModel
        self.showsHeader = showsHeader
        self.panelToggles = panelToggles
        self.endpointTraffic = endpointTraffic
        self.endpointSettings = endpointSettings
        self.onShowJourneys = onShowJourneys
        self.onAddScenario = onAddScenario
        self.onSetActiveScenario = onSetActiveScenario
        self.onDuplicateScenario = onDuplicateScenario
        self.onDeleteScenario = onDeleteScenario
        self.onRenameScenario = onRenameScenario
    }

    enum Mode: Equatable {
        case scenarios
        case journey
        case overview
        case empty

        var title: String {
            switch self {
            case .scenarios: "Scenarios"
            case .journey: "Journey"
            case .overview: "Overview"
            case .empty: "Inspector"
            }
        }
    }

    static func mode(
        hasEndpoint: Bool,
        hasOverview: Bool,
        hasJourney: Bool = false
    ) -> Mode {
        if hasEndpoint { return .scenarios }
        if hasJourney { return .journey }
        if hasOverview { return .overview }
        return .empty
    }

    var mode: Mode {
        Self.mode(
            hasEndpoint: endpoint != nil,
            hasOverview: overview != nil,
            hasJourney: journey != nil
        )
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                if let endpoint {
                    endpointContent(endpoint)
                        .opacity(mode == .scenarios ? 1 : 0)
                        .allowsHitTesting(mode == .scenarios)
                        .accessibilityHidden(mode != .scenarios)
                }
                switch mode {
                case .journey:
                    if let journey, let journeyModel { JourneyInspector(model: journeyModel, context: journey).id(journey.selected.id) }
                case .overview:
                    if let overview { InspectorOverview(summary: overview, onShowJourneys: onShowJourneys) }
                case .empty:
                    DSEmptyState(heading: "No selection", message: "Select an endpoint or journey to inspect it.",
                                 prominence: .compact, identifier: "inspector.empty")
                case .scenarios:
                    EmptyView()
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .toolbar { headerToolbar }
        .sheet(item: $addScenarioTarget) { target in
            NewScenarioSheet { name in onAddScenario(target.id, name) }
        }
    }

    /// The header: the mode's title at the leading edge of the inspector's toolbar section, then its
    /// action and the window's panel toggles at the trailing edge, level with the window's toolbar.
    @ToolbarContentBuilder
    private var headerToolbar: some ToolbarContent {
        if showsHeader {
            ToolbarItem(id: "inspector.header") {
                headerTitle
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarSpacer(.flexible)

            if mode == .journey, let journey, let journeyModel {
                ToolbarItem(id: "inspector.stepActions") {
                    JourneyStepActionsMenu(model: journeyModel, context: journey)
                }
                .sharedBackgroundVisibility(.hidden)
            }

            if mode == .scenarios, endpoint != nil {
                ToolbarItem(id: "inspector.addScenario") {
                    DSPanelHeaderButton(systemImage: "plus", help: "Add scenario",
                                        identifier: "inspector.addScenarioButton") {
                        addScenarioTarget = endpoint.map { ScenarioTarget(id: $0.id) }
                    }
                }
                .sharedBackgroundVisibility(.hidden)
            }

            if let panelToggles {
                ToolbarItemGroup {
                    panelToggles.requestLog
                    panelToggles.inspector
                }
            }
        }
    }

    private var headerTitle: some View {
        HStack(spacing: DSSpacing.xs) {
            // A selected journey step names itself, "Step 3", as the design's inspector does.
            Text(mode == .journey ? (journey?.title ?? mode.title) : mode.title)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .fixedSize()
                .accessibilityIdentifier("ds.panelheader.title.inspector")
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.leading, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.header")
    }

    private func endpointContent(_ endpoint: Endpoint) -> some View {
        EndpointInspectorContent(
            endpoint: endpoint,
            traffic: endpointTraffic,
            settings: endpointSettings,
            onSetActiveScenario: onSetActiveScenario,
            onDuplicateScenario: onDuplicateScenario,
            onDeleteScenario: onDeleteScenario,
            onRenameScenario: onRenameScenario
        )
    }
}
