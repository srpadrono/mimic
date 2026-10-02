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
        case toolbar = "Toolbar"
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
    /// Whether the design draws this entry. The empty window skeleton has no artboard of its own.
    let hasArtboard: Bool
    /// The artboard section's size in points, which is the size the entry is drawn at.
    let size: CGSize
    let content: @MainActor () -> AnyView

    init(_ id: String, _ title: String, group: Group, reference: String? = nil, hasArtboard: Bool = true,
         size: CGSize, @ViewBuilder content: @escaping @MainActor () -> some View) {
        self.id = id
        self.title = title
        self.group = group
        self.referenceID = reference ?? id
        self.hasArtboard = hasArtboard
        self.size = size
        self.content = { AnyView(content()) }
    }

    /// The whole window with its real toolbar, for entries a window draws. A toolbar draws only in
    /// a window's title bar, so the canvas shows these without one and offers to open them.
    @MainActor var window: AnyView? { GalleryCatalog.window(for: id) }
}

@MainActor
enum GalleryCatalog {
    static var entries: [GalleryEntry] {
        windows + workspace + toolbar + endpoints + journeys + requestLog + server + projects + importing + updates
            + DSCatalog.components.map { component(from: $0, group: .components) }
            + componentsFromSections
            + DSCatalog.tokens.map { component(from: $0, group: .tokens) }
    }

    /// The entries a section filter names: a comma-separated list of entry ids (`journeys.navigator`),
    /// id prefixes (`journeys` for every `journeys.` entry) or group names (`Request log`), matched
    /// without regard to case. An empty or missing filter keeps every entry.
    static func entries(matching filter: String?) -> [GalleryEntry] {
        let terms = (filter ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        guard !terms.isEmpty else { return entries }
        return entries.filter { entry in
            let id = entry.id.lowercased()
            let group = entry.group.rawValue.lowercased()
            return terms.contains { term in id == term || id.hasPrefix(term + ".") || group == term }
        }
    }

    /// The entries `MIMIC_SECTION` names, so the gallery and the fidelity report can show one section.
    /// Set it in the MimicGallery scheme's environment, or pass `TEST_RUNNER_MIMIC_SECTION` to
    /// `xcodebuild test`.
    static var selected: [GalleryEntry] {
        entries(matching: ProcessInfo.processInfo.environment["MIMIC_SECTION"])
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
        GalleryEntry("journeys.window", "Journey editor window", group: .windows,
                     size: CGSize(width: 1440, height: 900)) {
            GalleryJourneysWindow()
        },
        GalleryEntry("workspace.skeleton", "Empty window skeleton", group: .windows, hasArtboard: false,
                     size: CGSize(width: 1440, height: 900)) {
            GalleryEmptyWindow()
        },
    ]

    /// The window entries with their toolbar installed, for the gallery's own window scene.
    static func window(for id: String) -> AnyView? {
        switch id {
        case "workspace.window": AnyView(GalleryWorkspaceWindow(showsToolbar: true))
        case "journeys.window": AnyView(GalleryJourneysWindow(showsToolbar: true))
        case "workspace.skeleton": AnyView(GalleryEmptyWindow(showsToolbar: true))
        // The toolbar states in the window that draws them, so the real toolbar can be checked
        // against its strip. "Narrow centre column" needs a window narrow enough for that tier.
        case "toolbar.running": AnyView(GalleryWorkspaceWindow(showsToolbar: true, toolbar: .running))
        case "toolbar.stopped": AnyView(GalleryWorkspaceWindow(showsToolbar: true, toolbar: .stopped))
        case "toolbar.restartRequired": AnyView(GalleryWorkspaceWindow(showsToolbar: true, toolbar: .restartRequired))
        case "toolbar.compact": AnyView(GalleryWorkspaceWindow(showsToolbar: true, toolbar: .compact))
        default: nil
        }
    }

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
        // The jump bar's three save states side by side, on the Alerts board's desk.
        GalleryEntry("feedback.autosave", "Autosave states", group: .workspace, size: CGSize(width: 197, height: 16)) {
            HStack(spacing: 18) {
                AutosaveStatusIndicator(status: .saved)
                AutosaveStatusIndicator(status: .saving)
                AutosaveStatusIndicator(status: .failed("The disk is full."))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(GalleryDesk.color)
        },
    ]

    // MARK: - Toolbar

    /// The toolbar over the centre column, in the states the approved toolbar design draws.
    static let toolbar: [GalleryEntry] = [
        GalleryEntry("toolbar.running", "Running", group: .toolbar, size: CGSize(width: 844, height: 52)) {
            GalleryToolbarStrip(fixture: .running)
        },
        GalleryEntry("toolbar.stopped", "Stopped", group: .toolbar, size: CGSize(width: 844, height: 52)) {
            GalleryToolbarStrip(fixture: .stopped)
        },
        GalleryEntry("toolbar.restartRequired", "Ports changed while running", group: .toolbar,
                     size: CGSize(width: 844, height: 52)) {
            GalleryToolbarStrip(fixture: .restartRequired)
        },
        GalleryEntry("toolbar.compact", "Narrow centre column", group: .toolbar, size: CGSize(width: 480, height: 52)) {
            GalleryToolbarStrip(fixture: .compact)
        },
    ]

    // MARK: - Endpoints

    static let endpoints: [GalleryEntry] = [
        GalleryEntry("workspace.navigator", "Endpoint navigator", group: .endpoints,
                     size: CGSize(width: 264, height: 884)) {
            GalleryNavigatorPanel(tab: .endpoints)
        },
        GalleryEntry("endpoints.emptyNavigator", "Navigator with no endpoints", group: .endpoints,
                     size: CGSize(width: 264, height: 884)) {
            GalleryNavigatorPanel(tab: .endpoints, endpoints: [])
        },
        GalleryEntry("endpoints.editor", "Endpoint editor", group: .endpoints, size: CGSize(width: 844, height: 485)) {
            GalleryWorkspaceWindow.editor
        },
        GalleryEntry("endpoints.inspector", "Scenario inspector", group: .endpoints,
                     size: CGSize(width: 300, height: 884)) {
            GalleryEndpointInspectorPanel()
        },
        GalleryEntry("endpoints.firstRun", "First endpoint", group: .endpoints, size: CGSize(width: 1152, height: 836)) {
            // Over the empty request log, as a new project's window shows it: the chooser centres
            // in what the log leaves. 250pt is the log's height on the EmptyStates artboard.
            VStack(spacing: 0) {
                FirstEndpointChooser(port: 8080, onAddEndpoint: {}, onImportHAR: {}, onImportOpenAPI: {})
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: DSStroke.hairline)
                RequestLogDrawerView(requestLogs: [], endpoints: [], serverState: .stopped, onClear: {})
                    .configuredPort(8080)
                    .frame(height: 250)
            }
            .background(DSColors.content)
        },
        GalleryEntry("endpoints.newEndpointSheet", "New endpoint sheet", group: .endpoints,
                     size: CGSize(width: 407, height: 376)) {
            NewEndpointSheet(existingGroups: ["Account", "Catalog", "Payments"],
                             initialDraft: GalleryModels.newEndpointDraft) { _ in }
        },
    ]

    // MARK: - Journeys

    static let journeys: [GalleryEntry] = [
        GalleryEntry("journeys.navigator", "Journey navigator", group: .journeys,
                     size: CGSize(width: 264, height: 884)) {
            GalleryNavigatorPanel(tab: .journeys)
        },
        // From the jump bar down, as the artboard's section is drawn.
        GalleryEntry("journeys.editor", "Journey editor", group: .journeys, size: CGSize(width: 844, height: 836)) {
            VStack(spacing: 0) {
                GalleryJourneysWindow.jumpBar
                GalleryJourneysWindow.editor
            }
            .background(DSColors.content)
        },
        GalleryEntry("journeys.inspector", "Journey step inspector", group: .journeys,
                     size: CGSize(width: 300, height: 884)) {
            GalleryJourneyInspectorPanel()
        },
        // The artboard edits Payment retry's fourth step under the title "Edit step 3".
        GalleryEntry("journeys.stepSheet", "Journey step sheet", group: .journeys,
                     size: CGSize(width: 580, height: 696)) {
            JourneyStepSheet(
                step: DesignFixtures.editedStep,
                stepNumber: 3,
                backends: DesignFixtures.serverConfiguration.listeners,
                endpoints: DesignFixtures.endpoints,
                onCommit: { _ in },
                onRemove: {},
                visibleScreenHeight: GalleryModels.tallScreenHeight
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
            BackendSettingsView(configuration: DesignFixtures.serverSettingsConfiguration, model: GalleryModels.server,
                                visibleScreenHeight: GalleryModels.tallScreenHeight)
        },
        // The popover's content on a painted box; the board's figures, Storefront and Payments, and
        // its 24-hour clock.
        GalleryEntry("server.statusPopover", "Server status popover", group: .server,
                     size: CGSize(width: 320, height: 234)) {
            GalleryPopover {
                ServerStatusDetails(
                    serverState: .running(port: DesignFixtures.port),
                    requestCount: 142,
                    unmatchedCount: 3,
                    configuration: DesignFixtures.serverSettingsConfiguration,
                    boundConfiguration: DesignFixtures.serverSettingsConfiguration,
                    runningSince: DesignFixtures.now.addingTimeInterval(-14 * 60),
                    onShowUnmatched: {},
                    onShowSettings: {},
                    onToggleServer: {},
                    onDismiss: {}
                )
            }
            .environment(\.locale, Locale(identifier: "en_GB"))
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
            NewProjectSheet(initialProjectName: DesignFixtures.projectName, initialPortString: "8080") { _, _ in }
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
                initialSourceFileName: "checkout-session.har",
                initialHiddenHosts: ["events.segment.io"],
                // The artboard's height, whatever the screen that renders it.
                height: ImportView.designHeight,
                onCommitImport: { _ in }
            )
        },
    ]

    // MARK: - Updates

    static let updates: [GalleryEntry] = [
        GalleryEntry("updates.sheet", "Update sheet", group: .updates,
                     size: CGSize(width: DSSheetWidth.medium, height: UpdateSheet.designHeight)) {
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
        boundConfiguration: DesignFixtures.serverSettingsBoundConfiguration
    )
    static let updates = UpdateSheetPreviewModel()

    /// A screen tall enough for every sheet to open at its design height. CI's runner screen is
    /// short, and a sheet that fits itself under the real screen would render cut short there.
    static let tallScreenHeight: CGFloat = 1_200

    /// The new endpoint artboard: `GET /products/:id`, filed under Catalog.
    static let newEndpointDraft = NewEndpointDraft(
        name: "Get product", method: .get, path: "/products/:id", groupTag: "Catalog",
        statusCode: 200, contentType: .json
    )

    /// The rows the import review artboard lists, with the analytics host switched off.
    static let importCandidates: [ImportCandidate] = [
        candidate(.get, "/products", 200, bytes: 12_700),
        candidate(.get, "/products/42", 200, bytes: 1_840),
        candidate(.post, "/cart", 201, bytes: 312),
        candidate(.post, "/cart", 409, bytes: 140, selected: false, duplicate: true),
        candidate(.post, "/payments", 503, bytes: 180, host: "pay.acme.shop"),
        candidate(.get, "/media/hero-autumn.jpg", 200, bytes: 2_400_000, host: "cdn.acme.shop",
                  selected: false, binary: true),
        candidate(.post, "/v1/track", 200, bytes: 41, host: "events.segment.io", selected: false),
        candidate(.get, "/account-summary", 200, bytes: 2_150),
        candidate(.put, "/account/address", 200, bytes: 388),
        candidate(.get, "/orders/export.csv", 200, bytes: 3_990_000, selected: false, overLimit: true),
        candidate(.delete, "/session", 204, bytes: 0),
        candidate(.get, "/recommendations", 0, bytes: 0, selected: false),
    ]

    private static func candidate(
        _ method: HTTPMethod, _ path: String, _ status: Int, bytes: Int, host: String = "api.acme.shop",
        selected: Bool = true, duplicate: Bool = false, binary: Bool = false, overLimit: Bool = false
    ) -> ImportCandidate {
        ImportCandidate(
            isSelected: selected,
            method: method,
            path: path,
            host: host,
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
