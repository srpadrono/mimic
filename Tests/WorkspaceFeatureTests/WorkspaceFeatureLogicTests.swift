import AppKit
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

@Suite("WorkspaceFeature Logic")
@MainActor
struct WorkspaceFeatureLogicTests {
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
    func requestLogQuerySortsByDerivedNames() {
        let beta = makeEndpoint(name: "Beta", path: "/beta", groupTag: "Beta")
        let alpha = makeEndpoint(name: "Alpha", path: "/alpha", groupTag: "Alpha")
        let betaScenario = try! #require(beta.scenarios.last)
        let alphaScenario = try! #require(alpha.scenarios.first)

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

    @Test("Request log formatter includes status headers and body")
    func requestLogFormatterBuildsPasteboardText() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint, statusCode: 202, body: #"{"queued":true}"#, timestamp: 1_710_000_000)

        let text = RequestLogQuery.formattedDetails(for: log)

        #expect(text.contains("GET /api/users"))
        #expect(text.contains("Status: 202"))
        #expect(text.contains("Headers:"))
        #expect(text.contains("X-Trace-ID"))
        #expect(text.contains("Body:"))
        #expect(text.contains(#"{"queued":true}"#))
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
    func hostingRequestLogAndScenarioViewsDoesNotTrap() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint, timestamp: 1_710_000_000)
        let emptyLog = makeLog(endpoint: endpoint, body: nil, timestamp: 1_710_000_010)
        let activeScenario = try! #require(endpoint.scenarios.first)
        let inactiveScenario = try! #require(endpoint.scenarios.last)
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
            },
            size: CGSize(width: 900, height: 120)
        )
        render(RequestDetailInspector(log: log, initialTab: .summary))
        render(RequestDetailInspector(log: log, initialTab: .headers))
        render(RequestDetailInspector(log: log, initialTab: .body))
        render(RequestDetailInspector(log: emptyLog, initialTab: .body))
        render(RequestDetailInspector(log: log, initialTab: .body, initialSearchText: "queued"))
        // A request that arrived with no headers at all, in the tab whose whole content is headers —
        // and in a 300pt-wide panel, which is the width the inspector is actually dragged to.
        render(
            RequestDetailInspector(log: headerlessLog, initialTab: .headers),
            size: CGSize(width: 300, height: 700)
        )

        render(
            ScenarioListView(
                endpoint: endpoint,
                onSetActive: { _, _ in },
                onDuplicate: { _, _ in },
                onDelete: { _, _ in }
            )
        )
        render(
            VStack(spacing: 12) {
                ScenarioRow(
                    scenario: activeScenario,
                    isActive: true,
                    isOnlyScenario: false,
                    onTap: {},
                    onDuplicate: {},
                    onDelete: {}
                )
                ScenarioRow(
                    scenario: inactiveScenario,
                    isActive: false,
                    isOnlyScenario: true,
                    onTap: {},
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

    @Test("Request log helpers handle missing names and minimal payloads")
    func requestLogHelpersHandleMissingData() {
        let endpoint = makeEndpoint()
        let emptyLog = RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_050),
            method: .get,
            path: "/missing",
            requestHeaders: [:],
            requestBody: nil,
            matchedEndpointID: endpoint.id,
            matchedScenarioID: nil,
            responseStatusCode: nil
        )

        #expect(RequestLogQuery.endpointName(for: nil, endpoints: [endpoint]) == nil)
        #expect(RequestLogQuery.scenarioName(endpointID: nil, scenarioID: nil, endpoints: [endpoint]) == nil)
        #expect(RequestLogQuery.scenarioName(endpointID: UUID(), scenarioID: UUID(), endpoints: [endpoint]) == nil)

        let formatted = RequestLogQuery.formattedDetails(for: emptyLog)
        #expect(formatted.contains("GET /missing"))
        #expect(formatted.contains("Headers:") == false)
        #expect(formatted.contains("Body:") == false)
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

    @Test("Server toggle helper starts and stops only for actionable states")
    func serverToggleHelperPerformsExpectedAction() {
        var startCount = 0
        var stopCount = 0

        ServerToggleButton.performAction(
            serverState: .stopped,
            onStart: { startCount += 1 },
            onStop: { stopCount += 1 }
        )
        ServerToggleButton.performAction(
            serverState: .error("Boom"),
            onStart: { startCount += 1 },
            onStop: { stopCount += 1 }
        )
        ServerToggleButton.performAction(
            serverState: .running(port: 8080),
            onStart: { startCount += 1 },
            onStop: { stopCount += 1 }
        )
        ServerToggleButton.performAction(
            serverState: .starting,
            onStart: { startCount += 1 },
            onStop: { stopCount += 1 }
        )

        #expect(startCount == 2)
        #expect(stopCount == 1)
    }

    @Test("New scenario helper trims whitespace and rejects empty names")
    func newScenarioNameSanitizer() {
        #expect(NewScenarioSheet.sanitizedName(from: "  Unauthorized  ") == "Unauthorized")
        #expect(NewScenarioSheet.sanitizedName(from: "   ") == nil)

        var confirmedName: String?
        var dismissCount = 0
        NewScenarioSheet.performConfirm(
            rawName: "  Needs auth  ",
            onConfirm: { confirmedName = $0 },
            dismiss: { dismissCount += 1 }
        )
        NewScenarioSheet.performConfirm(
            rawName: "   ",
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

        let collapsed = SidebarView.updatedCollapsedSections(["Users"], name: "Users", isExpanded: true)
        #expect(collapsed.isEmpty)

        let expanded = SidebarView.updatedCollapsedSections([], name: "Admin", isExpanded: false)
        #expect(expanded == ["Admin"])

        let endpoint = makeEndpoint(name: "Accounts", path: "/accounts")
        var deletedID: UUID?
        var duplicatedID: UUID?
        #expect(SidebarView.clearedSearchText().isEmpty)
        #expect(SidebarView.deleteTarget(for: endpoint).name == "Accounts")
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
    }

    @Test("Request log copy helper writes formatted details to the pasteboard")
    func requestLogCopyHelper() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint, statusCode: 202, body: #"{"queued":true}"#, timestamp: 1_710_000_000)

        NSPasteboard.general.clearContents()
        RequestDetailInspector.write(RequestLogQuery.formattedDetails(for: log), to: .general)

        let copied = NSPasteboard.general.string(forType: .string)
        #expect(copied?.contains("Status: 202") == true)
        #expect(copied?.contains(#"{"queued":true}"#) == true)
    }

    @Test("Byte summary reads in the units a person uses")
    func byteSummaryFormatsSizes() {
        #expect(RequestDetailInspector.byteSummary(nil) == "\u{2014}")
        #expect(RequestDetailInspector.byteSummary("") == "\u{2014}")
        #expect(RequestDetailInspector.byteSummary("abc") == "3 B")
        #expect(RequestDetailInspector.byteSummary(String(repeating: "a", count: 2048)) == "2.0 KB")
    }

    @Test("Inspector mode follows selection precedence")
    func inspectorModePrecedence() {
        // A selected request wins over an endpoint, which wins over the overview. The order matters:
        // clicking a log row must not be swallowed by an endpoint that was already selected.
        #expect(
            InspectorPanelView.mode(hasRequestDetail: true, hasEndpoint: true, hasOverview: true) == .request
        )
        #expect(
            InspectorPanelView.mode(hasRequestDetail: false, hasEndpoint: true, hasOverview: true) == .scenarios
        )
        #expect(
            InspectorPanelView.mode(hasRequestDetail: false, hasEndpoint: false, hasOverview: true) == .overview
        )
        #expect(
            InspectorPanelView.mode(hasRequestDetail: false, hasEndpoint: false, hasOverview: false) == .empty
        )
        #expect(InspectorPanelView.Mode.request.title == "Request")
    }
}
