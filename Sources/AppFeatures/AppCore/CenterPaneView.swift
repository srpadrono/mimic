import DesignSystem
import Domain
import EndpointsFeature
import FeatureSupport
import JourneysFeature
import SwiftUI

/// Center pane — edits whatever the active navigator has selected.
///
/// Acts as the bridge between AppState and the decoupled editors. Which editor appears follows the
/// navigator tab, the same way clicking a file in Xcode's project navigator and a test in its test
/// navigator both change the one editor rather than opening a second place to look.
struct CenterPaneView: View {
    @Environment(AppState.self) private var appState
    let content: CenterPaneContent
    var onRenameEndpoint: (UUID) -> Void = { _ in }
    var onEditEndpointRequest: (UUID) -> Void = { _ in }
    var onAddEndpoint: () -> Void = {}
    var onImportHAR: () -> Void = {}
    var onImportOpenAPI: () -> Void = {}
    /// The endpoint editor's own height, so the request log can sit right below it; `nil` while
    /// the pane shows anything that fills the pane instead.
    var onContentHeightChange: (CGFloat?) -> Void = { _ in }

    var body: some View {
        Group {
            switch content {
            case let .endpoint(endpointID):
                endpointEditor(for: endpointID)
            case let .journey(journeyID):
                journeyEditor(for: journeyID)
            }
        }
        // The canvas belongs to the pane, not to the editors inside it.
        //
        // Both editors used to paint their own background on their roots and the two empty states painted
        // nothing at all — `DSEmptyState` has no background — so the centre column was one colour
        // when something was selected and whatever the window happened to be behind it when nothing
        // was. Selecting an endpoint changed the pane's colour, which reads as a redraw glitch
        // rather than as a selection.
        //
        // Stated once here, so every branch of the switch above lands on the same surface and a
        // future third branch cannot forget to.
        // Keep the leading edge visible when a form's fixed controls exceed a narrow pane.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(DSColors.content)
    }

    // MARK: - Endpoints

    @ViewBuilder
    private func endpointEditor(for endpointID: UUID?) -> some View {
        if let endpointID,
           let endpoint = appState.currentProject?.endpoints.first(where: { $0.id == endpointID }) {
            let scenario = appState.editedScenario(of: endpoint)
            let configuration = appState.serverConfiguration
            let listener = configuration.backend(id: endpoint.backendID) ?? configuration.listeners.first
            EndpointEditorView(
                endpoint: endpoint,
                activeScenario: scenario,
                globalDelayMs: configuration.globalDelayMs,
                backends: configuration.listeners,
                baseAddress: "localhost:\(listener?.port ?? configuration.port)",
                actions: EndpointEditorActions(
                    onRename: { onRenameEndpoint(endpointID) },
                    onEditRequest: { onEditEndpointRequest(endpointID) },
                    onDuplicate: { _ = appState.duplicateEndpoint(id: endpointID) },
                    onDelete: { appState.deleteEndpoint(id: endpointID) },
                    onUpdateScenario: { status, headers, body in
                        guard let scenarioID = scenario?.id else { return }
                        appState.updateScenario(
                            endpointID: endpointID, scenarioID: scenarioID,
                            statusCode: status, headers: headers, body: body
                        )
                    },
                    onUpdateContentType: { contentType in
                        guard let scenarioID = scenario?.id else { return }
                        appState.updateScenario(endpointID: endpointID, scenarioID: scenarioID, contentType: contentType)
                    },
                    onUpdateDelay: { appState.updateEndpointDelay(id: endpointID, delayMs: $0) },
                    onUpdateGroupTag: { appState.updateEndpointGroupTag(id: endpointID, groupTag: $0) },
                    onUpdateBackend: { appState.updateEndpointBackend(id: endpointID, backendID: $0) },
                    onMakeLive: { appState.setActiveScenario(endpointID: endpointID, scenarioID: $0) },
                    onRenameScenario: { appState.renameScenario(endpointID: endpointID, scenarioID: $0, name: $1) },
                    onDuplicateScenario: {
                        if let copy = appState.duplicateScenario(endpointID: endpointID, scenarioID: $0) {
                            appState.editScenario(endpointID: endpointID, scenarioID: copy.id)
                        }
                    },
                    onDeleteScenario: { appState.deleteScenario(endpointID: endpointID, scenarioID: $0) }
                )
            )
            .onGeometryChange(for: CGFloat.self) { $0.size.height.rounded(.up) } action: { height in
                onContentHeightChange(height)
            }
        } else {
            Group {
                if appState.currentProject?.endpoints.isEmpty ?? true {
                    FirstEndpointChooser(
                        port: appState.serverState.runningPort ?? appState.serverConfiguration.port,
                        onAddEndpoint: onAddEndpoint,
                        onImportHAR: onImportHAR,
                        onImportOpenAPI: onImportOpenAPI
                    )
                } else {
                    DSEmptyState(
                        heading: "No endpoint selected",
                        message: "Select an endpoint from the sidebar to view and edit its configuration.",
                        identifier: "center.noSelection"
                    )
                }
            }
            .onAppear { onContentHeightChange(nil) }
        }
    }

    // MARK: - Journeys

    @ViewBuilder
    private func journeyEditor(for journeyID: UUID?) -> some View {
        if let journeyID,
           let journey = appState.journeys.first(where: { $0.id == journeyID }) {
            JourneyEditorView(
                model: appState,
                journey: journey,
                isActive: appState.activeJourney?.id == journey.id,
                status: appState.activeJourney?.id == journey.id ? appState.activeJourneyStatus : nil
            )
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("center.journeyEditor")
            .onAppear { onContentHeightChange(nil) }
        } else {
            DSEmptyState(
                systemImage: NavigatorTab.journeys.systemImage,
                heading: "No journey selected",
                message: "Select a journey from the sidebar to script its steps, or add one to get started.",
                identifier: "center.noJourneySelection"
            )
            .onAppear { onContentHeightChange(nil) }
        }
    }
}

/// What the centre pane is editing.
///
/// Selecting in a navigator changes the editor, exactly as clicking a file in Xcode's project
/// navigator does. Modelled as one value rather than two optional IDs so the two cannot both be
/// "selected" and leave the pane guessing which to show.
enum CenterPaneContent: Equatable, Sendable {
    case endpoint(UUID?)
    case journey(UUID?)

    static func forTab(_ tab: NavigatorTab, endpointID: UUID?, journeyID: UUID?) -> CenterPaneContent {
        switch tab {
        case .endpoints: .endpoint(endpointID)
        case .journeys: .journey(journeyID)
        }
    }
}
