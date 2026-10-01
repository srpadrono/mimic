import DesignSystem
import SwiftUI

/// What the workspace toolbar shows, as plain values, so the app and the gallery draw the same
/// toolbar from a session or from fixtures.
public nonisolated struct WorkspaceToolbarState: Equatable, Sendable {
    /// How much fits over the centre column; see ``WorkspaceToolbarLayout``.
    public var layout: WorkspaceToolbarLayout
    /// The open project's name, or `nil` when none is open.
    public var projectName: String?
    /// "12 endpoints · 3 journeys", the name's subtitle while there is room for it.
    public var projectContents: String
    /// The server is running on ports the settings have since changed.
    public var restartRequired: Bool
    public var unmatchedCount: Int
    public var isRequestLogShown: Bool
    public var isInspectorPresented: Bool
    /// Whether there is anything for the inspector to show.
    public var canPresentInspector: Bool

    public init(
        layout: WorkspaceToolbarLayout,
        projectName: String?,
        projectContents: String,
        restartRequired: Bool = false,
        unmatchedCount: Int = 0,
        isRequestLogShown: Bool = true,
        isInspectorPresented: Bool = true,
        canPresentInspector: Bool = true
    ) {
        self.layout = layout
        self.projectName = projectName
        self.projectContents = projectContents
        self.restartRequired = restartRequired
        self.unmatchedCount = unmatchedCount
        self.isRequestLogShown = isRequestLogShown
        self.isInspectorPresented = isInspectorPresented
        self.canPresentInspector = canPresentInspector
    }

    /// Import and server settings need a project to act on.
    public var hasProject: Bool { projectName != nil }

    /// The panel toggles sit in the inspector's header; they come back to the toolbar only while
    /// the inspector is hidden.
    public var showsPanelToggles: Bool { !isInspectorPresented }
}

/// What the toolbar's own buttons do. Run and the server well bring their own actions.
public struct WorkspaceToolbarActions {
    public var importHAR: () -> Void
    public var importOpenAPI: () -> Void
    public var showServerSettings: () -> Void
    public var toggleRequestLog: () -> Void
    public var toggleInspector: () -> Void
    public var showUnmatched: () -> Void

    public init(
        importHAR: @escaping () -> Void,
        importOpenAPI: @escaping () -> Void,
        showServerSettings: @escaping () -> Void,
        toggleRequestLog: @escaping () -> Void,
        toggleInspector: @escaping () -> Void,
        showUnmatched: @escaping () -> Void
    ) {
        self.importHAR = importHAR
        self.importOpenAPI = importOpenAPI
        self.showServerSettings = showServerSettings
        self.toggleRequestLog = toggleRequestLog
        self.toggleInspector = toggleInspector
        self.showUnmatched = showUnmatched
    }

    /// Buttons that do nothing, for previews and the gallery.
    public static var none: WorkspaceToolbarActions {
        WorkspaceToolbarActions(
            importHAR: {}, importOpenAPI: {}, showServerSettings: {},
            toggleRequestLog: {}, toggleInspector: {}, showUnmatched: {}
        )
    }
}

/// The workspace window's toolbar over the centre column.
///
/// Run, the project, and the server's address and state lead; import and server settings trail in
/// one glass group. The panel toggles sit in the inspector's own toolbar section beside its title,
/// and come back to the end of this toolbar only while the inspector is hidden. As the centre
/// column narrows, the trailing actions fold into one "More" menu, and last of all Run joins it.
///
/// Run and the address well belong to the server section, so they arrive as views: `run` for the
/// toolbar, `runMenuItem` for the menu it folds into, and `status` for the address and state.
public struct WorkspaceToolbar<Run: View, RunMenuItem: View, Status: View>: ToolbarContent {
    let state: WorkspaceToolbarState
    let actions: WorkspaceToolbarActions
    let run: Run
    let runMenuItem: RunMenuItem
    let status: Status

    public init(
        state: WorkspaceToolbarState,
        actions: WorkspaceToolbarActions,
        @ViewBuilder run: () -> Run,
        @ViewBuilder runMenuItem: () -> RunMenuItem,
        @ViewBuilder status: () -> Status
    ) {
        self.state = state
        self.actions = actions
        self.run = run()
        self.runMenuItem = runMenuItem()
        self.status = status()
    }

    @ToolbarContentBuilder
    public var body: some ToolbarContent {
        if !state.layout.foldsRun {
            ToolbarItem(id: "workspace.run", placement: .navigation) {
                run
            }
        }

        ToolbarItem(id: "workspace.identity", placement: .navigation) {
            WorkspaceProjectIdentity(state: state)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "workspace.status", placement: .navigation) {
            // Its own item, and wrapped rather than rooted at the well's `Button`. A bare button as
            // an item's root is published as the item itself, and so is a button sharing an item
            // with other views: the project name beside it then left the accessibility tree, and
            // the well's details popover never reached it.
            WorkspaceToolbarStatus(state: state) { status }
        }
        .sharedBackgroundVisibility(.hidden)

        // The actions keep to the column's trailing edge, clear of the address.
        ToolbarSpacer(.flexible)

        ToolbarItemGroup(placement: .primaryAction) {
            if state.layout.usesOverflow {
                WorkspaceOverflowMenu(state: state, actions: actions) { runMenuItem }
                    .buttonStyle(.borderless)
                    .frame(width: WorkspaceToolbarLayout.actionWidth)
            } else {
                WorkspaceImportMenu(inToolbar: true, actions: actions)
                    .disabled(!state.hasProject)
                    .buttonStyle(.borderless)
                    .frame(width: WorkspaceToolbarLayout.actionWidth)
                WorkspaceServerSettingsButton(restartRequired: state.restartRequired,
                                              action: actions.showServerSettings)
                    .disabled(!state.hasProject)
                    .labelStyle(.iconOnly)
                    .frame(width: WorkspaceToolbarLayout.actionWidth)
            }
        }

        if !state.layout.usesOverflow, state.showsPanelToggles {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                WorkspaceRequestLogToggle(isShown: state.isRequestLogShown, action: actions.toggleRequestLog)
                    .labelStyle(.iconOnly)
                WorkspaceInspectorToggle(isPresented: state.isInspectorPresented,
                                         canPresent: state.canPresentInspector,
                                         action: actions.toggleInspector)
                    .labelStyle(.iconOnly)
            }
        }
    }
}

/// The divider before the server well, and the well itself, as the toolbar's third item.
public struct WorkspaceToolbarStatus<Status: View>: View {
    let state: WorkspaceToolbarState
    let status: Status

    public init(state: WorkspaceToolbarState, @ViewBuilder status: () -> Status) {
        self.state = state
        self.status = status()
    }

    public var body: some View {
        HStack(spacing: DSSpacing.md) {
            if !state.layout.usesCompactSummary {
                Rectangle()
                    .fill(DSColors.separator)
                    .frame(width: DSStroke.emphasis, height: 24)
                    .accessibilityHidden(true)
            }
            status
        }
        .accessibilityElement(children: .contain)
    }
}

/// The project's name over what it holds, "12 endpoints · 3 journeys". Narrow toolbars keep the
/// name alone, and with no project open it reads "Mimic".
public struct WorkspaceProjectIdentity: View {
    let state: WorkspaceToolbarState

    public init(state: WorkspaceToolbarState) {
        self.state = state
    }

    private var name: String { state.projectName ?? "Mimic" }

    public var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name)
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(name)
                .accessibilityIdentifier("toolbar.projectName")
            if !state.layout.usesCompactSummary, state.hasProject {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "rectangle.grid.1x2")
                        .font(.system(size: DSGlyph.minimum))
                        .imageScale(.small)
                        .accessibilityHidden(true)
                    Text(state.projectContents)
                }
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("toolbar.projectContents")
                .accessibilityLabel(state.projectContents)
            }
        }
        .frame(maxWidth: state.layout.projectIdentityMaximumWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        // The toolbar spaces its items 8pt apart; the design leaves 12pt either side of the name.
        .padding(.horizontal, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.projectIdentity")
    }

    /// "12 endpoints · 3 journeys".
    public nonisolated static func contents(endpoints: Int, journeys: Int) -> String {
        "\(endpoints) \(endpoints == 1 ? "endpoint" : "endpoints") · \(journeys) \(journeys == 1 ? "journey" : "journeys")"
    }
}

/// Import a HAR file or an OpenAPI spec. Shared by the full toolbar and its overflow menu.
public struct WorkspaceImportMenu: View {
    let inToolbar: Bool
    let actions: WorkspaceToolbarActions

    public init(inToolbar: Bool = false, actions: WorkspaceToolbarActions) {
        self.inToolbar = inToolbar
        self.actions = actions
    }

    public var body: some View {
        Menu {
            Button(action: actions.importHAR) {
                Label("Import HAR file\u{2026}", systemImage: "doc.text")
            }
            .accessibilityIdentifier("importHARMenuItem")
            .accessibilityLabel("Import HAR file")

            Button(action: actions.importOpenAPI) {
                Label("Import OpenAPI spec\u{2026}", systemImage: "doc.badge.gearshape")
            }
            .accessibilityIdentifier("importOpenAPIMenuItem")
            .accessibilityLabel("Import OpenAPI spec")
        } label: {
            if inToolbar {
                Label("Import", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
            } else {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        .menuIndicator(.hidden)
        .help("Import a HAR file or an OpenAPI spec")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importMenuButton")
        .accessibilityLabel("Import")
    }
}

/// Opens the server settings, and says so when the running server needs a restart to apply them.
public struct WorkspaceServerSettingsButton: View {
    let restartRequired: Bool
    let action: () -> Void

    public init(restartRequired: Bool, action: @escaping () -> Void) {
        self.restartRequired = restartRequired
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(
                restartRequired ? "Server settings, restart required" : "Server settings\u{2026}",
                // The same sliders while a restart is pending: the server line under the address
                // already says so, in the warning colour.
                systemImage: "slider.horizontal.3"
            )
        }
        .help(restartRequired ? "Restart the server to apply local port changes" : "Configure local ports and real backends")
        .accessibilityIdentifier("backend.settingsButton")
        .accessibilityLabel("Server settings")
    }
}

/// Shows or hides the request log under the centre column.
public struct WorkspaceRequestLogToggle: View {
    let isShown: Bool
    let action: () -> Void

    public init(isShown: Bool, action: @escaping () -> Void) {
        self.isShown = isShown
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(isShown ? "Hide request log" : "Show request log", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .help(isShown ? "Hide request log (⌥⌘L)" : "Show request log (⌥⌘L)")
        .accessibilityIdentifier("toggleDrawerButton")
        .accessibilityLabel(isShown ? "Hide request log" : "Show request log")
    }
}

/// Shows or hides the inspector column. Disabled while there is nothing to inspect.
public struct WorkspaceInspectorToggle: View {
    let isPresented: Bool
    let canPresent: Bool
    let action: () -> Void

    public init(isPresented: Bool, canPresent: Bool, action: @escaping () -> Void) {
        self.isPresented = isPresented
        self.canPresent = canPresent
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            Label(isPresented ? "Hide inspector" : "Show inspector", systemImage: "sidebar.right")
        }
        .disabled(!canPresent)
        .help(canPresent
            ? (isPresented ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
            : "Add an endpoint or a journey to inspect it")
        .accessibilityIdentifier("toggleInspectorButton")
        .accessibilityLabel(isPresented ? "Hide inspector" : "Show inspector")
    }
}

/// The secondary actions, folded into one menu when the centre column is narrow. At the narrowest
/// width Run/Stop leads it, so AppKit never has to hide anything. The panel toggles join it only
/// while the inspector is hidden; otherwise they sit in the inspector's header.
public struct WorkspaceOverflowMenu<RunMenuItem: View>: View {
    let state: WorkspaceToolbarState
    let actions: WorkspaceToolbarActions
    let runMenuItem: RunMenuItem

    public init(
        state: WorkspaceToolbarState,
        actions: WorkspaceToolbarActions,
        @ViewBuilder runMenuItem: () -> RunMenuItem
    ) {
        self.state = state
        self.actions = actions
        self.runMenuItem = runMenuItem()
    }

    public var body: some View {
        let unmatchedCount = state.unmatchedCount
        let unmatchedDescription = "\(unmatchedCount) unmatched \(unmatchedCount == 1 ? "request" : "requests")"
        let foldsRun = state.layout.foldsRun
        Menu {
            if foldsRun {
                runMenuItem
                Divider()
            }
            WorkspaceImportMenu(actions: actions)
                .disabled(!state.hasProject)
            WorkspaceServerSettingsButton(restartRequired: state.restartRequired, action: actions.showServerSettings)
                .disabled(!state.hasProject)
            if state.showsPanelToggles {
                Divider()
                WorkspaceRequestLogToggle(isShown: state.isRequestLogShown, action: actions.toggleRequestLog)
                WorkspaceInspectorToggle(isPresented: state.isInspectorPresented,
                                         canPresent: state.canPresentInspector,
                                         action: actions.toggleInspector)
            }
            if unmatchedCount > 0 {
                Divider()
                Button("Show unmatched requests (\(unmatchedCount))", action: actions.showUnmatched)
                    .accessibilityIdentifier("toolbar.showUnmatched")
                    .accessibilityLabel("Show unmatched requests")
            }
        } label: {
            Label("More", systemImage: state.restartRequired ? "exclamationmark.arrow.circlepath" : "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help(foldsRun ? "Run, import, server settings, and more" : "Import, server settings, and more")
        .accessibilityIdentifier("toolbar.overflow")
        .accessibilityLabel("More actions")
        .accessibilityValue(unmatchedCount > 0
            ? unmatchedDescription
            : (state.restartRequired ? "Server restart required" : ""))
    }
}
