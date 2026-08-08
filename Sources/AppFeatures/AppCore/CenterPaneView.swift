import SwiftUI
import Domain
import DesignSystem

/// Center pane — edits whatever the active navigator has selected.
///
/// Acts as the bridge between AppState and the decoupled editors. Which editor appears follows the
/// navigator tab, the same way clicking a file in Xcode's project navigator and a test in its test
/// navigator both change the one editor rather than opening a second place to look.
struct CenterPaneView: View {
    @Environment(AppState.self) private var appState
    let content: CenterPaneContent
    /// Back/forward and the lateral moves, injected rather than derived here — the editors stay
    /// decoupled from `AppState`, and this view is the bridge that already knows both sides.
    var navigation: CenterPaneNavigation = CenterPaneNavigation()
    /// Opens the new-journey sheet, which `WorkspaceView` presents. Injected rather than reached for
    /// through `AppState`: the sheet has one presenter, and adding a second here is what
    /// `ContentView` warns about two files over.
    var onStartEmptyJourney: () -> Void = {}

    var body: some View {
        switch content {
        case let .endpoint(endpointID):
            endpointEditor(for: endpointID)
        case let .journey(journeyID):
            journeyEditor(for: journeyID)
        }
    }

    // MARK: - Endpoints

    @ViewBuilder
    private func endpointEditor(for endpointID: UUID?) -> some View {
        if let endpointID,
           let endpoint = appState.currentProject?.endpoints.first(where: { $0.id == endpointID }) {
            let activeScenario: Scenario? = {
                guard let activeID = endpoint.activeScenarioID else { return nil }
                return endpoint.scenarios.first { $0.id == activeID }
            }()
            EndpointEditorView(
                endpoint: endpoint,
                activeScenario: activeScenario,
                globalDelayMs: appState.serverConfiguration.globalDelayMs,
                navigation: navigation,
                actions: EndpointEditorActions(
                    onDuplicate: { _ = appState.duplicateEndpoint(id: endpointID) },
                    onDelete: { appState.deleteEndpoint(id: endpointID) },
                    onUpdateScenario: { appState.updateActiveScenario(endpointID: endpointID, statusCode: $0, headers: $1, body: $2) },
                    onUpdateDelay: { appState.updateEndpointDelay(id: endpointID, delayMs: $0) },
                    onUpdateGroupTag: { appState.updateEndpointGroupTag(id: endpointID, groupTag: $0) },
                    onActivateScenario: { appState.setActiveScenario(endpointID: endpointID, scenarioID: $0) }
                    // No `onCreateScenario` yet, so the control omits "New scenario…". The design
                    // asks for it, and it is deliberately deferred rather than faked: `NewScenarioSheet`
                    // is presented by `InspectorPanelView` from its own local state, and adding a
                    // second presenter here is the thing `ContentView` warns about a few files over —
                    // "one sheet with one presenter is what stops the two branches drifting into two
                    // slightly different dialogs". Re-homing that presenter belongs with the inspector
                    // rebuild, which is already rewriting the panel that owns it.
                )
            )
        } else {
            // The header stays when the content does not — AGENTS.md's rule, and here it is
            // load-bearing rather than cosmetic. The jump bar this replaced rendered a "No endpoint"
            // crumb and kept its arrows live, so Back still worked after you deleted the endpoint you
            // were on. That is the single case Back exists for. An editor header that disappears with
            // its selection would take the only way out with it.
            VStack(spacing: 0) {
                emptySelectionHeader

                DSEmptyState(
                    systemImage: NavigatorTab.endpoints.systemImage,
                    heading: "No endpoint selected",
                    message: "Select an endpoint from the sidebar to view and edit its configuration.",
                    identifier: "center.noSelection"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    /// The 30pt bar the centre pane keeps when it has no endpoint to show.
    ///
    /// Carries only the history pair. There is no title: the empty state directly beneath already
    /// says what is going on, and repeating it here would be the second copy of one sentence.
    @ViewBuilder
    private var emptySelectionHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            EditorHistoryControls(
                canGoBack: navigation.canGoBack,
                canGoForward: navigation.canGoForward,
                onBack: navigation.onBack,
                onForward: navigation.onForward
            )

            Spacer(minLength: DSSpacing.sm)
        }
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSBarHeight.panelHeader)
        .background(DSColors.surfacePanelHeader)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    // MARK: - Journeys

    @ViewBuilder
    private func journeyEditor(for journeyID: UUID?) -> some View {
        if let journeyID,
           let journey = appState.journeys.first(where: { $0.id == journeyID }) {
            JourneyEditorView(
                journey: journey,
                isActive: appState.activeJourney?.id == journey.id,
                status: appState.activeJourney?.id == journey.id ? appState.activeJourneyStatus : nil,
                navigation: navigation
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("center.journeyEditor")
        } else if appState.journeys.isEmpty {
            // The gallery *is* the empty state. Journeys are the app's most valuable idea and its
            // least obvious, and the nine templates teach it better than any paragraph — but they
            // sat two clicks deep, so the screen a new user actually met said "No journeys yet" and
            // offered nothing to look at.
            //
            // Only when there are none. With a journey in the project the pane means "you have not
            // selected one", which is a different sentence and a different answer.
            JourneyTemplateGallery(
                templates: JourneyTemplates.all,
                onCreate: { template in
                    if let journey = appState.addJourney(fromTemplate: template.id) {
                        appState.selectedJourneyID = journey.id
                    }
                },
                onStartEmpty: onStartEmptyJourney
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("center.journeyGallery")
        } else {
            DSEmptyState(
                systemImage: NavigatorTab.journeys.systemImage,
                heading: "No journey selected",
                message: "Select a journey from the sidebar to script its steps, or add one to get started.",
                identifier: "center.noJourneySelection"
            )
        }
    }
}
