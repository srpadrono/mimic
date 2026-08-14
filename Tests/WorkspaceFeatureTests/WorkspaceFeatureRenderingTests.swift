import AppKit
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

@Suite("WorkspaceFeature Rendering")
@MainActor
struct WorkspaceFeatureRenderingTests {
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 1100, height: 860),
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

    private func makeEndpoint() -> Endpoint {
        let activeScenario = Scenario(
            name: "OK",
            statusCode: 200,
            headers: ["Content-Type": "application/json"],
            body: #"{"status":"ok"}"#
        )
        let alternateScenario = Scenario(name: "Unauthorized", statusCode: 401)
        return Endpoint(
            name: "Users",
            method: .get,
            path: "/api/v1/users",
            scenarios: [activeScenario, alternateScenario],
            activeScenarioID: activeScenario.id,
            delayMs: 25,
            groupTag: "Users"
        )
    }

    private func makeLog(endpoint: Endpoint) -> RequestLog {
        RequestLog(
            timestamp: Date(timeIntervalSince1970: 1_710_000_000),
            method: endpoint.method,
            path: endpoint.path,
            requestHeaders: [
                "Accept": "application/json",
                "X-Trace-ID": "trace-123",
            ],
            requestBody: #"{"query":"users"}"#,
            matchedEndpointID: endpoint.id,
            matchedScenarioID: endpoint.activeScenarioID,
            responseStatusCode: 200
        )
    }

    /// Idle is `EmptyView`, and that is the assertion.
    ///
    /// The indicator sits in a toolbar row beside controls that must not move: if the idle case drew
    /// a placeholder — or a fixed frame holding room for the word "Saved" — the row would shift every
    /// time an autosave settled, which is the kind of motion you notice without being able to name.
    /// The other three states have to draw something, or the feature is invisible.
    @Test("The idle autosave state occupies nothing, and the rest occupy something")
    func autosaveIdleStateTakesNoRoom() {
        let measure = CGSize(width: 240, height: 60)
        let idle = render(AutosaveStatusIndicator(status: .idle), size: measure)
        let saving = render(AutosaveStatusIndicator(status: .saving), size: measure)
        let saved = render(AutosaveStatusIndicator(status: .saved), size: measure)
        let failed = render(AutosaveStatusIndicator(status: .failed("Disk full")), size: measure)

        #expect(idle.height < saving.height)
        #expect(idle.height < saved.height)
        #expect(idle.height < failed.height)
        #expect(idle.width < saving.width)
    }

    /// The app's primary action keeps one footprint through the whole start/stop cycle.
    ///
    /// The glyph inside it does change size — 10pt while transitioning, 12pt otherwise — so without
    /// the fixed 34pt frame around it the toolbar would resize twice every time the server was
    /// started, and the controls beside it would slide. The number is deliberately larger than the
    /// 18–22pt every other icon control takes, which is only defensible if it is the same 34 in all
    /// five states.
    @Test("The server toggle is one size in every server state")
    func serverToggleKeepsOneFootprint() {
        let measure = CGSize(width: 120, height: 80)
        let stopped = render(ServerToggleButton(serverState: .stopped, onStart: {}, onStop: {}), size: measure)
        let starting = render(ServerToggleButton(serverState: .starting, onStart: {}, onStop: {}), size: measure)
        let running = render(ServerToggleButton(serverState: .running(port: 8080), onStart: {}, onStop: {}), size: measure)
        let stopping = render(ServerToggleButton(serverState: .stopping, onStart: {}, onStop: {}), size: measure)
        let errored = render(ServerToggleButton(serverState: .error("Port in use"), onStart: {}, onStop: {}), size: measure)

        #expect(starting == stopped)
        #expect(running == stopped)
        #expect(stopping == stopped)
        #expect(errored == stopped)
    }

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// Hosting these panels runs their layout and every `@State` initialiser in them, which is where a
    /// panel crashes if it is going to — the request log's divider used to throw
    /// `NSInternalInconsistencyException` out of `_postWindowNeedsUpdateConstraints` during layout,
    /// with no bad value anywhere for a unit test to catch.
    ///
    /// It replaces nine `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`, which
    /// cannot be negative: they made the render look like an assertion when the render *was* the
    /// assertion. The two tests above carry the geometry claims that can actually fail.
    @Test("Hosting every panel state does not trap during layout")
    func hostingPanelStatesDoesNotTrap() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint)

        render(
            InspectorPanelView(
                endpoint: nil,
                onAddScenario: { _, _ in },
                onSetActiveScenario: { _, _ in },
                onDuplicateScenario: { _, _ in },
                onDeleteScenario: { _, _ in }
            )
        )
        render(
            InspectorPanelView(
                endpoint: endpoint,
                onAddScenario: { _, _ in },
                onSetActiveScenario: { _, _ in },
                onDuplicateScenario: { _, _ in },
                onDeleteScenario: { _, _ in }
            )
        )

        render(
            RequestLogDrawerView(
                requestLogs: [],
                endpoints: [],
                onClear: {}
            )
        )
        render(
            RequestLogDrawerView(
                requestLogs: [log],
                endpoints: [endpoint],
                onClear: {}
            )
        )
        render(
            RequestLogDrawerView(
                requestLogs: [log],
                endpoints: [endpoint],
                onClear: {},
                selectedLogIDs: .constant([log.id]),
                initialFilterText: "",
                initialMethodFilter: nil,
                initialSortField: .timestamp,
                initialSortAscending: false
            )
        )

        renderSidebarStates(endpoint: endpoint)
    }

    /// Split out only to keep the smoke test above readable — the sidebar has three states worth
    /// hosting, including the one where a search matches nothing, plus the row on its own.
    private func renderSidebarStates(endpoint: Endpoint) {
        render(
            SidebarView(
                projectName: "Mimic",
                endpoints: [],
                selectedEndpointID: .constant(nil),
                onDeleteEndpoint: { _ in },
                onDuplicateEndpoint: { _ in nil },
                onAddEndpoint: {}
            )
        )
        render(
            SidebarView(
                projectName: "Mimic",
                endpoints: [
                    endpoint,
                    Endpoint(
                        name: "Health",
                        method: .get,
                        path: "/health",
                        scenarios: endpoint.scenarios,
                        activeScenarioID: endpoint.activeScenarioID,
                        delayMs: 0,
                        groupTag: nil
                    ),
                ],
                selectedEndpointID: .constant(endpoint.id),
                onDeleteEndpoint: { _ in },
                onDuplicateEndpoint: { _ in UUID() },
                onAddEndpoint: {}
            )
        )
        render(
            SidebarView(
                projectName: "Mimic",
                endpoints: [endpoint],
                selectedEndpointID: .constant(nil),
                onDeleteEndpoint: { _ in },
                onDuplicateEndpoint: { _ in nil },
                onAddEndpoint: {},
                initialSearchText: "zzz",
                initialCollapsedSections: []
            )
        )
        render(
            EndpointSidebarRow(endpoint: endpoint),
            size: CGSize(width: 320, height: 60)
        )
    }
}
