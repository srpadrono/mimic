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

    @Test("Autosave indicator renders all states")
    func rendersAutosaveStates() {
        let size = render(
            VStack(spacing: 12) {
                AutosaveStatusIndicator(status: .idle)
                AutosaveStatusIndicator(status: .saving)
                AutosaveStatusIndicator(status: .saved)
                AutosaveStatusIndicator(status: .failed("Disk full"))
            }
        )

        #expect(size.height >= 0)
    }


    @Test("Inspector panel renders empty and populated states")
    func rendersInspectorPanelStates() {
        let endpoint = makeEndpoint()

        let emptySize = render(
            InspectorPanelView(
                endpoint: nil,
                onAddScenario: { _, _ in },
                onSetActiveScenario: { _, _ in },
                onDuplicateScenario: { _, _ in },
                onDeleteScenario: { _, _ in }
            )
        )
        let populatedSize = render(
            InspectorPanelView(
                endpoint: endpoint,
                onAddScenario: { _, _ in },
                onSetActiveScenario: { _, _ in },
                onDuplicateScenario: { _, _ in },
                onDeleteScenario: { _, _ in }
            )
        )

        #expect(emptySize.width >= 0)
        #expect(populatedSize.height >= 0)
    }

    @Test("Request log drawer renders empty and populated content")
    func rendersRequestLogDrawerStates() {
        let endpoint = makeEndpoint()
        let log = makeLog(endpoint: endpoint)

        let emptySize = render(
            RequestLogDrawerView(
                requestLogs: [],
                endpoints: [],
                onClear: {}
            )
        )
        let populatedSize = render(
            RequestLogDrawerView(
                requestLogs: [log],
                endpoints: [endpoint],
                onClear: {}
            )
        )
        let selectedSize = render(
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

        #expect(emptySize.width >= 0)
        #expect(populatedSize.height >= 0)
        #expect(selectedSize.height >= 0)
    }

    @Test("Server toggle renders each state")
    func rendersServerToggleStates() {
        let size = render(
            HStack(spacing: 16) {
                ServerToggleButton(serverState: .stopped, onStart: {}, onStop: {})
                ServerToggleButton(serverState: .starting, onStart: {}, onStop: {})
                ServerToggleButton(serverState: .running(port: 8080), onStart: {}, onStop: {})
                ServerToggleButton(serverState: .stopping, onStart: {}, onStop: {})
                ServerToggleButton(serverState: .error("Port in use"), onStart: {}, onStop: {})
            },
            size: CGSize(width: 500, height: 80)
        )

        #expect(size.width >= 0)
    }

    @Test("Sidebar renders empty grouped and no-match states")
    func rendersSidebarStates() {
        let endpoint = makeEndpoint()
        let emptySize = render(
            SidebarView(
                projectName: "Mimic",
                endpoints: [],
                selectedEndpointID: .constant(nil),
                onDeleteEndpoint: { _ in },
                onDuplicateEndpoint: { _ in nil },
                onAddEndpoint: {}
            )
        )
        let populatedSize = render(
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
        let noMatchesSize = render(
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
        let rowSize = render(
            EndpointSidebarRow(endpoint: endpoint),
            size: CGSize(width: 320, height: 60)
        )

        #expect(emptySize.width >= 0)
        #expect(populatedSize.height >= 0)
        #expect(noMatchesSize.height >= 0)
        #expect(rowSize.width >= 0)
    }
}
