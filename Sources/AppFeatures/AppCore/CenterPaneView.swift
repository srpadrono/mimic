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
    var onRenameEndpoint: (UUID) -> Void = { _ in }
    var onEditEndpointRequest: (UUID) -> Void = { _ in }
    var onAddEndpoint: () -> Void = {}
    var onImportHAR: () -> Void = {}
    var onImportOpenAPI: () -> Void = {}
    /// The endpoint editor's own height, so the request log can sit right below it; `nil` while
    /// the pane shows anything that fills the pane instead.
    var onContentHeightChange: (CGFloat?) -> Void = { _ in }

    /// The pane's width, which decides how many option cards share a row.
    @State private var chooserWidth: CGFloat = 1_000

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
                    firstEndpointChooser
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

    /// A new project's centre: three ways to get a first endpoint.
    ///
    /// The headline sits over the three cards, which share one row and shrink before they wrap; a
    /// pane too short for all of it scrolls rather than clipping the headline.
    private var firstEndpointChooser: some View {
        ViewThatFits(in: .vertical) {
            firstEndpointChooserContent
            ScrollView { firstEndpointChooserContent }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { chooserWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ds.empty.center.noSelection")
    }

    private var firstEndpointChooserContent: some View {
        let port = appState.serverState.runningPort ?? appState.serverConfiguration.port
        let columns = Self.chooserColumns(forWidth: chooserWidth - 2 * DSSpacing.xxl)
        return VStack(spacing: DSSpacing.xxl + DSSpacing.xs) {
            VStack(spacing: DSSpacing.sm) {
                Text("Mock your first endpoint")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("ds.empty.center.noSelection.heading")
                    .accessibilityAddTraits(.isHeader)
                Text("Add one by hand, or bring in traffic you already have. Mimic serves it on localhost:\(String(port)) when you press Run.")
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .multilineTextAlignment(.center)
                    .lineSpacing(DSTypography.Leading.callout)
                    .frame(maxWidth: 460)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("ds.empty.center.noSelection.message")
            }
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(
                        .flexible(minimum: Self.cardMinimumWidth, maximum: Self.cardWidth),
                        spacing: DSSpacing.lg,
                        alignment: .top
                    ),
                    count: columns
                ),
                alignment: .center,
                spacing: DSSpacing.lg
            ) {
                chooserCards
            }
            .frame(maxWidth: CGFloat(columns) * Self.cardWidth + CGFloat(columns - 1) * DSSpacing.lg)
        }
        .padding(DSSpacing.xxl)
        .frame(maxWidth: .infinity)
    }

    /// The design's card width, and the narrowest a card gets before the row wraps.
    private static let cardWidth: CGFloat = 220
    private static let cardMinimumWidth: CGFloat = 168

    /// Three cards to a row while they fit at their narrowest, then two, then one.
    static func chooserColumns(forWidth width: CGFloat) -> Int {
        let perCard = cardMinimumWidth + DSSpacing.lg
        let fitting = Int((width + DSSpacing.lg) / perCard)
        return min(3, max(1, fitting))
    }

    @ViewBuilder
    private var chooserCards: some View {
        // ⌥⌘N, the shortcut File ▸ New Endpoint… really has; ⌘N is New Project.
        DSOptionCard("Add endpoint", systemImage: "plus",
                     message: "Choose a method and path, then write the response.",
                     shortcut: ["⌥", "⌘", "N"], isDefault: true, identifier: "empty.center.noSelection.cta",
                     action: onAddEndpoint)
        DSOptionCard("Import HAR", systemImage: "doc.text",
                     message: "From Proxyman, Charles or browser DevTools.",
                     footnote: "A .har file", identifier: "center.importHAR", action: onImportHAR)
        DSOptionCard("Import OpenAPI", systemImage: "curlybraces",
                     message: "Each operation becomes an endpoint with its example response.",
                     footnote: "JSON or YAML", identifier: "center.importOpenAPI", action: onImportOpenAPI)
    }

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
