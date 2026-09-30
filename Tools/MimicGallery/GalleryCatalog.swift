import DesignSystem
import Domain
import EndpointsFeature
import FeatureSupport
import ImportFeature
import JourneysFeature
import MimicFixtures
import ProjectsFeature
import RequestLogFeature
import ServerFeature
import SpecImport
import SwiftUI
import UpdatesFeature
import WorkspaceShell

/// One thing the gallery can show: a design-system component or a UI section, drawn from the design
/// fixtures at the size of the artboard section it is meant to match.
struct GalleryEntry: Identifiable {
    enum Group: String, CaseIterable, Identifiable {
        case windows = "Windows"
        case workspace = "Workspace"
        case endpoints = "Endpoints"
        case journeys = "Journeys"
        case requestLog = "Request log"
        case server = "Server"
        case projects = "Projects"
        case importing = "Import"
        case updates = "Updates"
        case components = "Components"
        case tokens = "Tokens"

        var id: String { rawValue }
    }

    let id: String
    let title: String
    let group: Group
    /// The section of `Design/Reference/sections.json` this entry is drawn to match.
    let referenceID: String
    /// The artboard section's size in points, which is the size the entry is drawn at.
    let size: CGSize
    let content: @MainActor () -> AnyView

    init(_ id: String, _ title: String, group: Group, reference: String? = nil, size: CGSize,
         @ViewBuilder content: @escaping @MainActor () -> some View) {
        self.id = id
        self.title = title
        self.group = group
        self.referenceID = reference ?? id
        self.size = size
        self.content = { AnyView(content()) }
    }
}

@MainActor
enum GalleryCatalog {
    static var entries: [GalleryEntry] {
        windows + workspace + endpoints + journeys + requestLog + server + projects + importing + updates
            + DSCatalog.components.map { component(from: $0, group: .components) }
            + DSCatalog.tokens.map { component(from: $0, group: .tokens) }
    }

    private static func component(from entry: DSCatalog.Entry, group: GalleryEntry.Group) -> GalleryEntry {
        GalleryEntry(entry.id, entry.title, group: group, reference: entry.referenceID, size: entry.size) {
            entry.content()
        }
    }

    // MARK: - Windows

    static let windows: [GalleryEntry] = [
        GalleryEntry("workspace.window", "Endpoint editor window", group: .windows,
                     size: CGSize(width: 1440, height: 900)) {
            GalleryWorkspaceWindow()
        },
    ]

    // MARK: - Workspace shell

    static let workspace: [GalleryEntry] = [
        GalleryEntry("workspace.jumpBar", "Jump bar", group: .workspace, size: CGSize(width: 844, height: 32)) {
            BreadcrumbJumpBar(
                crumbs: GalleryWorkspaceWindow.crumbs,
                autosaveStatus: .saved,
                history: BreadcrumbJumpBar.History(canGoBack: true, canGoForward: false, onBack: {}, onForward: {}),
                onSelectOption: { _, _ in }
            )
            .background(DSColors.content)
        },
    ]

    // MARK: - Endpoints

    static let endpoints: [GalleryEntry] = [
        GalleryEntry("workspace.navigator", "Endpoint navigator", group: .endpoints,
                     size: CGSize(width: 264, height: 884)) {
            GalleryEndpointNavigator()
        },
        GalleryEntry("endpoints.editor", "Endpoint editor", group: .endpoints, size: CGSize(width: 844, height: 485)) {
            GalleryWorkspaceWindow.editor
        },
        GalleryEntry("endpoints.inspector", "Scenario inspector", group: .endpoints,
                     size: CGSize(width: 300, height: 884)) {
            GalleryWorkspaceWindow.inspector
                .background(DSColors.window)
        },
        GalleryEntry("endpoints.firstRun", "First endpoint", group: .endpoints, size: CGSize(width: 1152, height: 836)) {
            FirstEndpointChooser(port: 8080, onAddEndpoint: {}, onImportHAR: {}, onImportOpenAPI: {})
                .background(DSColors.content)
        },
        GalleryEntry("endpoints.newEndpointSheet", "New endpoint sheet", group: .endpoints,
                     size: CGSize(width: 407, height: 376)) {
            NewEndpointSheet(existingGroups: ["Account", "Catalog", "Payments"]) { _ in }
        },
    ]

    // MARK: - Journeys

    static let journeys: [GalleryEntry] = [
        GalleryEntry("journeys.navigator", "Journey navigator", group: .journeys,
                     size: CGSize(width: 264, height: 884)) {
            JourneyNavigatorList(
                journeys: DesignFixtures.journeys,
                activeJourneyID: DesignFixtures.paymentRetry.id,
                selectedJourneyID: .constant(DesignFixtures.paymentRetry.id),
                onActivate: { _ in },
                onAdd: {},
                onDuplicate: { _ in },
                onDelete: { _ in }
            )
        },
        GalleryEntry("journeys.editor", "Journey editor", group: .journeys, size: CGSize(width: 844, height: 836)) {
            JourneyEditorView(
                model: GalleryModels.journeys,
                journey: DesignFixtures.paymentRetry,
                isActive: true,
                status: JourneyStatus.make(journey: DesignFixtures.paymentRetry, state: nil)
            )
            .background(DSColors.content)
        },
        GalleryEntry("journeys.inspector", "Journey step inspector", group: .journeys,
                     size: CGSize(width: 300, height: 884)) {
            JourneyInspector(
                model: GalleryModels.journeys,
                context: JourneyInspector.Context(
                    selected: DesignFixtures.paymentRetry,
                    active: DesignFixtures.paymentRetry,
                    progress: "Step 3 of 4",
                    serverState: .running(port: DesignFixtures.port),
                    selectedStepID: DesignFixtures.paymentRetry.steps[2].id
                )
            )
            .background(DSColors.window)
        },
        GalleryEntry("journeys.stepSheet", "Journey step sheet", group: .journeys,
                     size: CGSize(width: 580, height: 696)) {
            JourneyStepSheet(
                step: DesignFixtures.paymentRetry.steps[2],
                stepNumber: 3,
                backends: DesignFixtures.serverConfiguration.listeners,
                endpoints: DesignFixtures.endpoints,
                onCommit: { _ in },
                onRemove: {}
            )
        },
    ]

    // MARK: - Request log

    static let requestLog: [GalleryEntry] = [
        GalleryEntry("requestLog.drawer", "Request log", group: .requestLog, size: CGSize(width: 844, height: 319)) {
            GalleryWorkspaceWindow.requestLog(showsDetail: false)
        },
        GalleryEntry("requestLog.detail", "Request detail", group: .requestLog, size: CGSize(width: 1152, height: 836)) {
            GalleryWorkspaceWindow.requestLog(showsDetail: true)
        },
    ]

    // MARK: - Server

    static let server: [GalleryEntry] = [
        GalleryEntry("server.settings", "Server settings", group: .server, size: CGSize(width: 760, height: 576)) {
            BackendSettingsView(configuration: DesignFixtures.serverConfiguration, model: GalleryModels.server)
        },
    ]

    // MARK: - Projects

    static let projects: [GalleryEntry] = [
        GalleryEntry("projects.welcome", "Welcome window", group: .projects, size: CGSize(width: 880, height: 560)) {
            WelcomeWindow(
                recentProjects: DesignFixtures.recentProjects,
                onOpenProject: { _ in },
                onDuplicateProject: { _ in },
                onDeleteProject: { _ in },
                onRequestNewProject: {},
                onRequestImport: { _ in },
                onRequestOpenExport: {},
                onRequestSampleProject: {}
            )
        },
        GalleryEntry("projects.newProjectSheet", "New project sheet", group: .projects,
                     size: CGSize(width: 377, height: 227)) {
            NewProjectSheet { _, _ in }
        },
    ]

    // MARK: - Import

    static let importing: [GalleryEntry] = [
        GalleryEntry("import.review", "Import review", group: .importing, size: CGSize(width: 1000, height: 696)) {
            ImportView(
                kind: .har,
                existingEndpoints: [],
                initialCandidates: GalleryModels.importCandidates,
                initialParseError: nil,
                initialIsParsing: false,
                onCommitImport: { _ in }
            )
        },
    ]

    // MARK: - Updates

    static let updates: [GalleryEntry] = [
        GalleryEntry("updates.sheet", "Update sheet", group: .updates, size: CGSize(width: 560, height: 480)) {
            UpdateSheet(service: GalleryModels.updates)
        },
    ]
}

/// The stand-in models the sections edit through. One of each, so edits made in the gallery stay put
/// while you move between entries.
@MainActor
enum GalleryModels {
    static let journeys = JourneyPreviewModel(
        project: DesignFixtures.project,
        serverState: .running(port: DesignFixtures.port),
        requestLogs: DesignFixtures.requestLogs
    )
    static let server = ServerSettingsPreviewModel(
        projectName: DesignFixtures.projectName,
        serverState: .running(port: DesignFixtures.port),
        boundConfiguration: DesignFixtures.serverConfiguration
    )
    static let updates = UpdateSheetPreviewModel()

    /// The rows the import review artboard lists.
    static let importCandidates: [ImportCandidate] = [
        candidate(.get, "/products", 200, bytes: 12_700),
        candidate(.get, "/products/42", 200, bytes: 1_840),
        candidate(.post, "/cart", 201, bytes: 312),
        candidate(.post, "/cart", 409, bytes: 140, selected: false, duplicate: true),
        candidate(.post, "/payments", 503, bytes: 180),
        candidate(.get, "/media/hero-autumn.jpg", 200, bytes: 2_400_000, selected: false, binary: true),
        candidate(.get, "/account-summary", 200, bytes: 2_150),
        candidate(.put, "/account/address", 200, bytes: 388),
        candidate(.get, "/orders/export.csv", 200, bytes: 3_900_000, selected: false, overLimit: true),
        candidate(.delete, "/session", 204, bytes: 0),
    ]

    private static func candidate(
        _ method: HTTPMethod, _ path: String, _ status: Int, bytes: Int,
        selected: Bool = true, duplicate: Bool = false, binary: Bool = false, overLimit: Bool = false
    ) -> ImportCandidate {
        ImportCandidate(
            isSelected: selected,
            method: method,
            path: path,
            suggestedName: path,
            suggestedGroupTag: nil,
            statusCode: status,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: binary || overLimit ? nil : "{}",
            responseContentType: .json,
            bodySizeBytes: bytes,
            bodySizeExceedsLimit: overLimit,
            bodyIsBinary: binary,
            isDuplicate: duplicate
        )
    }
}
