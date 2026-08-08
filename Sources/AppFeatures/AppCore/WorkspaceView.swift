import SwiftUI
import Domain
import DesignSystem
import Persistence

/// The workspace: a full-height navigator, an editor column with the request log docked below it, and
/// a full-height inspector. Both side panels are real `NavigationSplitView`/`.inspector` columns, so
/// only the request log is a tenant of the centre.
struct WorkspaceView: View {
    @Environment(AppState.self) private var appState
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
    /// Restrict the request log to one endpoint's traffic. What the inspector's retired Traffic tab
    /// became: the question is answered in the log the user is already watching rather than in a
    /// second list of the same rows.
    @State private var logEndpointScope: UUID?
    /// Which navigator the sidebar is showing, and therefore what the centre pane edits.
    @State private var navigatorTab: NavigatorTab = .endpoints
    /// Back/forward across endpoints you have looked at.
    @State private var endpointHistory = NavigationHistory<UUID>()
    /// Set while a back/forward move is in flight, so the resulting selection change is not recorded
    /// as a *new* visit — which would truncate the forward stack and make Forward unreachable the
    /// instant you used Back.
    @State private var isNavigatingHistory = false
    @State private var showHARImport = false
    @State private var showOpenAPIImport = false
    /// The two journey sheets, both of which used to be reachable only from the journeys window.
    @State private var showJourneyTemplatePicker = false
    @State private var showNewJourneySheet = false
    @State private var isAddJourneyHovered = false
    /// How tall the request log is. Two-way with `DSSplitPane`, which reports a *settled* size rather
    /// than every frame of a drag — so this can be persisted on change without writing `UserDefaults`
    /// at the pointer's sample rate, which is what the hand-rolled divider used to do.
    @State private var drawerHeight: CGFloat

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

    var body: some View {
        @Bindable var appState = appState

        // The window's floor, not a preference. Below this the request log's Path column collapses —
        // its other columns are fixed and total 380pt — and because the row is an `HStack`, an
        // over-committed one pushes its *leading* edge out of view rather than truncating, so the
        // method badges leave the window before anything visibly runs out of room. `WelcomeWindow`
        // carries its own, much smaller, floor for the same reason: they share this scene, and a
        // workspace-sized minimum would make the welcome screen 1140pt wide.
        //
        // `.windowResizability(.contentMinSize)` on the scene is what turns this into something
        // AppKit enforces on the drag rather than a number a view hopes for.
        VStack(spacing: 0) {
            NavigationSplitView {
                navigator
                    // The split view's own modifier, never a `.frame`. AGENTS.md is explicit:
                    // anything a user drags is an `NSSplitViewItem`, and handing the column a frame
                    // fights the drag rather than configuring it — which is how one divider ended up
                    // behaving differently from the other two.
                    .navigationSplitViewColumnWidth(
                        min: 220,
                        ideal: PanelLayoutStore.Bounds.idealNavigatorWidth,
                        max: 420
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
                    // No jump bar above this. It used to sit here at 24pt, which made the centre
                    // column the one pane whose first row did not start at the same y as the other
                    // three — 54pt of stacked chrome against everyone else's 30. Its sideways moves
                    // now live in each editor's own overflow menu; see `CenterPaneNavigation`.
                    //
                    // The pair that shares the centre column, as one `NSSplitViewItem`
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
                            ),
                            navigation: centerPaneNavigation,
                            onStartEmptyJourney: { showNewJourneySheet = true }
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
                // A real column, not a trailing drawer inside the detail view.
                //
                // As a `DSDrawer` the inspector lived *inside* the detail pane, so the window had one
                // unbroken toolbar spanning the editor and the inspector both, and the panel toggles
                // simply floated at its far right. Xcode divides the toolbar at the inspector's edge:
                // a vertical rule runs from the very top of the bar down through the content, and the
                // inspector's toolbar region holds only its own toggle. `.inspector` is what produces
                // that structure — the divider, the column, and the toolbar segmentation come with it.
                .inspector(isPresented: $showInspector) {
                    inspectorPanel
                        .inspectorColumnWidth(
                            min: PanelLayoutStore.Bounds.minimumInspectorWidth,
                            ideal: PanelLayoutStore.Bounds.idealInspectorWidth,
                            max: 640
                        )
                        // `.contain` for the same reason the sidebar needs it: a bare identifier on a
                        // container overrides its descendants', which would make every control inside
                        // the request detail report "inspector".
                        .accessibilityElement(children: .contain)
                        .accessibilityIdentifier("inspector")
                }
                .toolbar {
                    // Grouped, not two adjacent singletons. AppKit sets related controls in a
                    // `ToolbarItemGroup` closer together and treats them as one unit when the window
                    // narrows, which is what makes Xcode's toolbar read as clusters rather than a
                    // row of loose buttons.
                    ToolbarItemGroup(placement: .navigation) {
                        // One object, not two at opposite ends of the bar. The run control and the
                        // state it produces were never in the same glance before this.
                        DSServerSegment(
                            serverState: appState.serverState,
                            requestCount: appState.requestLogs.count,
                            unmatchedCount: RequestLogQuery.unmatchedCount(logs: appState.requestLogs),
                            onStart: appState.startServer,
                            onStop: appState.stopServer,
                            // No `withAnimation`: the request log is an `NSSplitViewItem`, and AppKit
                            // animates the reveal through its own animator. Wrapping the flag in a
                            // SwiftUI animation would only animate the flag.
                            onShowUnmatched: {
                                showDrawer = true
                                showUnmatchedOnly = true
                            }
                        )

                        // Import stays here because it acts on the *project*, not on one panel.
                        //
                        // "Add endpoint" used to sit beside it and no longer does: the navigator
                        // already owns that action in its own strip, where it adds an endpoint or a
                        // journey depending on which tab is showing. Two "+" buttons for one job,
                        // one of which was wrong half the time.
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
                            Label("Import", systemImage: "square.and.arrow.down")
                        }
                        .help("Import a HAR file or an OpenAPI spec")
                        .accessibilityIdentifier("importMenuButton")
                        .accessibilityLabel("Import")
                    }

                    // Dead centre, like Xcode's activity view. This is not what made the toolbar read
                    // as three islands — the fault was that everything *else* was pinned to the two
                    // far edges, so the centre had nothing around it. With the content actions moved
                    // into this column the bar now reads as one row.
                    // No principal item any more. It held `ServerStatusWell`, which said the same
                    // thing the segment now says at the leading edge — and having the address in the
                    // centre while the run control sat at the far left is what made the toolbar read
                    // as separate islands.

                    // The autosave indicator is empty while idle, so it must not be allowed to
                    // change the toolbar's layout when it flickers into view for two seconds. A
                    // reserved slot keeps its neighbours still.
                    ToolbarItem(placement: .primaryAction) {
                        AutosaveStatusIndicator(status: appState.autosaveStatus)
                            .frame(minWidth: 54, alignment: .trailing)
                    }

                    // Panel toggles as their own cluster at the trailing edge, which is where every
                    // macOS app that has them puts them — Xcode included.
                    ToolbarItemGroup(placement: .primaryAction) {
                        Button {
                            showDrawer.toggle()
                        } label: {
                            Label("Toggle request log", systemImage: "rectangle.bottomhalf.inset.filled")
                        }
                        .keyboardShortcut("l", modifiers: [.command, .option])
                        // The shortcut is named here because it is named nowhere else: these two
                        // toggles appear in no menu, so without the tooltip ⌥⌘L and ⌥⌘I are
                        // undiscoverable. Xcode puts the equivalents in its View menu.
                        .help(showDrawer ? "Hide request log (⌥⌘L)" : "Show request log (⌥⌘L)")
                        .accessibilityIdentifier("toggleDrawerButton")
                        .accessibilityLabel(showDrawer ? "Hide request log" : "Show request log")

                        Button {
                            withAnimation(DSAnimation.drawerToggle) { showInspector.toggle() }
                        } label: {
                            Label("Toggle inspector", systemImage: "sidebar.right")
                        }
                        .keyboardShortcut("i", modifiers: [.command, .option])
                        .help(showInspector ? "Hide inspector (⌥⌘I)" : "Show inspector (⌥⌘I)")
                        .accessibilityIdentifier("toggleInspectorButton")
                        .accessibilityLabel(showInspector ? "Hide inspector" : "Show inspector")
                    }
                }
            }

        }
        .frame(
            minWidth: PanelLayoutStore.Bounds.minimumWindowContentWidth,
            minHeight: PanelLayoutStore.Bounds.minimumWindowContentHeight
        )
        // Port conflict alert
        .alert(
            "Port \(appState.portConflictAlert?.conflictingPort ?? 0) already in use",
            isPresented: $appState.isShowingPortConflict,
            presenting: appState.portConflictAlert
        ) { alertData in
            Button("Try port \(alertData.suggestedPort)") {
                appState.retryStartOnNextPort(from: alertData.conflictingPort)
            }
            Button("Keep server stopped", role: .cancel) {
                appState.portConflictAlert = nil
            }
        } message: { alertData in
            Text("Another process is using port \(alertData.conflictingPort). Try port \(alertData.suggestedPort) instead?")
        }
        // New endpoint sheet
        .sheet(isPresented: $appState.showNewEndpointSheet) {
            NewEndpointSheet { name, method, path in
                if let endpoint = appState.addEndpoint(name: name, method: method, path: path) {
                    selectedEndpointID = endpoint.id
                }
            }
        }
        // Generic server error alert
        .alert(
            "Server error",
            isPresented: $appState.isShowingGenericStartError,
            presenting: appState.genericStartError
        ) { _ in
            Button("OK") { appState.genericStartError = nil }
        } message: { error in
            Text(error)
        }
        // HAR import sheet
        .sheet(isPresented: $showHARImport) {
            ImportView(
                kind: .har,
                existingEndpoints: currentEndpoints,
                onCommitImport: appState.commitImportedCandidates
            )
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
            withAnimation(DSAnimation.drawerToggle) { showInspector = true }
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
    }

    // MARK: - Breadcrumb

    /// Where the centre pane can go from here.
    ///
    /// The lateral moves the jump bar used to offer as crumb menus, minus the two that did not earn
    /// a second home: the project crumb carried no options at all, and the scenario crumb's job is
    /// taken by the inspector's Scenarios list today and by `DSScenarioControl` in the editor's own
    /// title row shortly. See ``CenterPaneNavigation``.
    private var centerPaneNavigation: CenterPaneNavigation {
        CenterPaneNavigation(
            canGoBack: endpointHistory.canGoBack,
            canGoForward: endpointHistory.canGoForward,
            jumpSections: jumpSections,
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
            },
            onJump: handleCenterPaneJump
        )
    }

    private var jumpSections: [CenterPaneNavigation.JumpSection] {
        switch navigatorTab {
        case .journeys:
            let journeys = appState.journeys
            return [
                CenterPaneNavigation.JumpSection(
                    id: "journey",
                    title: "Journeys",
                    options: journeys.map {
                        CenterPaneNavigation.Option(
                            id: $0.id,
                            title: $0.name,
                            isSelected: $0.id == appState.selectedJourneyID
                        )
                    }
                )
            ]

        case .endpoints:
            let endpoints = currentEndpoints
            guard let endpoint = endpoints.first(where: { $0.id == selectedEndpointID }) else {
                return []
            }

            var sections: [CenterPaneNavigation.JumpSection] = []

            // The group section only earns its place when there are groups to move between.
            let groups = Set(endpoints.compactMap(\.groupTag).filter { !$0.isEmpty }).sorted()
            if let group = endpoint.groupTag, !group.isEmpty, groups.count > 1 {
                sections.append(
                    CenterPaneNavigation.JumpSection(
                        id: "group",
                        title: "Groups",
                        options: groups.compactMap { name in
                            // A group is not a thing you can select, so each option stands for the
                            // first endpoint in it — the same landing a sidebar click would give.
                            endpoints.first { $0.groupTag == name }.map {
                                CenterPaneNavigation.Option(id: $0.id, title: name, isSelected: name == group)
                            }
                        }
                    )
                )
            }

            let siblings = endpoints.filter { $0.groupTag == endpoint.groupTag }
            sections.append(
                CenterPaneNavigation.JumpSection(
                    id: "endpoint",
                    title: endpoint.groupTag.map { $0.isEmpty ? "Endpoints" : "Endpoints in \($0)" }
                        ?? "Endpoints",
                    options: siblings.map {
                        CenterPaneNavigation.Option(id: $0.id, title: $0.name, isSelected: $0.id == endpoint.id)
                    }
                )
            )

            return sections
        }
    }

    private func handleCenterPaneJump(sectionID: String, optionID: UUID) {
        switch sectionID {
        case "group", "endpoint":
            selectedEndpointID = optionID
        case "journey":
            appState.selectedJourneyID = optionID
        default:
            break
        }
    }

    // MARK: - Navigator

    /// The navigator's "+" on the Journeys tab.
    ///
    /// Shaped like `DSPanelHeaderButton` rather than using it, because that type is a `Button` and
    /// this has to be a `Menu`. The geometry is copied deliberately — 22pt target, 13pt glyph, `sm`
    /// well, `labelSecondary` → `labelPrimary` on hover — so it sits in the strip as one of the
    /// buttons beside it rather than as a third kind of control. `EndpointEditorView.moreMenu` is
    /// the same shape for the same reason.
    private var addJourneyMenu: some View {
        Menu {
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
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isAddJourneyHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(isAddJourneyHovered ? DSColors.accentSubtle : Color.clear)
        }
        .onHover { isAddJourneyHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isAddJourneyHovered)
        .help("Add a journey")
        .accessibilityIdentifier("journeys.addJourneyButton")
        .accessibilityLabel("Add journey")
    }

    /// One panel, two lists, an icon strip to switch them — Xcode's navigator, at Mimic's scale.
    @ViewBuilder
    private var navigator: some View {
        @Bindable var appState = appState

        VStack(spacing: 0) {
            // The strip *is* the navigator's chrome — there is no title row under it. The selected
            // tab already says which list you are in, so a header repeating it would cost a second
            // 30pt row before a sidebar showed its first endpoint.
            DSTabStrip(
                tabs: NavigatorTab.allCases.map { tab in
                    DSTabStrip.Tab(
                        id: tab.id,
                        systemImage: tab.systemImage,
                        help: tab.help,
                        // The badge is the point of putting journeys here: a running journey is
                        // overriding every endpoint you look at, and you should not have to open a
                        // window to find that out.
                        badge: tab == .journeys && appState.activeJourney != nil ? 1 : nil
                    )
                },
                selection: navigatorTabBinding,
                identifier: "navigator",
                host: .sidebar
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

            switch navigatorTab {
            case .endpoints:
                SidebarView(
                    projectName: appState.currentProject?.name,
                    endpoints: currentEndpoints,
                    selectedEndpointID: $selectedEndpointID,
                    onDeleteEndpoint: appState.deleteEndpoint,
                    onDuplicateEndpoint: { appState.duplicateEndpoint(id: $0)?.id },
                    onAddEndpoint: { appState.showNewEndpointSheet = true }
                )
            case .journeys:
                JourneyNavigatorList(
                    journeys: appState.journeys,
                    activeJourneyID: appState.activeJourney?.id,
                    activeProgress: activeJourneyProgress,
                    selectedJourneyID: $appState.selectedJourneyID,
                    onActivate: appState.activateJourney,
                    onAdd: {
                        if let journey = appState.addJourney(name: "New journey") {
                            appState.selectedJourneyID = journey.id
                        }
                    },
                    onDuplicate: { _ = appState.duplicateJourney(id: $0) },
                    onDelete: appState.deleteJourney,
                    onRestart: appState.restartActiveJourney,
                    onAdvance: appState.advanceActiveJourney
                )
            }
        }
    }

    /// `DSTabStrip` speaks in raw ids so it can stay in the design system without knowing what a
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
            endpointScope: $logEndpointScope,
            onCreateEndpoint: { method, path in
                if let endpoint = appState.addEndpoint(
                    name: EndpointFromLog.suggestedName(method: method, path: path),
                    method: method,
                    path: path
                ) {
                    selectedEndpointID = endpoint.id
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
            guard let id = selectedEndpointID else { return nil }
            return appState.currentProject?.endpoints.first { $0.id == id }
        }()
        let detail = requestDetailContext

        InspectorPanelView(
            endpoint: endpoint,
            requestDetail: detail,
            // Always supplied, not only when nothing else is selected. That guard was right when
            // the inspector's mode was a pure derivation — overview was the fallback, so computing
            // it otherwise was waste. With a mode rail the user can *choose* it, and gating it on
            // "nothing selected" made Overview permanently dim the moment you clicked an endpoint:
            // the one mode you might want while working on something, unreachable while working on
            // something. Precedence is unchanged; only availability is.
            overview: inspectorOverview,
            endpointTraffic: endpoint.map {
                EndpointTrafficQuery.logs(forEndpoint: $0.id, in: appState.requestLogs)
            } ?? [],
            onShowJourneys: { navigatorTab = .journeys },
            onCloseRequestDetail: { selectedLogIDs = [] },
            onShowEndpointTraffic: { endpointID in
                // Scope the log rather than open a panel, and make sure it is on screen — a filter
                // applied to a hidden drawer is a click that appears to do nothing.
                logEndpointScope = endpointID
                showUnmatchedOnly = false
                showDrawer = true
            },
            onAddScenario: { _ = appState.addScenario(endpointID: $0, name: $1) },
            onSetActiveScenario: appState.setActiveScenario,
            onDuplicateScenario: { _ = appState.duplicateScenario(endpointID: $0, scenarioID: $1) },
            onDeleteScenario: appState.deleteScenario
        )
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
            port: appState.serverState.runningPort
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
}
