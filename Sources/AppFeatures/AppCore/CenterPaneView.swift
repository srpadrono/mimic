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
            // No `.id(endpointID)` here, and that is a decision rather than an omission. One view
            // identity across a selection change is what gives the editor the same `@State` boxes on
            // both sides of the click, which is what
            // `EndpointEditorView.endpointSelectionChanged()` needs in order to finish an edit that
            // was still settling when the click landed. Adding an id would hand the new endpoint a
            // fresh editor and take that flush out of the picture without changing a line of it.
            EndpointEditorView(
                endpoint: endpoint,
                activeScenario: activeScenario,
                globalDelayMs: appState.serverConfiguration.globalDelayMs,
                actions: EndpointEditorActions(
                    onDuplicate: { _ = appState.duplicateEndpoint(id: endpointID) },
                    onDelete: { appState.deleteEndpoint(id: endpointID) },
                    onUpdateScenario: { appState.updateActiveScenario(endpointID: endpointID, statusCode: $0, headers: $1, body: $2) },
                    onUpdateDelay: { appState.updateEndpointDelay(id: endpointID, delayMs: $0) },
                    onUpdateGroupTag: { appState.updateEndpointGroupTag(id: endpointID, groupTag: $0) }
                )
            )
        } else {
            DSEmptyState(
                systemImage: NavigatorTab.endpoints.systemImage,
                heading: "No endpoint selected",
                message: "Select an endpoint from the sidebar to view and edit its configuration.",
                identifier: "center.noSelection"
            )
        }
    }

    // MARK: - Journeys

    @ViewBuilder
    private func journeyEditor(for journeyID: UUID?) -> some View {
        if let journeyID,
           let journey = appState.journeys.first(where: { $0.id == journeyID }) {
            JourneyEditorView(
                journey: journey,
                isActive: appState.activeJourney?.id == journey.id,
                status: appState.activeJourney?.id == journey.id ? appState.activeJourneyStatus : nil
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("center.journeyEditor")
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
