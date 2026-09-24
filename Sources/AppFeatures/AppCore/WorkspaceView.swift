import SwiftUI
import Domain
import DesignSystem
import Persistence

/// The workspace: a full-height navigator, an editor column with the request log docked below it, and
/// a full-height inspector. Both side panels are real `NavigationSplitView`/`.inspector` columns, so
/// only the request log is a tenant of the centre.
struct WorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showInspector: Bool
    @State private var showDrawer: Bool
    @State private var selectedEndpointID: UUID?
    /// The logged requests the user has selected. Owned here rather than inside the drawer because
    /// two panels need them: the log paints the rows selected, the inspector renders the detail.
    ///
    /// A set because a selection is also how a journey is captured from a session. The inspector
    /// shows detail only when exactly one row is selected — detail is about one thing.
    @State private var selectedLogIDs: Set<UUID> = []
    /// The requests waiting to be named as a journey. Non-nil *is* "the capture sheet is up".
    @State private var pendingCapture: CaptureJourneySheet.Capture?
    /// Restricts the request log to calls nothing answered. Lives here so the toolbar's unmatched
    /// badge can turn it on from outside the panel.
    @State private var showUnmatchedOnly = false
    /// Which navigator the sidebar is showing, and therefore what the centre pane edits.
    @State private var navigatorTab: NavigatorTab = .endpoints
    @State private var endpointFilter = ""
    @State private var collapsedEndpointGroups: Set<String> = []
    @State private var endpointMethodScope = SidebarView.anyMethodScopeID
    @State private var journeyFilter = ""
    @State private var collapsedJourneyGroups: Set<String> = []
    /// Back/forward across endpoints you have looked at.
    @State private var endpointHistory = NavigationHistory<UUID>()
    /// Set while a back/forward move is in flight, so the resulting selection change is not recorded
    /// as a *new* visit — which would truncate the forward stack and make Forward unreachable the
    /// instant you used Back.
    @State private var isNavigatingHistory = false
    @State private var showHARImport = false
    @State private var showOpenAPIImport = false
    @State private var showBackendSettings = false
    #if DEBUG
    /// The result of parsing a UI test's injected file — see ``presentInjectedImportIfNeeded()``.
    /// Non-nil *is* "the injected import sheet is up", the way `pendingCapture` works.
    @State private var injectedImport: InjectedImport?
    #endif
    /// The two journey sheets, both of which used to be reachable only from the journeys window.
    @State private var showJourneyTemplatePicker = false
    @State private var showNewJourneySheet = false
    /// How tall the request log is. Two-way with `DSSplitPane`, which reports a *settled* size rather
    /// than every frame of a drag — so this can be persisted on change without writing `UserDefaults`
    /// at the pointer's sample rate, which is what the hand-rolled divider used to do.
    @State private var drawerHeight: CGFloat

    /// The editor column determines when supporting toolbar actions need overflow.
    @State private var centerToolbarWidth: CGFloat = 0

    /// Where the panels were left last time. Injected rather than read from `.standard` so a UI test
    /// run keeps its own arrangement — the same reason `RecentProjectsStore` is injected.
    private let layoutStore: PanelLayoutStore

    init(
        layoutStore: PanelLayoutStore = PanelLayoutStore(),
        initialShowInspector: Bool? = nil,
        initialShowDrawer: Bool? = nil,
        initialSelectedEndpointID: UUID? = nil,
        initialShowHARImport: Bool = false,
        initialShowOpenAPIImport: Bool = false,
        initialDrawerHeight: CGFloat? = nil
    ) {
        self.layoutStore = layoutStore
        let saved = layoutStore.load()
        _showInspector = State(initialValue: initialShowInspector ?? saved.isInspectorVisible)
        _showDrawer = State(initialValue: initialShowDrawer ?? saved.isRequestLogVisible)
        _selectedEndpointID = State(initialValue: initialSelectedEndpointID)
        _showHARImport = State(initialValue: initialShowHARImport)
        _showOpenAPIImport = State(initialValue: initialShowOpenAPIImport)
        _drawerHeight = State(initialValue: initialDrawerHeight ?? saved.requestLogHeight)
    }

    /// Writes the current arrangement back. Called on each change rather than at quit, because a
    /// crash or a force-quit should not be the thing that loses your layout.
    ///
    /// The inspector is absent on purpose. It is a real `.inspector` column and AppKit restores its
    /// width with the window, so a copy kept here would be a second, staler answer to a question
    /// something else already owns — which is exactly what `panel.inspector.width` had become.
    private func persistLayout() {
        layoutStore.save(
            PanelLayout(
                requestLogHeight: drawerHeight,
                isRequestLogVisible: showDrawer,
                isInspectorVisible: showInspector
            )
        )
    }

    private var workspaceLayout: some View {
        VStack(spacing: 0) {
            NavigationSplitView {
                navigator
                    .navigationSplitViewColumnWidth(
                        min: DSNavigatorMetrics.minimumWidth,
                        ideal: DSNavigatorMetrics.idealWidth,
                        max: DSNavigatorMetrics.maximumWidth
                    )
                    // `.contain` matters: a bare `.accessibilityIdentifier` on a container *overrides*
                    // its descendants' identifiers. The search field survived this only because it used
                    // to live inside a `List`, whose rows form their own accessibility elements; once it
                    // was pinned above the list it inherited "sidebar" and `sidebar.searchField`
                    // disappeared from the tree. Declaring a container keeps both.
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("sidebar")
            } detail: {
                // Xcode's arrangement, and for Xcode's reason. Both side panels own their full
                // column top to bottom; the bottom panel is a tenant of the centre column only.
                //
                // Mimic had the inverse: the request log spanned the whole detail column, so the
                // inspector had to stop short to make room for it. With the log at its default 220pt
                // that cost the inspector 220pt of height — taken from the one panel whose job is
                // showing you a payload, and given to a log that was not using the corner.
                VStack(spacing: 0) {
                    // Xcode's jump bar. Sits above the editor area rather than inside any one
                    // editor, because it describes where you are, not what you are editing.
                    BreadcrumbJumpBar(
                        crumbs: breadcrumbs,
                        canGoBack: endpointHistory.canGoBack,
                        canGoForward: endpointHistory.canGoForward,
                        onSelectOption: handleBreadcrumbSelection,
                        onBack: {
                            if let previous = endpointHistory.goBack() {
                                isNavigatingHistory = true
                                selectedEndpointID = previous
                            }
                        },
                        onForward: {
                            if let next = endpointHistory.goForward() {
                                isNavigatingHistory = true
                                selectedEndpointID = next
                            }
                        }
                    )

                    // The pair that shares the space below the jump bar, as one `NSSplitViewItem`
                    // pair — so the divider between them is the same divider the navigator and the
                    // inspector already wear, and the centre pane's floor is a constraint AppKit
                    // enforces rather than a ceiling this view recomputes from a measured container.
                    DSSplitPane(
                        axis: .vertical,
                        isSecondaryPresented: $showDrawer,
                        secondaryThickness: $drawerHeight,
                        minimumPrimaryThickness: PanelLayoutStore.Bounds.minimumCentreHeight,
                        minimumSecondaryThickness: PanelLayoutStore.Bounds.minimumRequestLogHeight,
                        defaultSecondaryThickness: PanelLayout.default.requestLogHeight,
                        identifier: "requestLog"
                    ) {
                        CenterPaneView(
                            content: CenterPaneContent.forTab(
                                navigatorTab,
                                endpointID: selectedEndpointID,
                                journeyID: appState.selectedJourneyID
                            )
                        )
                        // Anchored to the top, not centred. A pane is exactly as tall as the split
                        // view gives it, and an editor taller than that — the journey editor has no
                        // scroll view — is centred by default, which pushes its *first* row above the
                        // pane and out of sight under the toolbar. That row carries "Add step", so on
                        // a short window the control was drawn nowhere and clicked nothing: two UI
                        // tests failed on it, and a user with a small window would have seen the same.
                        // Clipping the bottom of a long editor is recoverable; losing the top is not.
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        // Re-injected because the pane is hosted: `NSHostingController` starts a new
                        // SwiftUI hierarchy, and `@Environment` does not cross that boundary. Without
                        // this the editor traps on a missing `AppState` the moment it appears.
                        .environment(appState)
                        // Paired, like every other container identifier in this window. Naming a
                        // container without `.contain` renames every descendant, which would take
                        // the whole editor out of the accessibility tree.
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("centerPane")
                    } secondary: {
                        requestLogPanel
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { centerToolbarWidth = $0 }
                // Editor actions belong to this column, before the inspector divides the toolbar.
                .toolbar { workspaceToolbar }
            }
            .navigationSplitViewStyle(.balanced)
            // Outside the navigation structure, the inspector owns a full-height column and its
            // own toolbar section. Nesting it in the detail column merges both action groups.
            .inspector(isPresented: $showInspector) {
                inspectorPanel
                    .inspectorColumnWidth(
                        min: PanelLayoutStore.Bounds.minimumInspectorWidth,
                        ideal: PanelLayoutStore.Bounds.idealInspectorWidth,
                        max: 640
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("inspector")
                    .toolbar { panelToolbar }
            }
        }
    }

    private var workspaceWithToolbar: some View {
        workspaceLayout
            .toolbar(removing: .title)
    }

    var body: some View {
        @Bindable var appState = appState

        workspaceWithToolbar
        // Port conflict alert
        // `String(...)` around the port, not the bare `Int`. This first argument is a
        // `LocalizedStringKey`, so an interpolated integer is formatted for the current locale and
        // picks up a grouping separator: the alert read "Port 21,311 already in use". A port is an
        // identifier, not a quantity — there is no such port as 21,311, and the number a user would
        // have to retype is not the one the window showed them. Interpolating a `String` gives the
        // key a piece of text to place rather than a number to format.
        .alert(
            "Port \(String(appState.portConflictAlert?.conflictingPort ?? 0)) already in use",
            isPresented: $appState.isShowingPortConflict,
            presenting: appState.portConflictAlert
        ) { alertData in
            if let suggestedPort = alertData.suggestedPort {
                Button("Try port \(String(suggestedPort))") {
                    appState.retryStartOnNextPort(from: alertData.conflictingPort)
                }
                .accessibilityIdentifier("portConflict.tryPortButton")
                .accessibilityLabel("Try port \(String(suggestedPort))")
            }

            Button("Keep server stopped", role: .cancel) {
                appState.portConflictAlert = nil
            }
            .accessibilityIdentifier("portConflict.keepStoppedButton")
            .accessibilityLabel("Keep server stopped")
        } message: { alertData in
            Text(verbatim: alertData.suggestedPort.map {
                "Another process is using port \(alertData.conflictingPort). Try port \($0) instead?"
            } ?? "Another process is using port \(alertData.conflictingPort). No higher port is available.")
                // Named, not matched as a substring. The body interpolates two ports, so the only
                // query that could reach it without an identifier is a `CONTAINS` predicate over the
                // window's static texts — which is both expensive and satisfied by any other text
                // that happens to mention a port.
                .accessibilityIdentifier("portConflict.message")
        }
        // New endpoint sheet
        .sheet(isPresented: $appState.showNewEndpointSheet) {
            NewEndpointSheet { name, method, path in
                if let endpoint = appState.addEndpoint(name: name, method: method, path: path) {
                    revealEndpoint(endpoint)
                }
            }
        }
        // Generic server error alert
        .alert(
            "Server error",
            isPresented: $appState.isShowingGenericStartError,
            presenting: appState.genericStartError
        ) { _ in
            // Distinct from `commandError.okButton` in `ContentView`, which is also called "OK" and
            // is also presented over this window. Two dismiss buttons with one name is a query that
            // matches whichever alert AppKit listed first, so a test could confirm a server error by
            // dismissing a validation refusal.
            Button("OK") { appState.genericStartError = nil }
                .accessibilityIdentifier("serverError.okButton")
                .accessibilityLabel("OK")
        } message: { error in
            Text(error)
                // The message is whatever the runtime threw, so there is no literal to match on.
                .accessibilityIdentifier("serverError.message")
        }
        // HAR import sheet
        .sheet(isPresented: $showHARImport) {
            ImportView(
                kind: .har,
                existingEndpoints: currentEndpoints,
                onCommitImport: appState.commitImportedCandidates
            )
        }
        .sheet(isPresented: $showBackendSettings) {
            BackendSettingsView(configuration: appState.serverConfiguration)
                .environment(appState)
        }
        // OpenAPI import sheet
        .sheet(isPresented: $showOpenAPIImport) {
            ImportView(
                kind: .openAPI,
                existingEndpoints: currentEndpoints,
                onCommitImport: appState.commitImportedCandidates
            )
        }
        // Both moved here from the journeys window, which was their only presenter.
        .sheet(isPresented: $showNewJourneySheet) {
            NewJourneySheet { name in
                if let journey = appState.addJourney(name: name) {
                    appState.selectedJourneyID = journey.id
                    navigatorTab = .journeys
                }
            }
        }
        .sheet(isPresented: $showJourneyTemplatePicker) {
            JourneyTemplatePicker { templateID, activate in
                guard let journey = appState.addJourney(fromTemplate: templateID) else { return }
                appState.selectedJourneyID = journey.id
                navigatorTab = .journeys
                if activate { appState.activateJourney(id: journey.id) }
            }
        }
        // Naming happens before the journey exists, which is what the menu item's ellipsis has always
        // promised. It used to create one silently with a derived name.
        .sheet(item: $pendingCapture) { capture in
            CaptureJourneySheet(capture: capture) { name, logs in
                guard let journey = appState.addJourney(name: name, capturing: logs) else { return }
                appState.selectedJourneyID = journey.id
                navigatorTab = .journeys
            }
        }
        // Selecting a request shows it in the inspector, so the inspector has to be open. Without
        // this, clicking a row in the log looks like it does nothing at all whenever the panel
        // happens to be collapsed.
        .onChange(of: selectedLogIDs) { _, newValue in
            guard !newValue.isEmpty, !showInspector else { return }
            withAnimation(reduceMotion ? nil : DSAnimation.drawerToggle) {
                showInspector = true
            }
        }
        // The inspector shows one thing at a time, so the newer selection wins. Picking an endpoint
        // while a request is up should show that endpoint — not silently lose the click.
        .onChange(of: selectedEndpointID) { _, newValue in
            guard let newValue else { return }
            selectedLogIDs = []
            guard !isNavigatingHistory else {
                isNavigatingHistory = false
                return
            }
            endpointHistory.visit(newValue)
        }
        .onChange(of: navigatorTab) { _, _ in selectedLogIDs = [] }
        .onChange(of: appState.selectedJourneyID) { _, _ in selectedLogIDs = [] }
        // A cleared log takes its selection with it; otherwise the inspector goes on showing a
        // request that is no longer in the list.
        .onChange(of: appState.requestLogs.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            selectedLogIDs = []
        }
        // Panel arrangement is a preference, so it is written as it changes.
        .onChange(of: drawerHeight) { _, _ in persistLayout() }
        .onChange(of: showDrawer) { _, _ in persistLayout() }
        .onChange(of: showInspector) { _, _ in persistLayout() }
        // ⌘1 / ⌘2 from the menu bar, which lives above this window and so cannot bind to its state.
        // Journeys ▸ Show Journeys arrives the same way, now that it selects a tab rather than
        // opening a window.
        .onChange(of: appState.navigatorRequest) { _, requested in
            guard let requested else { return }
            navigatorTab = requested
            appState.navigatorRequest = nil
        }
        // Last in the chain, like the only other postfix `#if` in this app (`MimicScene`), and for
        // the same reason: everything inside it has to vanish in Release, and a conditional block at
        // the end of a modifier chain is the shape that is unambiguously allowed to.
        #if DEBUG
        // The same sheet the Import menu presents, on a file a UI test named instead of one an
        // `NSOpenPanel` returned. Separate from the two presentations above rather than folded into
        // them, so nothing about the shipping import path changes to accommodate a test.
        .sheet(item: $injectedImport) { injected in
            ImportView(
                kind: injected.kind,
                existingEndpoints: currentEndpoints,
                initialCandidates: injected.state.candidates,
                initialParseError: injected.state.parseError,
                initialIsParsing: injected.state.isParsing,
                onCommitImport: appState.commitImportedCandidates
            )
        }
        .task { await presentInjectedImportIfNeeded() }
        #endif
    }

    // MARK: - Toolbar

    /// Preserve project identity and server context; only editor actions move into overflow.
    nonisolated static func toolbarUsesOverflow(centerWidth: CGFloat) -> Bool {
        !centerWidth.isFinite || centerWidth < DSToolbarGeometry.expandedCenterWidth
    }

    private var usesToolbarOverflow: Bool {
        Self.toolbarUsesOverflow(centerWidth: centerToolbarWidth)
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItem(id: "workspace.run", placement: .navigation) {
            ServerToggleButton(
                serverState: appState.serverState,
                onStart: appState.startServer,
                onStop: appState.stopServer
            )
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "workspace.identityAndServer", placement: .navigation) {
            HStack(spacing: usesToolbarOverflow ? DSSpacing.sm : DSSpacing.md) {
                projectIdentity
                Rectangle()
                    .fill(DSColors.border)
                    .frame(width: DSStroke.seam, height: DSSpacing.xl)
                    .accessibilityHidden(true)
                serverSummary
            }
            .fixedSize(horizontal: true, vertical: false)
            .accessibilityElement(children: .contain)
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarSpacer(.flexible, placement: .primaryAction)
        // Keep one native group installed when the workspace first opens in compact mode.
        ToolbarItemGroup(placement: .primaryAction) {
            if usesToolbarOverflow {
                overflowMenu
            } else {
                importMenu(inToolbar: true)
                serverSettingsButton.labelStyle(.iconOnly)
            }
        }
    }

    private var projectIdentity: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xxs) {
            Text(appState.currentProject?.name ?? "Mimic")
                .font(DSTypography.bodyBold)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(appState.currentProject?.name ?? "Mimic")
                .accessibilityIdentifier("toolbar.projectName")
            ZStack(alignment: .leading) {
                Label {
                    Text("Local mock").font(DSTypography.label)
                } icon: {
                    Image(systemName: "desktopcomputer")
                        .font(.system(size: DSGlyph.inline, weight: .regular))
                }
                .labelStyle(.titleAndIcon)
                .foregroundStyle(DSColors.labelSecondary)
                .opacity(appState.autosaveStatus == .idle ? 1 : 0)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("toolbar.projectKind")
                .accessibilityLabel("Local mock")
                .accessibilityHidden(appState.autosaveStatus != .idle)
                AutosaveStatusIndicator(status: appState.autosaveStatus)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: DSToolbarGeometry.metadataHeight, alignment: .leading)
        }
        .frame(maxWidth: usesToolbarOverflow
            ? DSToolbarGeometry.compactProjectTitleWidth : DSToolbarGeometry.projectTitleWidth,
               alignment: .leading)
        .frame(height: DSToolbarGeometry.height, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.projectIdentity")
    }

    private var serverSummary: some View {
        ServerStatusWell(
            serverState: appState.serverState,
            projectName: appState.currentProject?.name,
            requestCount: appState.requestLogs.count,
            unmatchedCount: RequestLogQuery.unmatchedCount(logs: appState.requestLogs),
            compact: usesToolbarOverflow,
            configuration: appState.currentProject?.serverConfiguration,
            boundConfiguration: appState.server.boundConfiguration,
            onShowUnmatched: {
                showDrawer = true
                showUnmatchedOnly = true
            },
            onShowSettings: { showBackendSettings = true },
            onShowTraffic: {
                showDrawer = true
                showUnmatchedOnly = false
            }
        )
        .frame(width: usesToolbarOverflow
            ? DSToolbarGeometry.compactStatusWidth : DSToolbarGeometry.statusWidth)
    }

    @ToolbarContentBuilder
    private var panelToolbar: some ToolbarContent {
        ToolbarSpacer(.flexible, placement: .primaryAction)
        ToolbarItemGroup(placement: .primaryAction) {
            drawerToolbarButton.labelStyle(.iconOnly)
            inspectorToolbarButton.labelStyle(.iconOnly)
        }
    }

    private var overflowMenu: some View {
        let unmatchedCount = RequestLogQuery.unmatchedCount(logs: appState.requestLogs)
        let unmatchedDescription = "\(unmatchedCount) unmatched \(unmatchedCount == 1 ? "request" : "requests")"
        return Menu {
            importMenu()
            serverSettingsButton
            if !appState.requestLogs.isEmpty {
                Divider()
                Button("Show unmatched requests (\(unmatchedCount))") {
                    showDrawer = true
                    showUnmatchedOnly = true
                }
                .accessibilityIdentifier("toolbar.showUnmatched")
                .accessibilityLabel("Show unmatched requests")
            }
        } label: {
            Label("More actions", systemImage: appState.server.restartRequired
                  ? "exclamationmark.arrow.circlepath" : "chevron.forward.2")
                .labelStyle(.iconOnly)
                .font(.system(size: DSGlyph.toolbar, weight: .regular))
        }
        .menuStyle(.button)
        .menuIndicator(.hidden)
        // A native toolbar otherwise measures this menu as zero on the first compact layout.
        .frame(width: DSToolbarGeometry.height, height: DSToolbarGeometry.height)
        .help(unmatchedCount > 0
            ? "More actions; \(unmatchedDescription)"
            : "More actions: import and server settings")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("toolbar.overflow")
        .accessibilityLabel("More actions")
        .accessibilityValue(unmatchedCount > 0
            ? unmatchedDescription
            : (appState.server.restartRequired ? "Server restart required" : ""))
    }

    private var serverSettingsButton: some View {
        Button { showBackendSettings = true } label: {
            Label(
                appState.server.restartRequired ? "Server settings — restart required" : "Server settings",
                systemImage: appState.server.restartRequired ? "exclamationmark.arrow.circlepath" : "server.rack"
            )
        }
        .font(.system(size: DSGlyph.toolbar, weight: .regular))
        .disabled(appState.currentProject == nil)
        .help(appState.server.restartRequired ? "Restart the server to apply local port changes" : "Configure local ports and real backends")
        .accessibilityIdentifier("backend.settingsButton")
        .accessibilityLabel("Server settings")
    }

    private var inspectorPresentation: Binding<Bool> {
        Binding(
            get: { showInspector },
            set: { value in
                withAnimation(reduceMotion ? nil : DSAnimation.drawerToggle) { showInspector = value }
            }
        )
    }

    private var drawerToolbarButton: some View {
        Button { showDrawer.toggle() } label: {
            Label(showDrawer ? "Hide request log" : "Show request log", systemImage: "rectangle.bottomhalf.inset.filled")
        }
        .font(.system(size: DSGlyph.toolbar, weight: .regular))
        .keyboardShortcut("l", modifiers: [.command, .option])
        .help(showDrawer ? "Hide request log (⌥⌘L)" : "Show request log (⌥⌘L)")
        .accessibilityIdentifier("toggleDrawerButton")
        .accessibilityLabel(showDrawer ? "Hide request log" : "Show request log")
    }

    private var inspectorToolbarButton: some View {
        Button { inspectorPresentation.wrappedValue.toggle() } label: {
            Label(showInspector ? "Hide inspector" : "Show inspector", systemImage: "sidebar.right")
        }
        .font(.system(size: DSGlyph.toolbar, weight: .regular))
        .keyboardShortcut("i", modifiers: [.command, .option])
        .help(showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
        .accessibilityIdentifier("toggleInspectorButton")
        .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
    }

    /// Shared by the full toolbar and its compact overflow menu.
    private func importMenu(inToolbar: Bool = false) -> some View {
        Menu {
            Button { showHARImport = true } label: {
                Label("Import HAR file\u{2026}", systemImage: "doc.text")
            }
            .accessibilityIdentifier("importHARMenuItem")
            .accessibilityLabel("Import HAR file")

            Button { showOpenAPIImport = true } label: {
                Label("Import OpenAPI spec\u{2026}", systemImage: "doc.badge.gearshape")
            }
            .accessibilityIdentifier("importOpenAPIMenuItem")
            .accessibilityLabel("Import OpenAPI spec")
        } label: {
            if inToolbar {
                Label("Import", systemImage: "square.and.arrow.down")
                    .labelStyle(.iconOnly)
                    .font(.system(size: DSGlyph.toolbar, weight: .regular))
            } else {
                Label("Import", systemImage: "square.and.arrow.down")
            }
        }
        .menuIndicator(.hidden)
        .disabled(appState.currentProject == nil)
        .help("Import a HAR file or an OpenAPI spec")
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("importMenuButton")
        .accessibilityLabel("Import")
    }

    // MARK: - Breadcrumb

    /// Where you are, as a trail you can steer with.
    ///
    /// Every level past the first is a menu over its siblings, so moving to another endpoint in the
    /// same group — or another scenario on this endpoint — never means a round trip to the sidebar.
    private var breadcrumbs: [BreadcrumbJumpBar.Crumb] {
        var crumbs: [BreadcrumbJumpBar.Crumb] = [
            BreadcrumbJumpBar.Crumb(
                id: "project",
                title: appState.currentProject?.name ?? "Mimic",
                systemImage: "shippingbox"
            )
        ]

        switch navigatorTab {
        case .journeys:
            let journeys = appState.journeys
            crumbs.append(
                BreadcrumbJumpBar.Crumb(
                    id: "journey",
                    // The centre editor gives the selected journey its full title. Keep this jump
                    // control short so it does not repeat and truncate that title above the editor.
                    title: "Journeys",
                    // From `NavigatorTab`, not spelled out here: this crumb sits one bar below the
                    // tab whose glyph it is repeating, and a literal is how the five empty states
                    // `NavigatorTab.systemImage` was extracted for came to disagree with it in the
                    // first place. Same value it already carried, now from the one place that picks it.
                    systemImage: NavigatorTab.journeys.systemImage,
                    options: journeys.map {
                        BreadcrumbJumpBar.Option(
                            id: $0.id,
                            title: $0.name,
                            isSelected: $0.id == appState.selectedJourneyID
                        )
                    }
                )
            )

        case .endpoints:
            let endpoints = currentEndpoints
            guard let endpoint = endpoints.first(where: { $0.id == selectedEndpointID }) else {
                crumbs.append(BreadcrumbJumpBar.Crumb(id: "endpoint", title: "No endpoint"))
                return crumbs
            }

            // The group crumb only earns its place when there are groups to move between.
            let groups = Set(endpoints.compactMap(\.groupTag).filter { !$0.isEmpty }).sorted()
            if let group = endpoint.groupTag, !group.isEmpty, groups.count > 1 {
                crumbs.append(
                    BreadcrumbJumpBar.Crumb(
                        id: "group",
                        title: group,
                        options: groups.compactMap { name in
                            // A group is not a thing you can select, so each option stands for the
                            // first endpoint in it — the same landing a sidebar click would give.
                            endpoints.first { $0.groupTag == name }.map {
                                BreadcrumbJumpBar.Option(id: $0.id, title: name, isSelected: name == group)
                            }
                        }
                    )
                )
            }

            let siblings = endpoints.filter { $0.groupTag == endpoint.groupTag }
            crumbs.append(
                BreadcrumbJumpBar.Crumb(
                    id: "endpoint",
                    title: endpoint.name,
                    options: siblings.map {
                        BreadcrumbJumpBar.Option(id: $0.id, title: $0.name, isSelected: $0.id == endpoint.id)
                    }
                )
            )

            if !endpoint.scenarios.isEmpty {
                crumbs.append(
                    BreadcrumbJumpBar.Crumb(
                        id: "scenario",
                        title: endpoint.scenarios.first { $0.id == endpoint.activeScenarioID }?.name
                            ?? "No scenario",
                        options: endpoint.scenarios.map {
                            BreadcrumbJumpBar.Option(
                                id: $0.id,
                                title: $0.name,
                                isSelected: $0.id == endpoint.activeScenarioID
                            )
                        }
                    )
                )
            }
        }

        return crumbs
    }

    private func handleBreadcrumbSelection(crumbID: String, optionID: UUID) {
        switch crumbID {
        case "group", "endpoint":
            selectedEndpointID = optionID
        case "scenario":
            guard let endpointID = selectedEndpointID else { return }
            appState.setActiveScenario(endpointID: endpointID, scenarioID: optionID)
        case "journey":
            appState.selectedJourneyID = optionID
        default:
            break
        }
    }

    // MARK: - Navigator

    /// The navigator's "+" on the Journeys tab.
    ///
    /// `DSIconMenu` rather than `DSPanelHeaderButton`, because that type is a `Button` and this has
    /// to be a `Menu`. The geometry used to be *copied* — 22pt target, 13pt glyph, `sm` well,
    /// `labelSecondary` → `labelPrimary` on hover — and the note here said so, naming
    /// `EndpointEditorView.moreMenu` as the other block with the same shape. That is a coupling
    /// asserted in prose across two modules' worth of call sites and checked by nobody, which is the
    /// thing `DSControlHeight` was extracted to stop. The component is where the agreement lives now.
    private var addJourneyMenu: some View {
        DSIconMenu(
            systemImage: "plus",
            help: "Add a journey",
            // Neither the tooltip's words nor the empty state's, and that is the whole point. This
            // control *opens a chooser* — a new empty journey, or one built from a template — while
            // `JourneyNavigatorList`'s empty state offers "Add journey" and creates one outright.
            // Both used to answer to "Add journey": VoiceOver named two different actions
            // identically, and `JourneyUITests` was left telling them apart by AppKit element type,
            // a `MenuButton` here against a `Button` there. Element type is not identity — it is a
            // property of the menu *style* — so modernising `DSIconMenu` off the deprecated
            // `.menuStyle(.borderlessButton)` would have repointed the suite's query at the empty
            // state's button, where every wait for a menu item would then time out. Both the label
            // and the menu's own identifier now remain available to assistive technology and tests.
            label: "Choose how to add a journey",
            identifier: "journeys.addJourneyButton"
        ) {
            // Opens a naming sheet rather than creating a "New journey" outright, which is what the
            // Endpoints tab's "+" does with `NewEndpointSheet` — and what the journeys window did
            // before it was removed. Creating it unnamed made this the one add action in the app that
            // did not ask, and it orphaned `NewJourneySheet` entirely. Hence the ellipsis.
            Button {
                showNewJourneySheet = true
            } label: {
                Label("New empty journey\u{2026}", systemImage: "plus")
            }
            .accessibilityIdentifier("journeys.newEmptyMenuItem")
            .accessibilityLabel("New empty journey")

            Button {
                showJourneyTemplatePicker = true
            } label: {
                Label("Add from template\u{2026}", systemImage: "sparkles")
            }
            .accessibilityIdentifier("journeys.templateMenuItem")
            .accessibilityLabel("Add journey from template")
        }
    }

    /// One navigator shell with a native mode picker, shared row geometry, and a pinned filter.
    @ViewBuilder
    private var navigator: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            DSNavigatorHeader(
                modes: NavigatorTab.allCases.map {
                    DSNavigatorMode(id: $0.id, title: $0.title, help: $0.help)
                },
                selection: navigatorTabBinding
            ) {
                switch navigatorTab {
                case .endpoints:
                    DSPanelHeaderButton(
                        systemImage: "plus",
                        help: "Add endpoint",
                        identifier: "sidebar.addEndpointButton"
                    ) {
                        appState.showNewEndpointSheet = true
                    }
                case .journeys:
                    // A menu, not a button, because there are two ways to start a journey and the
                    // templates were the ones about to be stranded: they had no entry point outside
                    // the journeys window, so removing that window would have removed the feature.
                    // The window offered exactly this menu from its own "+".
                    addJourneyMenu
                }
            }

            Group {
                switch navigatorTab {
                case .endpoints:
                    SidebarView(
                        projectName: appState.currentProject?.name,
                        endpoints: currentEndpoints,
                        selectedEndpointID: $selectedEndpointID,
                        onDeleteEndpoint: appState.deleteEndpoint,
                        onDuplicateEndpoint: { appState.duplicateEndpoint(id: $0)?.id },
                        onAddEndpoint: { appState.showNewEndpointSheet = true },
                        searchText: $endpointFilter,
                        methodScopeID: $endpointMethodScope,
                        collapsedSections: $collapsedEndpointGroups
                    )
                case .journeys:
                    JourneyNavigatorList(
                        journeys: appState.journeys,
                        activeJourneyID: appState.activeJourney?.id,
                        selectedJourneyID: $appState.selectedJourneyID,
                        onActivate: appState.activateJourney,
                        onAdd: {
                            if let journey = appState.addJourney(name: "New journey") {
                                appState.selectedJourneyID = journey.id
                            }
                        },
                        onDuplicate: { _ = appState.duplicateJourney(id: $0) },
                        onDelete: appState.deleteJourney,
                        searchText: journeyFilter,
                        collapsedGroups: $collapsedJourneyGroups
                    )
                }
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            DSNavigatorFooter(
                text: navigatorTab == .endpoints ? $endpointFilter : $journeyFilter,
                scopeID: $endpointMethodScope,
                scopes: navigatorTab == .endpoints ? SidebarView.methodScopes : [],
                placeholder: navigatorTab == .endpoints ? "Filter endpoints" : "Filter journeys",
                identifier: navigatorTab == .endpoints ? "sidebar.filter" : "journeys.filter",
                showsStatus: appState.activeJourney != nil
            ) {
                if let active = appState.activeJourney {
                    DSPanelHeaderButton(
                        systemImage: "play.circle.fill",
                        help: "Show active journey: \(active.name)",
                        identifier: "navigator.activeJourney",
                        tint: DSColors.accent
                    ) {
                        journeyFilter = ""
                        if let group = active.groupTag {
                            collapsedJourneyGroups.remove(JourneyNavigatorList.groupSectionKey(group))
                        }
                        navigatorTab = .journeys
                        appState.selectedJourneyID = active.id
                    }
                    .accessibilityValue("\(active.name), \(activeJourneyProgress ?? "Active")")
                }
            }
        }
    }

    /// The navigator picker speaks in raw ids so it can stay in the design system without knowing what a
    /// navigator is; this keeps the enum on this side of that boundary.
    private var navigatorTabBinding: Binding<String> {
        Binding(
            get: { navigatorTab.id },
            set: { navigatorTab = NavigatorTab(rawValue: $0) ?? .endpoints }
        )
    }

    private var activeJourneyProgress: String? {
        guard let status = appState.activeJourneyStatus else { return nil }
        return status.isComplete
            ? "Complete"
            : "Step \((status.currentStepIndex ?? 0) + 1) of \(status.totalSteps)"
    }

    // MARK: - Request log wiring

    @ViewBuilder
    private var requestLogPanel: some View {
        RequestLogDrawerView(
            requestLogs: appState.requestLogs,
            endpoints: currentEndpoints,
            onClear: { appState.requestLogs = [] },
            selectedLogIDs: $selectedLogIDs,
            unmatchedOnly: $showUnmatchedOnly,
            onCreateEndpoint: { method, path in
                if let endpoint = appState.addEndpoint(
                    name: "\(method.rawValue) \(path)",
                    method: method,
                    path: path
                ) {
                    revealEndpoint(endpoint)
                }
            },
            onSaveAsMock: { id in
                if let endpoint = appState.savePassedThroughLogAsMock(id: id) {
                    revealEndpoint(endpoint)
                }
            },
            journeys: appState.journeys,
            onAddToJourney: { logs, journeyID in
                guard let journey = appState.addJourneySteps(journeyID: journeyID, capturing: logs) else { return }
                // Appending to an existing journey shows it too. Without this, capturing eight calls
                // into a journey you cannot see is indistinguishable from having captured nothing.
                appState.selectedJourneyID = journey.id
                navigatorTab = .journeys
            },
            // Capturing into a brand-new journey names it first — the sheet then shows the journey,
            // or the command reads as having done nothing.
            onAddToNewJourney: { logs in
                pendingCapture = CaptureJourneySheet.Capture(
                    logs: logs,
                    suggestedName: AppState.journeyName(capturing: logs),
                    stepCount: AppState.capturedStepCount(logs)
                )
            }
        )
        .accessibilityElement(children: .contain)
            .accessibilityIdentifier("drawer")
    }

    // MARK: - Inspector wiring

    @ViewBuilder
    private var inspectorPanel: some View {
        let endpoint: Endpoint? = {
            guard navigatorTab == .endpoints, let id = selectedEndpointID else { return nil }
            return appState.currentProject?.endpoints.first { $0.id == id }
        }()
        let detail = requestDetailContext
        let selectedJourney = navigatorTab == .journeys
            ? appState.journeys.first { $0.id == appState.selectedJourneyID } : nil

        InspectorPanelView(
            endpoint: endpoint,
            requestDetail: detail,
            overview: endpoint == nil && detail == nil ? inspectorOverview : nil,
            journey: selectedJourney.map {
                JourneyInspector.Context(selected: $0, active: appState.activeJourney,
                                         progress: activeJourneyProgress, serverState: appState.serverState)
            },
            selectedRequestCount: selectedLogIDs.count,
            endpointTraffic: endpoint.map {
                EndpointTrafficQuery.logs(forEndpoint: $0.id, in: appState.requestLogs)
            } ?? [],
            onShowJourneys: { navigatorTab = .journeys },
            onCloseRequestDetail: { selectedLogIDs = [] },
            onSelectTrafficLog: { selectedLogIDs = [$0] },
            onAddScenario: { _ = appState.addScenario(endpointID: $0, name: $1) },
            onSetActiveScenario: appState.setActiveScenario,
            onDuplicateScenario: { _ = appState.duplicateScenario(endpointID: $0, scenarioID: $1) },
            onDeleteScenario: appState.deleteScenario,
            onSaveAsMock: { id in
                if let endpoint = appState.savePassedThroughLogAsMock(id: id) {
                    revealEndpoint(endpoint)
                }
            }
        )
    }

    /// Creating a mock from traffic should reveal what was created even when Journeys is open.
    private func revealEndpoint(_ endpoint: Endpoint) {
        navigatorTab = .endpoints
        selectedEndpointID = endpoint.id
        selectedLogIDs = []
    }

    /// The selected request, resolved against the current project so the endpoint and scenario names
    /// track renames rather than showing whatever they were called when the call arrived.
    private var requestDetailContext: RequestDetailInspector.Context? {
        // Exactly one, not "the first of several": a detail panel showing one arbitrary member of a
        // multi-row selection would claim to be about a selection it is only a fraction of. With
        // several rows picked the inspector falls back to the overview.
        guard selectedLogIDs.count == 1,
              let selectedLogID = selectedLogIDs.first,
              let log = appState.requestLogs.first(where: { $0.id == selectedLogID })
        else { return nil }

        let endpoints = currentEndpoints
        return RequestDetailInspector.Context(
            log: log,
            endpointName: RequestLogQuery.endpointName(for: log.matchedEndpointID, endpoints: endpoints),
            scenarioName: RequestLogQuery.scenarioName(
                endpointID: log.matchedEndpointID,
                scenarioID: log.matchedScenarioID,
                endpoints: endpoints
            ),
            port: log.listenerPort ?? appState.serverState.runningPort
        )
    }

    /// Project-level facts for the inspector's no-selection state.
    private var inspectorOverview: InspectorOverview.Summary {
        let project = appState.currentProject
        let endpoints = currentEndpoints
        let status = appState.activeJourneyStatus
        return InspectorOverview.Summary(
            projectName: project?.name ?? "Mimic",
            serverState: appState.serverState,
            port: project?.serverConfiguration.port ?? 0,
            endpointCount: endpoints.count,
            scenarioCount: endpoints.reduce(0) { $0 + $1.scenarios.count },
            journeyCount: appState.journeys.count,
            activeJourneyName: appState.activeJourney?.name,
            activeJourneyProgress: status.map { status in
                status.isComplete
                    ? "Complete"
                    : "Step \((status.currentStepIndex ?? 0) + 1) of \(status.totalSteps)"
            },
            requestCount: appState.requestLogs.count,
            unmatchedCount: appState.requestLogs.count { $0.outcome.isMissingConfiguration }
        )
    }

    private var currentEndpoints: [Endpoint] {
        appState.currentProject?.endpoints ?? []
    }

    #if DEBUG

    // MARK: - Injected spec import (UI tests only)

    /// A parsed injection, and the sheet's presentation state in one value — non-nil *is* "show it",
    /// which is how `pendingCapture` presents the capture sheet a few modifiers above.
    private struct InjectedImport: Identifiable {
        let id = UUID()
        let kind: ImportKind
        let state: ImportWorkflowState
    }

    /// Parses the file `MIMIC_IMPORT_FILE` names and opens the import review sheet on the result.
    ///
    /// Spec import is the one workflow with no `ControlCommand` behind it, so a script cannot set it
    /// up — and its only entry point is `NSOpenPanel`, which XCUITest cannot drive at all. The review
    /// screen, the candidate list, the select-all pair, the per-route toggles and the commit were
    /// therefore unreachable to the suite: about fifty steps of UI with no way in. This is the way
    /// in, and it bypasses **only** the panel.
    ///
    /// Everything after the file name is production code. `ImportWorkflow.parseFile` is the same
    /// method `chooseFile` calls once the panel has returned a URL — it was already injectable, which
    /// is why nothing in `ImportFeature` had to change — so the real `HARParser`/`OpenAPIParser` runs
    /// over the real bytes, the sheet lists the candidates that parse produced, and confirming it
    /// calls `AppState.commitImportedCandidates` exactly as the menu path does. Handing the sheet a
    /// list of candidates built here instead would be a fixture made from the mechanism under test:
    /// it would stay green with both parsers deleted.
    ///
    /// The parse is awaited before the sheet is presented rather than driven from inside it, because
    /// `ImportWorkflowScreen` captures its state at `init`. A superseded parse cannot arise — there
    /// is exactly one injection per launch, and the guard below keeps `.task` re-running from
    /// starting a second.
    ///
    /// The name is resolved to a resource in the app's **own bundle**;
    /// ``UITestSupport/importFileEnvironmentKey`` records why — two CI rounds in which the runner and
    /// the app could not be made to name one directory between them.
    private func presentInjectedImportIfNeeded() async {
        guard injectedImport == nil, let injection = UITestSupport.importInjection() else { return }

        let kind = injection.kind
        let workflow = ImportWorkflow(kind: kind)
        workflow.parseFile(
            at: injection.url,
            existingEndpoints: currentEndpoints,
            // The read is still a real read of a real file, on the same detached hop the panel path
            // uses; `importFixtureData` only expands the padding token, and only when this run asked
            // for it. Capturing the count rather than the injection keeps the closure over a plain
            // `Int?`, which is `Sendable` without anything having to be declared so.
            loadData: { [paddingByteCount = injection.paddingByteCount] url in
                try UITestSupport.importFixtureData(at: url, paddingByteCount: paddingByteCount)
            },
            parse: { data, endpoints in
                try await kind.parse(data: data, existingEndpoints: endpoints)
            }
        )
        // Bound rather than optional-chained: `await workflow.parseTask?.value` is an expression of
        // type `()?`, which the compiler reports as an unused result.
        if let parseTask = workflow.parseTask {
            await parseTask.value
        }

        // The app's own answer to "was the file there", computed only when something failed, and
        // carried out through the sheet's error text — the one channel of the app's that reaches the
        // runner. The app's stdout does not: an entire round of CI diagnostics printed from the
        // runner never appeared in the xcodebuild log either, so anything a later diagnosis needs has
        // to arrive in the accessibility tree or in an assertion message.
        //
        // This is what makes the two error-state tests mean something. `readableParseError` appends
        // its format guidance to *any* error, a file that could not be opened included, so "Parse
        // error" over "Mimic reads HAR 1.2" is exactly what a missing fixture produces too — and on
        // the first CI round those two tests were the only ones that passed, green over the bug the
        // other eight were failing on. `SpecImportUITests.assertFixtureWasReadable` requires the
        // "bytes read" half of this line before it will believe an error is about the bytes.
        var readReport = "not checked"
        if workflow.parseError != nil {
            do {
                let bytes = try Data(contentsOf: injection.url).count
                readReport = "\(bytes) bytes read"
            } catch {
                readReport = "unreadable: \(error)"
            }
        }

        // Whatever the parse produced, including a failure: the error state is a review-screen arm
        // too, and it is the one an injected fixture is most likely to land on.
        injectedImport = InjectedImport(
            kind: kind,
            state: ImportWorkflowState(
                candidates: workflow.candidates,
                parseError: workflow.parseError.map { failure in
                    // Appended rather than substituted, so the format guidance the two error-state
                    // tests match on is still in front of it.
                    "\(failure)\n\nInjected fixture: \(injection.url.path) — \(readReport)"
                },
                isParsing: false
            )
        )
    }
    #endif
}
