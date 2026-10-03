import AppKit
import SwiftUI
import Testing
import Domain
@testable import AppFeatures
@testable import EndpointsFeature
@testable import JourneysFeature
@testable import RequestLogFeature
@testable import ServerFeature
@testable import WorkspaceShell

@Suite("WorkspaceFeature Logic")
@MainActor
struct WorkspaceFeatureLogicTests {
    @Test("A named journey group cannot share the ungrouped collapse key")
    func journeyGroupKeysDoNotCollide() {
        #expect(JourneyNavigatorList.groupSectionKey("__ungrouped__") != "__ungrouped__")
        #expect(JourneyNavigatorList.groupSectionKey("Checkout") == "group:Checkout")
        #expect(SidebarView.groupSectionKey("__ungrouped__") != "__ungrouped__")
        #expect(SidebarView.groupSectionKey("Users") == "group:Users")
    }

    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 960, height: 720),
        wait: TimeInterval = 0.1
    ) -> CGSize {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.orderFront(nil)
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    private func makeEndpoint(
        name: String = "Users",
        path: String = "/api/users",
        method: HTTPMethod = .get,
        groupTag: String? = "Users"
    ) -> Endpoint {
        let activeScenario = Scenario(
            name: "OK",
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"status":"ok"}"#
        )
        let alternateScenario = Scenario(name: "Unauthorized", statusCode: 401)
        return Endpoint(
            name: name,
            method: method,
            path: path,
            scenarios: [activeScenario, alternateScenario],
            activeScenarioID: activeScenario.id,
            delayMs: 40,
            groupTag: groupTag
        )
    }

    private func makeLog(
        endpoint: Endpoint,
        scenarioID: UUID? = nil,
        method: HTTPMethod? = nil,
        path: String? = nil,
        statusCode: Int = 200,
        body: String? = #"{"query":"users"}"#,
        timestamp: TimeInterval
    ) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: timestamp),
            method: method ?? endpoint.method,
            path: path ?? endpoint.path,
            requestHeaders: [
                "Accept": "application/json",
                "X-Trace-ID": "trace-123",
            ],
            requestBody: body,
            matchedEndpointID: endpoint.id,
            matchedScenarioID: scenarioID ?? endpoint.activeScenarioID,
            responseStatusCode: statusCode
        )
    }

    @Test("Request log query filters by method and text")
    func requestLogQueryFilters() {
        let users = makeEndpoint(name: "Users", path: "/api/users")
        let posts = makeEndpoint(name: "Posts", path: "/api/posts", method: .post, groupTag: "Posts")
        let logs = [
            makeLog(endpoint: users, timestamp: 1_710_000_000),
            makeLog(endpoint: posts, statusCode: 201, timestamp: 1_710_000_100),
        ]

        let filtered = RequestLogQuery.process(
            logs: logs,
            endpoints: [users, posts],
            methodFilter: .post,
            filterText: "201",
            sortField: .timestamp,
            sortAscending: false
        )

        #expect(filtered.count == 1)
        #expect(filtered.first?.matchedEndpointID == posts.id)
    }

    @Test("Request log query sorts using endpoint and scenario names")
    func requestLogQuerySortsByDerivedNames() throws {
        let beta = makeEndpoint(name: "Beta", path: "/beta", groupTag: "Beta")
        let alpha = makeEndpoint(name: "Alpha", path: "/alpha", groupTag: "Alpha")
        let betaScenario = try #require(beta.scenarios.last)
        let alphaScenario = try #require(alpha.scenarios.first)

        let logs = [
            makeLog(endpoint: beta, scenarioID: betaScenario.id, timestamp: 1_710_000_100),
            makeLog(endpoint: alpha, scenarioID: alphaScenario.id, timestamp: 1_710_000_000),
        ]

        let endpointSorted = RequestLogQuery.process(
            logs: logs,
            endpoints: [beta, alpha],
            methodFilter: nil,
            filterText: "",
            sortField: .endpoint,
            sortAscending: true
        )
        let scenarioSorted = RequestLogQuery.process(
            logs: logs,
            endpoints: [beta, alpha],
            methodFilter: nil,
            filterText: "",
            sortField: .scenario,
            sortAscending: true
        )

        #expect(endpointSorted.first?.matchedEndpointID == alpha.id)
        #expect(scenarioSorted.first?.matchedScenarioID == alphaScenario.id)
        #expect(RequestLogQuery.endpointName(for: alpha.id, endpoints: [alpha, beta]) == "Alpha")
        #expect(RequestLogQuery.scenarioName(endpointID: beta.id, scenarioID: betaScenario.id, endpoints: [alpha, beta]) == "Unauthorized")
    }

    @Test("Sidebar query groups and filters endpoints")
    func sidebarQueryGroupsEndpoints() {
        let grouped = makeEndpoint(name: "Users", path: "/api/users", groupTag: "Accounts")
        let methodMatch = makeEndpoint(name: "Create Post", path: "/api/posts", method: .post, groupTag: nil)
        let hidden = makeEndpoint(name: "Health", path: "/health", groupTag: nil)

        let result = SidebarQuery.sections(
            endpoints: [grouped, methodMatch, hidden],
            searchText: "post"
        )

        #expect(result.grouped.isEmpty)
        #expect(result.ungrouped.count == 1)
        #expect(result.ungrouped.first?.id == methodMatch.id)

        let groupedResult = SidebarQuery.sections(
            endpoints: [grouped, methodMatch, hidden],
            searchText: ""
        )
        #expect(groupedResult.grouped.map(\.name) == ["Accounts"])
        #expect(groupedResult.grouped.first?.endpoints.first?.id == grouped.id)
        #expect(groupedResult.ungrouped.count == 2)
    }

    @Test("Sidebar groups keep the project's order, not the alphabet's")
    func sidebarQueryKeepsProjectGroupOrder() {
        let endpoints = [
            makeEndpoint(name: "Products", path: "/products", groupTag: "Catalog"),
            makeEndpoint(name: "Summary", path: "/account-summary", groupTag: "Account"),
            makeEndpoint(name: "Cart", path: "/cart", method: .post, groupTag: "Catalog"),
            makeEndpoint(name: "Pay", path: "/payments", method: .post, groupTag: "Payments"),
        ]

        let result = SidebarQuery.sections(endpoints: endpoints, searchText: "")

        #expect(result.grouped.map(\.name) == ["Catalog", "Account", "Payments"])
        #expect(result.grouped.first?.endpoints.map(\.name) == ["Products", "Cart"])
    }

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// Everything else here asserts on values, which is the right shape for logic — but a value test
    /// never makes the view, so it cannot catch a trap in layout. These renders can: the request
    /// detail, the scenario list and the new-scenario sheet each carry `@State` that is initialised
    /// the first time they are hosted and never before.
    ///
    /// It replaces ten `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`, a
    /// quantity that has no negative values to find. Where these views have geometry worth pinning it
    /// belongs beside the component that owns it — `DSComponentRenderingTests` measures the panel
    /// chrome and the method badge — rather than being re-measured through a whole panel here.
    @Test("Hosting the request log and scenario views does not trap during layout")
    func hostingRequestLogAndScenarioViewsDoesNotTrap() throws {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint, timestamp: 1_710_000_000)
        let emptyLog = makeLog(endpoint: endpoint, body: nil, timestamp: 1_710_000_010)
        let activeScenario = try #require(endpoint.scenarios.first)
        let inactiveScenario = try #require(endpoint.scenarios.last)
        let headerlessLog = RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_200),
            method: endpoint.method,
            path: endpoint.path,
            requestHeaders: [:],
            requestBody: #"{"empty":true}"#,
            matchedEndpointID: endpoint.id,
            matchedScenarioID: endpoint.activeScenarioID,
            responseStatusCode: 200
        )
        let failedLog = RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_300),
            method: .post,
            path: "/api/orders?draft=true",
            listenerPort: 8080,
            durationMs: 30_000,
            failureLabel: "timeout(30000ms)",
            outcome: .proxyFailure
        )
        let passthroughLog = RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_400),
            method: .get,
            path: "/api/live",
            backendName: "Staging",
            listenerPort: 8080,
            upstreamURL: "https://staging.example.test/api/live",
            durationMs: 42,
            responseStatusCode: 200,
            responseHeaders: ["Content-Type": "application/json"],
            responseBody: #"{"live":true}"#,
            outcome: .passthrough
        )

        render(
            VStack(spacing: 12) {
                RequestLogTableRow(
                    log: log,
                    rowIndex: 0,
                    isSelected: true,
                    endpointName: endpoint.name,
                    scenarioName: "OK",
                    onSelect: { _ in }
                )
                RequestLogTableRow(
                    log: log,
                    rowIndex: 1,
                    isSelected: false,
                    endpointName: nil,
                    scenarioName: nil,
                    onSelect: { _ in }
                )
                // Selected in an unfocused table, compact, at the measured path width the live
                // table hands its rows.
                RequestLogTableRow(
                    log: log,
                    rowIndex: 2,
                    isSelected: true,
                    isEmphasized: false,
                    compact: true,
                    pathWidth: LogColumns.minimumPath,
                    endpointName: endpoint.name,
                    scenarioName: nil,
                    onSelect: { _ in }
                )
                // A request that reached no configuration and got no answer: the Scenario cell's
                // unnamed arms, and the Duration and Size cells' em dashes.
                RequestLogTableRow(
                    log: failedLog,
                    rowIndex: 3,
                    isSelected: false,
                    endpointName: nil,
                    scenarioName: nil,
                    onSelect: { _ in }
                )
            },
            size: CGSize(width: 900, height: 160)
        )
        render(RequestDetailView(log: log, initialTab: .request))
        render(RequestDetailView(log: log, initialTab: .response))
        render(RequestDetailView(log: log, initialTab: .timing))
        render(RequestDetailView(log: emptyLog, initialTab: .request))
        render(RequestDetailView(log: emptyLog, initialTab: .response))
        // A failed exchange draws its failure in the status line and the empty response sections.
        render(RequestDetailView(log: failedLog, initialTab: .request))
        render(RequestDetailView(log: failedLog, initialTab: .response))
        render(RequestDetailView(log: failedLog, initialTab: .timing))
        // A passed-through request offers the capture control in its header.
        render(RequestDetailView(log: passthroughLog, port: 8080, onSaveAsMock: { _ in }, initialTab: .response))
        // An endpoint that answered can be opened, and the detail can be closed.
        render(
            RequestDetailView(
                context: RequestDetailView.Context(log: log, endpointName: endpoint.name, scenarioName: "OK",
                                                   endpointExists: true, port: 8080),
                onGoToEndpoint: { _ in },
                onClose: {}
            ),
            size: CGSize(width: 640, height: 600)
        )
        // A request that arrived with no headers at all, in the tab that lists request headers —
        // and at the narrowest the detail gets beside the list.
        render(
            RequestDetailView(log: headerlessLog, initialTab: .request),
            size: CGSize(width: 300, height: 700)
        )

        render(
            ScenarioListView(
                endpoint: endpoint,
                editedScenarioID: inactiveScenario.id,
                onSetActive: { _, _ in },
                onDuplicate: { _, _ in },
                onDelete: { _, _ in }
            )
        )
        render(
            VStack(spacing: 12) {
                // Live and edited, then neither: the two states the redesigned row draws apart.
                ScenarioRow(
                    scenario: activeScenario,
                    isActive: true,
                    isEdited: true,
                    isOnlyScenario: false,
                    onTap: {},
                    onMakeLive: {},
                    onDuplicate: {},
                    onDelete: {}
                )
                ScenarioRow(
                    scenario: inactiveScenario,
                    isActive: false,
                    isEdited: false,
                    isOnlyScenario: true,
                    onTap: {},
                    onMakeLive: {},
                    onDuplicate: {},
                    onDelete: {}
                )
            },
            size: CGSize(width: 420, height: 140)
        )
        render(NewScenarioSheet { _ in })
    }


    @Test("Request log query covers path status and descending timestamp sorts")
    func requestLogQueryAdditionalSorts() {
        let users = makeEndpoint(name: "Users", path: "/api/users")
        let posts = makeEndpoint(name: "Posts", path: "/api/posts", method: .post, groupTag: "Posts")
        let logs = [
            makeLog(endpoint: users, statusCode: 204, timestamp: 1_710_000_000),
            makeLog(endpoint: posts, statusCode: 500, timestamp: 1_710_000_100),
        ]

        let pathSorted = RequestLogQuery.process(
            logs: logs,
            endpoints: [users, posts],
            methodFilter: nil,
            filterText: "",
            sortField: .path,
            sortAscending: true
        )
        let statusSorted = RequestLogQuery.process(
            logs: logs,
            endpoints: [users, posts],
            methodFilter: nil,
            filterText: "",
            sortField: .status,
            sortAscending: false
        )
        let timestampSorted = RequestLogQuery.process(
            logs: logs,
            endpoints: [users, posts],
            methodFilter: nil,
            filterText: "",
            sortField: .timestamp,
            sortAscending: false
        )

        #expect(pathSorted.first?.path == "/api/posts")
        #expect(statusSorted.first?.responseStatusCode == 500)
        #expect(timestampSorted.first?.timestamp == Date(timeIntervalSince1970: 1_710_000_100))
    }

    @Test("Request log helpers handle missing names")
    func requestLogHelpersHandleMissingData() {
        let endpoint = makeEndpoint()

        #expect(RequestLogQuery.endpointName(for: nil, endpoints: [endpoint]) == nil)
        #expect(RequestLogQuery.scenarioName(endpointID: nil, scenarioID: nil, endpoints: [endpoint]) == nil)
        #expect(RequestLogQuery.scenarioName(endpointID: UUID(), scenarioID: UUID(), endpoints: [endpoint]) == nil)
    }

    @Test("Request log selection and clear helpers keep state consistent")
    func requestLogSelectionHelpers() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint, timestamp: 1_710_000_300)
        var didClear = false

        #expect(
            RequestLogDrawerView.selectedLogs(
                selectedLogIDs: [log.id],
                sortedAndFilteredLogs: [log]
            ).map(\.id) == [log.id]
        )
        // A plain click selects, and clicking the same row again clears — which is how the inspector's
        // request detail gets dismissed without reaching for the close button.
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [],
                anchor: nil,
                tapped: log.id,
                modifier: .replace,
                displayOrder: [log.id]
            ) == .init(selection: [log.id], anchor: log.id)
        )
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [log.id],
                anchor: log.id,
                tapped: log.id,
                modifier: .replace,
                displayOrder: [log.id]
            ) == .init(selection: [], anchor: nil)
        )
        #expect(RequestLogDrawerView.performClear {
            didClear = true
        } == [])
        #expect(didClear)
    }

    /// The modifier rules, which are the part of a selection model that looks obviously right and is
    /// wrong at the edges. None of these is observable in a screenshot.
    @Test("Modifier clicks build the selection the way a macOS list does")
    func requestLogMultiSelection() {
        let ids = (0..<5).map { _ in UUID() }

        // ⌘ adds without disturbing the rest, and removes when the row is already in.
        let added = RequestLogDrawerView.nextSelection(
            current: [ids[0]],
            anchor: ids[0],
            tapped: ids[2],
            modifier: .toggle,
            displayOrder: ids
        )
        #expect(added == .init(selection: [ids[0], ids[2]], anchor: ids[2]))

        let removed = RequestLogDrawerView.nextSelection(
            current: [ids[0], ids[2]],
            anchor: ids[2],
            tapped: ids[2],
            modifier: .toggle,
            displayOrder: ids
        )
        // The anchor was the row just deselected, so it moves to one still selected — otherwise the
        // next ⇧-click would measure a range from a row that is no longer part of the selection.
        #expect(removed == .init(selection: [ids[0]], anchor: ids[0]))

        // ⇧ takes the run between anchor and click, in either direction.
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [ids[1]],
                anchor: ids[1],
                tapped: ids[3],
                modifier: .extend,
                displayOrder: ids
            ) == .init(selection: [ids[1], ids[2], ids[3]], anchor: ids[1])
        )
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [ids[3]],
                anchor: ids[3],
                tapped: ids[1],
                modifier: .extend,
                displayOrder: ids
            ) == .init(selection: [ids[1], ids[2], ids[3]], anchor: ids[3])
        )

        // ⇧ keeps what was picked with ⌘ rather than replacing it: losing a careful selection is a
        // worse surprise than gaining a row.
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [ids[0], ids[3]],
                anchor: ids[3],
                tapped: ids[4],
                modifier: .extend,
                displayOrder: ids
            ).selection == [ids[0], ids[3], ids[4]]
        )

        // ⇧ with no anchor behaves like a plain click. Doing nothing would read as a broken control.
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [],
                anchor: nil,
                tapped: ids[2],
                modifier: .extend,
                displayOrder: ids
            ) == .init(selection: [ids[2]], anchor: ids[2])
        )

        // An anchor left over from before the selection was replaced from outside the table — which
        // is what selecting a request from an endpoint's traffic list does — measures from the row
        // that is actually selected, not from the row last clicked here.
        #expect(
            RequestLogDrawerView.nextSelection(
                current: [ids[3]],
                anchor: ids[0],
                tapped: ids[4],
                modifier: .extend,
                displayOrder: ids
            ).selection == [ids[3], ids[4]]
        )
    }

    @Test("A held chord resolves to one meaning, with command winning")
    func selectionModifierFromFlags() {
        #expect(RequestLogDrawerView.SelectionModifier([]) == .replace)
        #expect(RequestLogDrawerView.SelectionModifier(.command) == .toggle)
        #expect(RequestLogDrawerView.SelectionModifier(.shift) == .extend)
        // ⌘⇧ toggles rather than replacing: of the two readings, the one that cannot discard a
        // selection is the right default.
        #expect(RequestLogDrawerView.SelectionModifier([.command, .shift]) == .toggle)
    }

    @Test("Run and Stop availability follows each server state")
    func serverControlsEnableOnlyActionableStates() {
        #expect(ServerToggleButton.canStart(in: .stopped))
        #expect(ServerToggleButton.canStart(in: .error("Port in use")))
        #expect(!ServerToggleButton.canStart(in: .starting))
        #expect(!ServerToggleButton.canStart(in: .running(port: 8080)))
        #expect(!ServerToggleButton.canStart(in: .stopping))
        #expect(ServerToggleButton.canStop(in: .running(port: 8080)))
        #expect(!ServerToggleButton.canStop(in: .stopped))
        #expect(!ServerToggleButton.canStop(in: .starting))
        #expect(!ServerToggleButton.canStop(in: .stopping))
        #expect(!ServerToggleButton.canStop(in: .error("Port in use")))
    }

    @Test("New scenario helper trims whitespace and rejects empty names")
    func newScenarioNameSanitizer() {
        #expect(NewScenarioSheet.sanitizedName(from: "  Unauthorized  ") == "Unauthorized")
        #expect(NewScenarioSheet.sanitizedName(from: "   ") == nil)
        #expect(NewScenarioSheet.sanitizedName(from: "\n\r\t ") == nil)
        #expect(NewScenarioSheet.sanitizedName(from: "\n  Needs auth \r\n") == "Needs auth")

        var confirmedName: String?
        var dismissCount = 0
        NewScenarioSheet.performConfirm(
            rawName: "\n  Needs auth \r\n",
            onConfirm: { confirmedName = $0 },
            dismiss: { dismissCount += 1 }
        )
        NewScenarioSheet.performConfirm(
            rawName: "\n\r\t ",
            onConfirm: { confirmedName = $0 },
            dismiss: { dismissCount += 1 }
        )

        #expect(confirmedName == "Needs auth")
        #expect(dismissCount == 1)
    }

    @Test("Request log sort helper toggles repeated sorts and resets new fields")
    func requestLogSortStateHelper() {
        let toggled = RequestLogDrawerView.nextSortState(
            currentField: .method,
            currentAscending: true,
            requestedField: .method
        )
        #expect(toggled.field == .method)
        #expect(toggled.isAscending == false)

        let timestamp = RequestLogDrawerView.nextSortState(
            currentField: .method,
            currentAscending: false,
            requestedField: .timestamp
        )
        #expect(timestamp.field == .timestamp)
        #expect(timestamp.isAscending == false)

        let path = RequestLogDrawerView.nextSortState(
            currentField: .timestamp,
            currentAscending: false,
            requestedField: .path
        )
        #expect(path.field == .path)
        #expect(path.isAscending)
    }

    @Test("Sidebar helpers clear selections and track collapsed groups")
    func sidebarHelpers() {
        let selected = UUID()
        let untouched = UUID()

        #expect(SidebarView.nextSelectionAfterDeleting(selectedEndpointID: selected, targetID: selected) == nil)
        #expect(SidebarView.nextSelectionAfterDeleting(selectedEndpointID: selected, targetID: untouched) == selected)

        let collapsed = SidebarView.updatedCollapsedSections(["group:Users"], name: "group:Users", isExpanded: true)
        #expect(collapsed.isEmpty)

        let expanded = SidebarView.updatedCollapsedSections([], name: "group:Admin", isExpanded: false)
        #expect(expanded == ["group:Admin"])

        let endpoint = makeEndpoint(name: "Accounts", path: "/accounts")
        var deletedID: UUID?
        var duplicatedID: UUID?
        #expect(SidebarView.clearedSearchText().isEmpty)
        #expect(SidebarView.deleteTarget(for: endpoint).name == "Accounts")
        // The design's confirmation: the route in curly quotes, and what goes with it.
        #expect(SidebarView.deleteTarget(for: endpoint).title == "Delete \u{201C}GET /accounts\u{201D}?")
        #expect(SidebarView.deleteMessage(scenarioCount: 5)
            == "This removes the endpoint and its 5 scenarios. You can\u{2019}t undo this.")
        #expect(SidebarView.deleteMessage(scenarioCount: 1)
            == "This removes the endpoint and its scenario. You can\u{2019}t undo this.")
        let duplicated = SidebarView.performDuplicate(endpointID: endpoint.id, onDuplicate: { id in
            duplicatedID = id
            return id
        })
        #expect(duplicated == endpoint.id)
        #expect(duplicatedID == endpoint.id)
        #expect(
            SidebarView.performDelete(
                targetID: endpoint.id,
                selectedEndpointID: endpoint.id,
                onDelete: { deletedID = $0 }
            ) == nil
        )
        #expect(deletedID == endpoint.id)
        #expect(SidebarView.sectionKey(for: endpoint) == "group:Users")
        #expect(SidebarView.sectionKey(for: makeEndpoint(groupTag: nil)) == "__ungrouped__")
        #expect(SidebarView.sectionKey(for: makeEndpoint(groupTag: "")) == "__ungrouped__")
        #expect(SidebarView.sectionKey(for: makeEndpoint(groupTag: "__ungrouped__")) == "group:__ungrouped__")
    }

    @Test("Breadcrumb choices carry native selected state and select the requested destination")
    func breadcrumbOptionsUseNativeSelection() throws {
        let firstID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let secondID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        var selectedID: UUID?
        let menu = NSHostingMenu(rootView: BreadcrumbJumpBar.Options(
            crumb: .init(id: "group", title: "Accounts", options: [
                .init(id: firstID, title: "Accounts", isSelected: true),
                .init(id: secondID, title: "Orders"),
            ]),
            onSelect: { selectedID = $0 }
        ))
        menu.update()
        func item(_ title: String, in menu: NSMenu) -> (menu: NSMenu, index: Int)? {
            for (index, entry) in menu.items.enumerated() {
                if entry.title == title, entry.submenu == nil { return (menu, index) }
                if let submenu = entry.submenu, let found = item(title, in: submenu) { return found }
            }
            return nil
        }
        let first = try #require(item("Accounts", in: menu))
        let second = try #require(item("Orders", in: menu))
        #expect(first.menu.items[first.index].state == .on)
        #expect(second.menu.items[second.index].state == .off)
        second.menu.performActionForItem(at: second.index)
        #expect(selectedID == secondID)
    }

    @Test("Request log copy helper replaces the pasteboard's contents with the text")
    func requestLogCopyHelper() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("MimicTests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("stale", forType: .string)

        RequestDetailView.write("http://localhost:8080/api/users", to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "http://localhost:8080/api/users")
    }

    @Test("Byte summary reads in the units a person uses")
    func byteSummaryFormatsSizes() {
        #expect(RequestDetailView.byteSummary(nil) == "\u{2014}")
        #expect(RequestDetailView.byteSummary("") == "\u{2014}")
        #expect(RequestDetailView.byteSummary("abc") == "3 B")
        #expect(RequestDetailView.byteSummary(String(repeating: "a", count: 2048)) == "2.0 KB")
    }

    @Test("Inspector mode follows selection precedence")
    func inspectorModePrecedence() {
        // An endpoint wins over a journey, which wins over the overview. A logged request never
        // reaches the inspector: it opens in the centre column, which hides the inspector.
        #expect(InspectorPanelView.mode(hasEndpoint: true, hasOverview: true, hasJourney: true) == .scenarios)
        #expect(InspectorPanelView.mode(hasEndpoint: false, hasOverview: true, hasJourney: true) == .journey)
        #expect(InspectorPanelView.mode(hasEndpoint: false, hasOverview: true) == .overview)
        #expect(InspectorPanelView.mode(hasEndpoint: false, hasOverview: false) == .empty)
        #expect(InspectorPanelView.Mode.scenarios.title == "Scenarios")
    }

    @Test("The request detail explains what answered, naming the status Mimic returned for a miss")
    func requestDetailOutcomeExplanation() {
        let unmatched = RequestLog(method: .get, path: "/recommendations?limit=4",
                                   responseStatusCode: 404, outcome: .unmatched)
        let answered = RequestLog(method: .get, path: "/api/users", responseStatusCode: 200, outcome: .endpoint)

        #expect(RequestDetailView.outcomeExplanation(for: unmatched, endpointName: nil, scenarioName: nil)
                == "No endpoint matched, so Mimic returned 404")
        #expect(RequestDetailView.outcomeExplanation(for: answered, endpointName: "Users", scenarioName: "Default")
                == "Answered by Users, Default")
        #expect(RequestDetailView.outcomeExplanation(for: answered, endpointName: nil, scenarioName: nil)
                == "Answered by an endpoint")
    }

    @Test("Beside an open request the list takes up to 520 points and never less than the compact table")
    func splitListWidth() {
        #expect(LogColumns.splitListWidth(totalWidth: 1400) == 520)
        #expect(LogColumns.splitListWidth(totalWidth: 900) == 450)
        #expect(LogColumns.splitListWidth(totalWidth: 420) == LogColumns.compactMinimumTableWidth)
    }

    @Test("A window grown under the Dock is moved back inside the visible frame")
    func windowScreenFitMovesAWindowUpBeforeShrinkingIt() {
        // A 1024×768 display: menu bar above y 738, Dock below y 60.
        let visible = CGRect(x: 0, y: 60, width: 1024, height: 678)
        let minimum = CGSize(width: 800, height: 560)

        // Grown downward from a fixed top edge, the bottom 50pt sit under the Dock.
        let grown = CGRect(x: 60, y: 10, width: 900, height: 640)
        #expect(WindowScreenFit.fittedFrame(grown, visible: visible, minimum: minimum)
                == CGRect(x: 60, y: 60, width: 900, height: 640))

        // Taller than the screen: as tall as the visible frame, and no taller.
        let tall = CGRect(x: 60, y: 0, width: 900, height: 900)
        #expect(WindowScreenFit.fittedFrame(tall, visible: visible, minimum: minimum)
                == CGRect(x: 60, y: 60, width: 900, height: 678))

        // Never below the content's minimum, even when that cannot fit.
        let rigid = CGSize(width: 800, height: 700)
        #expect(WindowScreenFit.fittedFrame(tall, visible: visible, minimum: rigid)?.height == 700)

        // A window already on screen is left alone.
        let fits = CGRect(x: 60, y: 100, width: 900, height: 600)
        #expect(WindowScreenFit.fittedFrame(fits, visible: visible, minimum: minimum) == nil)
    }

    @Test("The welcome screen takes its own size, centred where the workspace was and kept on screen")
    func welcomeFrameIsCentredAndOnScreen() {
        let visible = CGRect(x: 0, y: 60, width: 1920, height: 990)
        let size = CGSize(width: 880, height: 560)
        // Centred on a 1280×988 workspace at the top left.
        #expect(WindowRoleFrame.centredFrame(around: CGRect(x: 0, y: 62, width: 1280, height: 988),
                                             size: size, visible: visible)
                == CGRect(x: 200, y: 276, width: 880, height: 560))
        // A workspace hard against the right edge keeps the welcome screen on screen.
        #expect(WindowRoleFrame.centredFrame(around: CGRect(x: 1800, y: 62, width: 300, height: 988),
                                             size: size, visible: visible).maxX == visible.maxX)
        // A screen smaller than the board shrinks the window to fit it.
        let small = CGRect(x: 0, y: 0, width: 800, height: 500)
        #expect(WindowRoleFrame.centredFrame(around: small, size: size, visible: small) == small)
    }

    @Test("A first workspace opens wide enough for the inspector, even on a 1024pt screen")
    func firstWorkspaceFrameLeavesRoomForTheInspector() {
        // The welcome screen centred on CI's visible frame: a 1024×768 display under a 31pt menu
        // bar and above the Dock, 1024×677 as every frame of the layout audit measured it on CI.
        let visible = CGRect(x: 0, y: 60, width: 1024, height: 677)
        let welcome = CGRect(x: 72, y: 118, width: 880, height: 561)
        let first = WindowRoleFrame.centredFrame(around: welcome, size: WindowRoleFrame.defaultWorkspaceSize,
                                                 visible: visible)
        #expect(first == CGRect(x: 0, y: 60, width: 1024, height: 677))
        // The navigator at its widest, the centre's floor beside it and the inspector at its least.
        #expect(first.width >= 976)
    }

    @Test("A pinned screen is CI's visible frame at the top left of the real one, and never larger")
    func pinnedScreenFrameSitsAtTheTopLeft() {
        let pin = CGSize(width: 1024, height: 677)
        // CI's own display: the pinned frame is its visible frame, exactly.
        let ci = CGRect(x: 0, y: 60, width: 1024, height: 677)
        #expect(ScreenGeometry.pinnedFrame(pin, in: ci) == ci)
        // A 1920×1080 display under a 37pt menu bar, Dock hidden: the top edge stays where it is.
        let large = CGRect(x: 0, y: 0, width: 1920, height: 1043)
        #expect(ScreenGeometry.pinnedFrame(pin, in: large) == CGRect(x: 0, y: 366, width: 1024, height: 677))
        // A second display left of and above the main one keeps its own origin.
        let secondary = CGRect(x: -1440, y: 1080, width: 1440, height: 875)
        #expect(ScreenGeometry.pinnedFrame(pin, in: secondary)
                == CGRect(x: -1440, y: 1278, width: 1024, height: 677))
        // A display smaller than the pin is used whole rather than overrun.
        let small = CGRect(x: 0, y: 60, width: 800, height: 540)
        #expect(ScreenGeometry.pinnedFrame(pin, in: small) == small)
    }

    @Test("On a pinned screen the welcome screen and the first workspace take the frames they take on CI")
    func pinnedScreenGivesTheWindowCIsFrames() {
        let pin = CGSize(width: 1024, height: 677)
        let ci = CGRect(x: 0, y: 60, width: 1024, height: 677)
        let pinned = ScreenGeometry.pinnedFrame(pin, in: CGRect(x: 0, y: 0, width: 1920, height: 1043))
        let welcomeSize = CGSize(width: 880, height: 560)
        // A UI test window starts at the whole pinned frame, and the welcome screen centres in it.
        // Centring on 677pt lands on a half point, which `integral` widens to 561pt on both.
        let welcomeOnCI = WindowRoleFrame.centredFrame(around: ci, size: welcomeSize, visible: ci)
        let welcomePinned = WindowRoleFrame.centredFrame(around: pinned, size: welcomeSize, visible: pinned)
        #expect(welcomeOnCI == CGRect(x: 72, y: 118, width: 880, height: 561))
        // The same size, the same distance from the top left corner: a click aimed at a control
        // lands on it on both.
        #expect(welcomePinned.size == welcomeOnCI.size)
        #expect(welcomePinned.minX - pinned.minX == welcomeOnCI.minX - ci.minX)
        #expect(pinned.maxY - welcomePinned.maxY == ci.maxY - welcomeOnCI.maxY)
        // The welcome screen records the pinned frame as the workspace's, and it needs no fitting,
        // so the first project opens filling the pinned screen.
        #expect(WindowScreenFit.fittedFrame(pinned, visible: pinned, minimum: CGSize(width: 680, height: 438)) == nil)
    }

    @Test("An open request sits beside the list only when both fit")
    func requestDetailBesideTheListOnlyWhenBothFit() {
        let both = LogColumns.compactMinimumTableWidth + LogColumns.splitDetailMinimum
        #expect(LogColumns.showsListBesideDetail(totalWidth: both))
        #expect(!LogColumns.showsListBesideDetail(totalWidth: both - 1))
        // The compact 900pt window, its 264pt navigator and the inspector stepping aside leave about
        // 620pt: the list still sits beside the request there.
        #expect(LogColumns.showsListBesideDetail(totalWidth: 620))
        #expect(!LogColumns.showsListBesideDetail(totalWidth: 488), "The narrowest window shows the request alone")
    }
}

