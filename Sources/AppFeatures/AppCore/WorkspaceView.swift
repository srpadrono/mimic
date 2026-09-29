import SwiftUI
import Domain
import DesignSystem
import Persistence

nonisolated enum WorkspaceToolbarLayout: Equatable {
    case expanded
    case compactSummary
    case overflow
    /// The status capsule keeps only its state word and the project identity narrows.
    case narrow
}

/// The workspace: a full-height navigator, an editor column with the request log docked below it, and
/// a full-height inspector. Both side panels are real `NavigationSplitView`/`.inspector` columns, so
/// only the request log is a tenant of the centre.
struct WorkspaceView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showInspector: Bool
    @State private var showDrawer: Bool
    /// The request log on the journeys screen, which the design draws without one. Kept apart from
    /// `showDrawer`, the endpoints screen's persisted preference, so ⌥⌘L can still show the log
    /// beside a journey without the endpoints screen losing its own arrangement.
    @State private var showJourneyDrawer = false
    @State private var selectedEndpointID: UUID?
    @State private var renameEndpointTarget: Endpoint?
    @State private var editEndpointRequestTarget: Endpoint?
    /// The logged requests the user has selected. Owned here rather than inside the log because it
    /// arranges the window: while any row is selected the centre column shows the log beside the
    /// request's detail in place of the editor, and the inspector steps aside.
    ///
    /// A set because a selection is also how a journey is captured from a session. The detail
    /// shows one request only when exactly one row is selected — detail is about one thing.
    @State private var selectedLogIDs: Set<UUID> = []
    /// The request log's filter, sort and rows, shared by the docked log and the one that opens
    /// beside a selected request, so moving between the two keeps them.
    @State private var requestLogTable = RequestLogTableState()
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
    /// The endpoint editor's own height. The request log sits right below it and takes the rest;
    /// `nil` while the centre shows something that fills it.
    @State private var centreContentHeight: CGFloat?

    /// Start with the narrowest fit so AppKit never overflows the identity before the first
    /// geometry measurement. Then update only when the layout tier changes during a resize.
    @State private var centerToolbarLayout: WorkspaceToolbarLayout = .narrow

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
                    if !selectedLogIDs.isEmpty {
                        // A selected request takes over the column: the log on the left, the request
                        // on the right, and neither the editor nor the docked log beside them.
                        // Deselecting — Escape in the list, the close button, picking an endpoint —
                        // brings the editor back.
                        requestLogPanel(showsDetail: true)
                    } else {
                        // Xcode's jump bar. Sits above the editor area rather than inside any one
                        // editor, because it describes where you are, not what you are editing.
                        BreadcrumbJumpBar(
                            crumbs: breadcrumbs,
                            autosaveStatus: appState.autosaveStatus,
                            onSelectOption: handleBreadcrumbSelection
                        )
                        Rectangle()
                            .fill(DSColors.separator)
                            .frame(height: DSStroke.hairline)
                            .accessibilityHidden(true)

                        // The pair that shares the space below the jump bar, as one `NSSplitViewItem`
                        // pair — so the divider between them is the same divider the navigator and the
                        // inspector already wear, and the centre pane's floor is a constraint AppKit
                        // enforces rather than a ceiling this view recomputes from a measured container.
                        DSSplitPane(
                            axis: .vertical,
                            isSecondaryPresented: logPresentation,
                            secondaryThickness: $drawerHeight,
                            minimumPrimaryThickness: PanelLayoutStore.Bounds.minimumCentreHeight,
                            minimumSecondaryThickness: PanelLayoutStore.Bounds.minimumRequestLogHeight,
                            defaultSecondaryThickness: PanelLayout.default.requestLogHeight,
                            preferredPrimaryThickness: centreContentHeight,
                            identifier: "requestLog"
                        ) {
                            CenterPaneView(
                                content: CenterPaneContent.forTab(
                                    navigatorTab,
                                    endpointID: selectedEndpointID,
                                    journeyID: appState.selectedJourneyID
                                ),
                                onRenameEndpoint: beginEndpointRename,
                                onEditEndpointRequest: beginEndpointRequestEdit,
                                onAddEndpoint: { appState.showNewEndpointSheet = true },
                                onImportHAR: { showHARImport = true },
                                onImportOpenAPI: { showOpenAPIImport = true },
                                onContentHeightChange: { height in
                                    guard centreContentHeight != height else { return }
                                    centreContentHeight = height
                                }
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
                            requestLogPanel(showsDetail: false)
                                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        }
                    }
                }
                // A floor for the centre column, so narrowing the window takes the side panels down
                // to their minimum widths before the editor is squeezed.
                .frame(minWidth: DSLayout.centreMinimumWidth)
                // The one content surface: a rounded card inset from the window, under the toolbar.
                .background(DSColors.content)
                .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: DSCornerRadius.panel, style: .continuous)
                        .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
                }
                .padding(.top, DSSpacing.xs)
                .padding([.horizontal, .bottom], DSLayout.panelInset)
                .background(DSColors.window.ignoresSafeArea())
                .onGeometryChange(for: WorkspaceToolbarLayout.self) {
                    Self.toolbarLayout(centerWidth: $0.size.width)
                } action: { layout in
                    // The toolbar changes its intrinsic width at two breakpoints. During a live
                    // window resize, animating that change lets the Run button and its neighbours
                    // occupy the same space for a frame while AppKit rearranges native items.
                    var transaction = Transaction(animation: nil)
                    transaction.disablesAnimations = true
                    withTransaction(transaction) { centerToolbarLayout = layout }
                }
                // Editor actions belong to this column, before the inspector divides the toolbar.
                .toolbar { workspaceToolbar }
            }
            .navigationSplitViewStyle(.balanced)
            // Outside the navigation structure, the inspector owns a full-height column and its
            // own toolbar section, which holds its header (`InspectorPanelView`). That section is
            // what keeps the centre column's actions over the centre column.
            .inspector(isPresented: inspectorColumnPresentation) {
                inspectorPanel
                    // The journey inspector edits through `AppState`; stated so the column never
                    // depends on how the inspector happens to be hosted.
                    .environment(appState)
                    .inspectorColumnWidth(
                        min: PanelLayoutStore.Bounds.minimumInspectorWidth,
                        ideal: PanelLayoutStore.Bounds.idealInspectorWidth,
                        max: DSLayout.inspectorMaximumWidth
                    )
                    .accessibilityElement(children: .contain)
                    .accessibilityIdentifier("inspector")
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
            NewEndpointSheet(
                existingGroups: Set(currentEndpoints.compactMap(\.groupTag).filter { !$0.isEmpty }).sorted()
            ) { draft in
                if let endpoint = appState.addEndpoint(
                    name: draft.name,
                    method: draft.method,
                    path: draft.path,
                    groupTag: draft.groupTag,
                    statusCode: draft.statusCode,
                    contentType: draft.contentType
                ) {
                    revealEndpoint(endpoint)
                }
            }
        }
        .sheet(item: $renameEndpointTarget) { endpoint in
            RenameItemSheet(
                title: "Rename endpoint", fieldLabel: "Endpoint name",
                identifier: "endpointRename", initialName: endpoint.name
            ) { name in
                appState.updateEndpoint(id: endpoint.id, spec: EndpointSpec(name: name))
            }
        }
        .sheet(item: $editEndpointRequestTarget) { endpoint in
            EndpointRequestSheet(endpoint: endpoint) { spec in
                appState.updateEndpoint(id: endpoint.id, spec: spec)
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
            .disabled(appState.updates.isPreparingInstallation)
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
            .disabled(appState.updates.isPreparingInstallation)
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
                // Captured from the log, so the log stays beside the journey it fed.
                showJourneyDrawer = true
                navigatorTab = .journeys
            }
        }
        // The centre column shows one thing at a time, so the newer selection wins. Picking an
        // endpoint while a request is up should show that endpoint — not silently lose the click.
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
        .onChange(of: appState.currentProject?.id) { _, _ in resetProjectPresentation() }
        // A cleared log takes its selection with it; otherwise the centre column goes on showing a
        // request that is no longer in the list.
        .onChange(of: appState.requestLogs.isEmpty) { _, isEmpty in
            guard isEmpty else { return }
            selectedLogIDs = []
        }
        // Panel arrangement is a preference, so it is written as it changes.
        .onChange(of: drawerHeight) { _, _ in persistLayout() }
        .onChange(of: showDrawer) { _, _ in persistLayout() }
        .onChange(of: isLogShown, initial: true) { _, visible in
            appState.isRequestLogVisible = visible
        }
        .onChange(of: showInspector) { _, _ in persistLayout() }
        // The View menu reads what is on screen, which an empty project or an open request overrides.
        .onChange(of: isInspectorPresented, initial: true) { _, visible in
            appState.isInspectorVisible = visible
        }
        .onChange(of: canPresentInspector, initial: true) { _, available in
            appState.canShowInspector = available
        }
        // ⌥⌘L and ⌥⌘I live in the View menu, so they work whether the toggles are inline or folded.
        .onChange(of: appState.requestLogToggleRequest) { _, _ in toggleRequestLog() }
        .onChange(of: appState.inspectorToggleRequest) { _, _ in toggleInspector() }
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
            .disabled(appState.updates.isPreparingInstallation)
        }
        .task { await presentInjectedImportIfNeeded() }
        #endif
    }

    // MARK: - Toolbar

    /// Collapse in stages as the centre column narrows: first the secondary actions fold into one
    /// menu, then the status capsule drops its counts, then the project identity narrows. The
    /// capsule always keeps its state word.
    nonisolated static func toolbarLayout(centerWidth: CGFloat) -> WorkspaceToolbarLayout {
        guard centerWidth.isFinite else { return .narrow }
        if centerWidth < 460 { return .narrow }
        if centerWidth < 620 { return .compactSummary }
        if centerWidth < 780 { return .overflow }
        return .expanded
    }

    nonisolated static func toolbarUsesCompactSummary(centerWidth: CGFloat) -> Bool {
        let layout = toolbarLayout(centerWidth: centerWidth)
        return layout == .compactSummary || layout == .narrow
    }

    /// Import, server settings, and both panel toggles move into one menu; Run never does.
    nonisolated static func toolbarUsesOverflow(centerWidth: CGFloat) -> Bool {
        toolbarLayout(centerWidth: centerWidth) != .expanded
    }

    nonisolated static func toolbarUsesNarrowIdentity(centerWidth: CGFloat) -> Bool {
        toolbarLayout(centerWidth: centerWidth) == .narrow
    }

    private var usesCompactToolbarSummary: Bool {
        centerToolbarLayout == .compactSummary || centerToolbarLayout == .narrow
    }

    private var usesToolbarOverflow: Bool {
        centerToolbarLayout != .expanded
    }

    /// The identity's widest extent at each stage, so the centre column's items fit its section.
    private var projectIdentityMaximumWidth: CGFloat {
        switch centerToolbarLayout {
        case .expanded, .overflow: 220
        case .compactSummary: 140
        case .narrow: 100
        }
    }

    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            historyButton(forward: false)
            historyButton(forward: true)
        }

        ToolbarItem(id: "workspace.identity", placement: .navigation) {
            projectIdentity
        }
        .sharedBackgroundVisibility(.hidden)

        ToolbarItem(id: "workspace.status", placement: .principal) {
            // Wrapped, not the item's root. A bare `Button` as a toolbar item's root is published as
            // the item itself: the toggle beside it loses its accessibility label that way, and the
            // well's details popover never reached the accessibility tree. A container keeps the well
            // a SwiftUI button and its popover addressable, as it was before the toolbar was rebuilt.
            HStack(spacing: 0) { serverSummary }
                .accessibilityElement(children: .contain)
        }

        ToolbarItem(id: "workspace.run", placement: .primaryAction) {
            ServerToggleButton(
                serverState: appState.serverState,
                onStart: appState.startServer,
                onStop: appState.stopServer
            )
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItemGroup(placement: .primaryAction) {
            if usesToolbarOverflow {
                overflowMenu
            } else {
                importMenu(inToolbar: true)
                serverSettingsButton.labelStyle(.iconOnly)
            }
        }

        if !usesToolbarOverflow {
            ToolbarSpacer(.fixed, placement: .primaryAction)
            ToolbarItemGroup(placement: .primaryAction) {
                drawerToolbarButton.labelStyle(.iconOnly)
                inspectorToolbarButton.labelStyle(.iconOnly)
            }
        }
    }

    /// Back and forward across endpoints you have looked at, the way Xcode's editor history works.
    private func historyButton(forward: Bool) -> some View {
        let enabled = forward
            ? endpointHistory.canGoForward(where: endpointExists)
            : endpointHistory.canGoBack(where: endpointExists)
        return Button {
            let target = forward
                ? endpointHistory.goForward(where: endpointExists)
                : endpointHistory.goBack(where: endpointExists)
            if let target, let endpoint = currentEndpoints.first(where: { $0.id == target }) {
                isNavigatingHistory = selectedEndpointID != target
                revealEndpoint(endpoint)
            }
        } label: {
            Label(forward ? "Forward" : "Back", systemImage: forward ? "chevron.forward" : "chevron.backward")
                .labelStyle(.iconOnly)
        }
        .disabled(!enabled)
        .help(forward ? "Go forward" : "Go back")
        .accessibilityIdentifier(forward ? "breadcrumb.forward" : "breadcrumb.back")
        .accessibilityLabel(forward ? "Go forward" : "Go back")
    }

    /// The project's name over the address it serves on.
    private var projectIdentity: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(appState.currentProject?.name ?? "Mimic")
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(appState.currentProject?.name ?? "Mimic")
                .accessibilityIdentifier("toolbar.projectName")
            if let address = projectAddress {
                Text(address)
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.labelSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .accessibilityIdentifier("toolbar.projectKind")
                    .accessibilityLabel("Local mock at \(address)")
            }
        }
        .frame(maxWidth: projectIdentityMaximumWidth, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toolbar.projectIdentity")
    }

    /// `localhost:18086`, plus how many other listeners the project has.
    private var projectAddress: String? {
        guard let configuration = appState.currentProject?.serverConfiguration else { return nil }
        let port = appState.serverState.runningPort ?? configuration.port
        let others = configuration.listeners.count - 1
        return others > 0 ? "localhost:\(port) +\(others)" : "localhost:\(port)"
    }

    private var serverSummary: some View {
        ServerStatusWell(
            serverState: appState.serverState,
            projectName: appState.currentProject?.name,
            requestCount: appState.requestLogs.count,
            unmatchedCount: RequestLogQuery.unmatchedCount(logs: appState.requestLogs),
            compact: usesCompactToolbarSummary,
            configuration: appState.currentProject?.serverConfiguration,
            boundConfiguration: appState.server.boundConfiguration,
            runningSince: appState.server.runningSince,
            onShowUnmatched: {
                logPresentation.wrappedValue = true
                showUnmatchedOnly = true
            },
            onShowSettings: { showBackendSettings = true },
            onToggleServer: {
                if appState.serverState.runningPort != nil {
                    appState.stopServer()
                } else {
                    appState.startServer()
                }
            }
        )
    }

    /// Everything but Run, folded into one menu when the centre column is narrow.
    private var overflowMenu: some View {
        let unmatchedCount = RequestLogQuery.unmatchedCount(logs: appState.requestLogs)
        let unmatchedDescription = "\(unmatchedCount) unmatched \(unmatchedCount == 1 ? "request" : "requests")"
        return Menu {
            importMenu()
            serverSettingsButton
            Divider()
            drawerToolbarButton
            inspectorToolbarButton
            if unmatchedCount > 0 {
                Divider()
                Button("Show unmatched requests (\(unmatchedCount))") {
                    logPresentation.wrappedValue = true
                    showUnmatchedOnly = true
                }
                .accessibilityIdentifier("toolbar.showUnmatched")
                .accessibilityLabel("Show unmatched requests")
            }
        } label: {
            Label("More", systemImage: appState.server.restartRequired
                  ? "exclamationmark.arrow.circlepath" : "ellipsis")
                .labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden)
        .help("Import, server settings, and panels")
        .accessibilityIdentifier("toolbar.overflow")
        .accessibilityLabel("More actions")
        .accessibilityValue(unmatchedCount > 0
            ? unmatchedDescription
            : (appState.server.restartRequired ? "Server restart required" : ""))
    }

    private var serverSettingsButton: some View {
        Button { showBackendSettings = true } label: {
            Label(
                appState.server.restartRequired ? "Server settings, restart required" : "Server settings\u{2026}",
                systemImage: appState.server.restartRequired ? "exclamationmark.arrow.circlepath" : "slider.horizontal.3"
            )
        }
        .disabled(appState.currentProject == nil)
        .help(appState.server.restartRequired ? "Restart the server to apply local port changes" : "Configure local ports and real backends")
        .accessibilityIdentifier("backend.settingsButton")
        .accessibilityLabel("Server settings")
    }

    /// Whether there is anything for the inspector to show. A project with no endpoints and no
    /// journeys has none.
    private var canPresentInspector: Bool {
        !currentEndpoints.isEmpty || !appState.journeys.isEmpty
    }

    /// The column on screen: the person's choice, which an empty project or a request open in the
    /// centre column overrides without forgetting it.
    private var isInspectorPresented: Bool {
        showInspector && canPresentInspector && selectedLogIDs.isEmpty
    }

    /// AppKit writes back here when the column is dragged shut; that is the person's choice too. A
    /// write while an empty project or an open request hides the column is not, and is ignored.
    private var inspectorColumnPresentation: Binding<Bool> {
        Binding(
            get: { isInspectorPresented },
            set: { value in
                guard canPresentInspector, selectedLogIDs.isEmpty, value != showInspector else { return }
                showInspector = value
            }
        )
    }

    /// Showing the inspector while a request is open closes the request, so the choice is honoured.
    private func toggleInspector() {
        guard canPresentInspector else { return }
        withAnimation(reduceMotion ? nil : DSAnimation.panel) {
            if isInspectorPresented {
                showInspector = false
            } else {
                selectedLogIDs = []
                showInspector = true
            }
        }
    }

    private var drawerToolbarButton: some View {
        Button { toggleRequestLog() } label: {
            Label(isLogShown ? "Hide request log" : "Show request log", systemImage: "rectangle.bottomthird.inset.filled")
        }
        .help(isLogShown ? "Hide request log (⌥⌘L)" : "Show request log (⌥⌘L)")
        .accessibilityIdentifier("toggleDrawerButton")
        .accessibilityLabel(isLogShown ? "Hide request log" : "Show request log")
    }

    private var inspectorToolbarButton: some View {
        Button { toggleInspector() } label: {
            Label(isInspectorPresented ? "Hide inspector" : "Show inspector", systemImage: "sidebar.right")
        }
        .disabled(!canPresentInspector)
        .help(canPresentInspector
            ? (isInspectorPresented ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
            : "Add an endpoint or a journey to inspect it")
        .accessibilityIdentifier("toggleInspectorButton")
        .accessibilityLabel(isInspectorPresented ? "Hide inspector" : "Show inspector")
    }

    private func toggleRequestLog() {
        logPresentation.wrappedValue.toggle()
    }

    /// Whether the request log is under the centre pane on the screen now showing.
    private var isLogShown: Bool {
        navigatorTab == .journeys ? showJourneyDrawer : showDrawer
    }

    /// The log's visibility for the screen now showing: the journeys screen opens without it.
    private var logPresentation: Binding<Bool> {
        Binding(
            get: { isLogShown },
            set: { visible in
                if navigatorTab == .journeys { showJourneyDrawer = visible } else { showDrawer = visible }
            }
        )
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
        var crumbs: [BreadcrumbJumpBar.Crumb] = []

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
            if let group = endpoint.groupTag, !group.isEmpty {
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
                    title: "\(endpoint.method.rawValue) \(endpoint.path)",
                    options: siblings.map {
                        BreadcrumbJumpBar.Option(id: $0.id, title: "\($0.method.rawValue) \($0.path)",
                                                 isSelected: $0.id == endpoint.id)
                    }
                )
            )

            if !endpoint.scenarios.isEmpty {
                let edited = appState.editedScenario(of: endpoint)
                crumbs.append(
                    BreadcrumbJumpBar.Crumb(
                        id: "scenario",
                        title: edited?.name ?? "No scenario",
                        options: endpoint.scenarios.map {
                            BreadcrumbJumpBar.Option(
                                id: $0.id,
                                title: $0.name,
                                isSelected: $0.id == edited?.id
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
            if let endpoint = currentEndpoints.first(where: { $0.id == optionID }) {
                revealEndpoint(endpoint)
            }
        case "scenario":
            guard let endpointID = selectedEndpointID else { return }
            appState.editScenario(endpointID: endpointID, scenarioID: optionID)
        case "journey":
            appState.selectedJourneyID = optionID
        default:
            break
        }
    }

    // MARK: - Navigator

    /// The navigator's "+" on the Journeys tab.
    ///
    /// `DSIconMenu` shares the 26pt control and hover treatment with the endpoint editor's menu.
    private var addJourneyMenu: some View {
        DSIconMenu(
            systemImage: "plus",
            help: "Add a journey",
            // This chooser offers an empty journey or a template. The empty-state "Add journey"
            // button creates one directly, so it has a different accessible name.
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
            )

            Group {
                switch navigatorTab {
                case .endpoints:
                    SidebarView(
                        projectName: appState.currentProject?.name,
                        endpoints: currentEndpoints,
                        serverConfiguration: appState.currentProject?.serverConfiguration,
                        selectedEndpointID: $selectedEndpointID,
                        onDeleteEndpoint: appState.deleteEndpoint,
                        onDuplicateEndpoint: { appState.duplicateEndpoint(id: $0)?.id },
                        onRenameEndpoint: beginEndpointRename,
                        onEditEndpointRequest: beginEndpointRequestEdit,
                        onAddEndpoint: { appState.showNewEndpointSheet = true },
                        searchText: $endpointFilter,
                        methodScopeID: $endpointMethodScope,
                        collapsedSections: $collapsedEndpointGroups
                    )
                case .journeys:
                    JourneyNavigatorList(
                        journeys: appState.journeys,
                        activeJourneyID: appState.activeJourney?.id,
                        activeStatus: appState.activeJourneyStatus,
                        selectedJourneyID: $appState.selectedJourneyID,
                        onActivate: appState.activateJourney,
                        onAdd: {
                            if let journey = appState.addJourney(name: "New journey") {
                                appState.selectedJourneyID = journey.id
                            }
                        },
                        onDuplicate: { _ = appState.duplicateJourney(id: $0) },
                        onDelete: appState.deleteJourney,
                        onRename: { id, name in
                            appState.updateJourney(id: id, spec: JourneySpec(name: name))
                        },
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
                placeholder: "Filter",
                label: navigatorTab == .endpoints ? "Filter endpoints" : "Filter journeys",
                identifier: navigatorTab == .endpoints ? "sidebar.filter" : "journeys.filter",
                focusRequest: appState.navigatorFilterRequest
            ) {
                if let active = appState.activeJourney {
                    DSPanelHeaderButton(
                        systemImage: "play.circle.fill",
                        help: "Show active journey: \(active.name)",
                        identifier: "navigator.activeJourney",
                        tint: DSColors.success
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
                    addJourneyMenu
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
    private func requestLogPanel(showsDetail: Bool) -> some View {
        RequestLogDrawerView(
            requestLogs: appState.requestLogs,
            endpoints: currentEndpoints,
            serverState: appState.serverState,
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
                showJourneyDrawer = true
                navigatorTab = .journeys
                // Neither line changes anything when that journey is already open, and the editor
                // is where the new steps show, so the request gives the column back explicitly.
                selectedLogIDs = []
            },
            // Capturing into a brand-new journey names it first — the sheet then shows the journey,
            // or the command reads as having done nothing.
            onAddToNewJourney: { logs in
                pendingCapture = CaptureJourneySheet.Capture(
                    logs: logs,
                    suggestedName: AppState.journeyName(capturing: logs)
                )
            },
            table: requestLogTable,
            showsDetail: showsDetail,
            onGoToEndpoint: { id in
                guard let endpoint = currentEndpoints.first(where: { $0.id == id }) else { return }
                revealEndpoint(endpoint)
            }
        )
        .configuredPort(appState.serverConfiguration.port)
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
        let selectedJourney = navigatorTab == .journeys
            ? appState.journeys.first { $0.id == appState.selectedJourneyID } : nil

        InspectorPanelView(
            endpoint: endpoint,
            overview: endpoint == nil ? inspectorOverview : nil,
            journey: selectedJourney.map {
                JourneyInspector.Context(selected: $0, active: appState.activeJourney,
                                         progress: activeJourneyProgress, serverState: appState.serverState,
                                         selectedStepID: appState.selectedJourneyStepID)
            },
            showsHeader: isInspectorPresented,
            endpointTraffic: endpoint.map {
                EndpointTrafficQuery.logs(forEndpoint: $0.id, in: appState.requestLogs)
            } ?? [],
            endpointSettings: endpoint.map { endpoint in
                EndpointInspectorSettings.Context(
                    editedScenarioID: appState.editedScenario(of: endpoint)?.id,
                    onEditScenario: { appState.editScenario(endpointID: $0, scenarioID: $1) },
                    globalDelayMs: appState.serverConfiguration.globalDelayMs,
                    backends: appState.serverConfiguration.listeners,
                    groups: Set(currentEndpoints.compactMap(\.groupTag).filter { !$0.isEmpty }).sorted(),
                    onUpdateGroupTag: { appState.updateEndpointGroupTag(id: $0, groupTag: $1) },
                    onUpdateBackend: { appState.updateEndpointBackend(id: $0, backendID: $1) },
                    onUpdatePassthrough: { appState.setPassthrough(backendID: $0, enabled: $1) }
                )
            },
            onShowJourneys: { navigatorTab = .journeys },
            onAddScenario: { endpointID, name in
                if let scenario = appState.addScenario(endpointID: endpointID, name: name) {
                    appState.editScenario(endpointID: endpointID, scenarioID: scenario.id)
                }
            },
            onSetActiveScenario: appState.setActiveScenario,
            onDuplicateScenario: { _ = appState.duplicateScenario(endpointID: $0, scenarioID: $1) },
            onDeleteScenario: appState.deleteScenario,
            onRenameScenario: appState.renameScenario
        )
    }

    /// Creating a mock from traffic should reveal what was created even when Journeys is open.
    private func revealEndpoint(_ endpoint: Endpoint) {
        endpointFilter = ""
        endpointMethodScope = SidebarView.anyMethodScopeID
        collapsedEndpointGroups.remove(SidebarView.sectionKey(for: endpoint))
        navigatorTab = .endpoints
        selectedEndpointID = endpoint.id
        selectedLogIDs = []
    }

    private func endpointExists(_ id: UUID) -> Bool {
        currentEndpoints.contains { $0.id == id }
    }

    /// Draft sheets and navigation belong to the project that opened them; panel geometry is global.
    private func resetProjectPresentation() {
        selectedEndpointID = nil
        selectedLogIDs = []
        endpointHistory = NavigationHistory()
        isNavigatingHistory = false
        endpointFilter = ""
        endpointMethodScope = SidebarView.anyMethodScopeID
        collapsedEndpointGroups = []
        journeyFilter = ""
        collapsedJourneyGroups = []
        navigatorTab = .endpoints
        showUnmatchedOnly = false
        renameEndpointTarget = nil
        editEndpointRequestTarget = nil
        pendingCapture = nil
        showHARImport = false
        showOpenAPIImport = false
        showBackendSettings = false
        showJourneyTemplatePicker = false
        showNewJourneySheet = false
        appState.showNewEndpointSheet = false
    }

    private func beginEndpointRename(_ id: UUID) {
        renameEndpointTarget = currentEndpoints.first { $0.id == id }
    }

    private func beginEndpointRequestEdit(_ id: UUID) {
        editEndpointRequestTarget = currentEndpoints.first { $0.id == id }
    }

    /// Project-level facts for the inspector's no-selection state.
    private var inspectorOverview: InspectorOverview.Summary {
        let project = appState.currentProject
        let endpoints = currentEndpoints
        let status = appState.activeJourneyStatus
        return InspectorOverview.Summary(
            projectName: project?.name ?? "Mimic",
            serverState: appState.serverState,
            port: appState.serverState.runningPort ?? project?.serverConfiguration.port ?? 0,
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
