import AppKit
import SwiftUI
import Testing
import Domain
@testable import AppFeatures

@Suite("EndpointFeature Rendering")
@MainActor
struct EndpointFeatureRenderingTests {
    @discardableResult
    private func render<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 1000, height: 800),
        wait: TimeInterval = 0.05
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
        let renderedSize = controller.view.fittingSize
        window.orderOut(nil)
        return renderedSize
    }

    private func makeActions(
        onDuplicate: @escaping () -> Void = {},
        onDelete: @escaping () -> Void = {},
        onUpdateScenario: @escaping (_ statusCode: Int?, _ headers: [String: String]?, _ body: String?) -> Void = { _, _, _ in },
        onUpdateDelay: @escaping (Int) -> Void = { _ in },
        onUpdateGroupTag: @escaping (String?) -> Void = { _ in }
    ) -> EndpointEditorActions {
        EndpointEditorActions(
            onDuplicate: onDuplicate,
            onDelete: onDelete,
            onUpdateScenario: onUpdateScenario,
            onUpdateDelay: onUpdateDelay,
            onUpdateGroupTag: onUpdateGroupTag
        )
    }

    private func makeEndpoint(groupTag: String? = "Users") -> Endpoint {
        let activeScenario = Scenario(
            name: "Default",
            statusCode: 201,
            headers: [
                "Content-Type": "application/json",
                "X-Request-ID": "abc-123",
            ],
            body: #"{"ok":true}"#
        )
        return Endpoint(
            name: "Create User",
            method: .post,
            path: "/api/v1/users",
            scenarios: [activeScenario],
            activeScenarioID: activeScenario.id,
            delayMs: 125,
            groupTag: groupTag
        )
    }

    @Test("Endpoint editor actions call injected closures")
    func endpointEditorActionsCallClosures() {
        var duplicated = false
        var deleted = false
        var statusCode: Int?
        var headers: [String: String]?
        var body: String?
        var delay: Int?
        var groupTag: String?

        let actions = makeActions(
            onDuplicate: { duplicated = true },
            onDelete: { deleted = true },
            onUpdateScenario: { status, updatedHeaders, updatedBody in
                statusCode = status
                headers = updatedHeaders
                body = updatedBody
            },
            onUpdateDelay: { delay = $0 },
            onUpdateGroupTag: { groupTag = $0 }
        )

        actions.onDuplicate()
        actions.onDelete()
        actions.onUpdateScenario(202, ["ETag": "1"], #"{"saved":true}"#)
        actions.onUpdateDelay(350)
        actions.onUpdateGroupTag("Auth")

        #expect(duplicated)
        #expect(deleted)
        #expect(statusCode == 202)
        #expect(headers?["ETag"] == "1")
        #expect(body == #"{"saved":true}"#)
        #expect(delay == 350)
        #expect(groupTag == "Auth")
    }

    /// Both sheets open at one width, which is the part of "the shared sheet convention" that is a
    /// number.
    ///
    /// The convention each of these two views claims to follow in its own documentation — a
    /// sentence-case heading, `DSSpacing.lg` between the blocks, a trailing button row — ends in
    /// `.frame(minWidth: 420, idealWidth: 420)`, written out separately in both files. A convention
    /// spelled out at each call site is one that drifts, and nothing checked that these two still
    /// agreed.
    ///
    /// Compared with each other rather than against 420, so it is the agreement being asserted and
    /// either sheet leaving it fails here.
    @Test("The two creation sheets open at one width")
    func creationSheetsShareOneWidth() {
        let endpointSheet = render(NewEndpointSheet { _, _, _ in })
        let projectSheet = render(NewProjectSheet { _, _ in })

        #expect(endpointSheet.width == projectSheet.width)
        // And it is the stated floor, not whatever the fields happened to measure.
        #expect(endpointSheet.width >= 420)
    }

    /// The one test in this file whose only claim is that nothing trapped, and it says so in its name.
    ///
    /// The editor carries more `@State` than anything else in the window — five fields, three
    /// debounced commit tasks and a JSON editor — and none of it is built until the view is hosted.
    /// Both branches are worth making: with an active scenario it builds the whole form, without one
    /// it builds a `DSEmptyState`, and the two share no layout.
    ///
    /// It replaces two `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`, which
    /// cannot be negative. The editor's own geometry is a stack of flexible cards inside a
    /// `ScrollView`, so its fitting size measures the scroll content rather than anything the layout
    /// promises — there is no honest number to assert here, and the helpers below are where this
    /// view's behaviour is actually pinned.
    @Test("Hosting the endpoint editor does not trap during layout")
    func hostingEndpointEditorDoesNotTrap() {
        let endpoint = makeEndpoint()
        render(
            EndpointEditorView(
                endpoint: endpoint,
                activeScenario: endpoint.scenarios.first,
                globalDelayMs: 50,
                actions: makeActions()
            )
        )

        let withoutScenario = Endpoint(
            name: "Health",
            method: .get,
            path: "/health",
            scenarios: [],
            activeScenarioID: nil,
            delayMs: 0,
            groupTag: nil
        )
        render(
            EndpointEditorView(
                endpoint: withoutScenario,
                activeScenario: nil,
                globalDelayMs: 0,
                actions: makeActions()
            )
        )
    }

    @Test("Endpoint editor helper functions normalize synced state and updates")
    func endpointEditorHelpers() {
        let endpoint = makeEndpoint(groupTag: "Users")
        let synced = try! #require(
            EndpointEditorView.syncedValues(
                endpoint: endpoint,
                activeScenario: endpoint.scenarios.first
            )
        )

        #expect(synced.statusCodeString == "201")
        #expect(synced.responseBody == #"{"ok":true}"#)
        #expect(synced.delayString == "125")
        #expect(synced.groupTag == "Users")
        #expect(synced.headers.map(\.0) == ["Content-Type", "X-Request-ID"])

        #expect(EndpointEditorView.statusCodeValue(from: "201") == 201)
        #expect(EndpointEditorView.statusCodeValue(from: "99") == nil)
        #expect(EndpointEditorView.headersDictionary(from: [
            (" Content-Type ", "application/json"),
            ("", "ignored"),
            ("X-Request-ID", "abc-123"),
        ]) == [
            "Content-Type": "application/json",
            "X-Request-ID": "abc-123",
        ])
        #expect(EndpointEditorView.bodyValue(from: #"{"ok":true}"#) == #"{"ok":true}"#)
        #expect(EndpointEditorView.bodyValue(from: "") == nil)
        #expect(EndpointEditorView.delayValue(from: "125") == 125)
        #expect(EndpointEditorView.delayValue(from: "-1") == nil)
        #expect(EndpointEditorView.groupTagValue(from: " Users ") == "Users")
        #expect(EndpointEditorView.groupTagValue(from: "   ") == nil)
        #expect(EndpointEditorView.syncedValues(endpoint: endpoint, activeScenario: nil) == nil)

        var statusCode: Int?
        var headers: [String: String]?
        var body: String?
        var delay: Int?
        var groupTag: String?
        let actions = makeActions(
            onUpdateScenario: { updatedStatusCode, updatedHeaders, updatedBody in
                if let updatedStatusCode {
                    statusCode = updatedStatusCode
                }
                if let updatedHeaders {
                    headers = updatedHeaders
                }
                if updatedBody != nil {
                    body = updatedBody
                }
            },
            onUpdateDelay: { delay = $0 },
            onUpdateGroupTag: { groupTag = $0 }
        )
        let committedView = EndpointEditorView(
            endpoint: endpoint,
            activeScenario: endpoint.scenarios.first,
            globalDelayMs: 50,
            actions: actions,
            initialStatusCodeString: "201",
            initialResponseBody: #"{"ok":true}"#,
            initialDelayString: "125",
            initialGroupTag: " Users ",
            initialHeaders: [
                (" Content-Type ", "application/json"),
                ("X-Request-ID", "abc-123"),
            ]
        )

        committedView.commitStatusCode()
        committedView.commitHeaders()
        committedView.commitBody()
        committedView.commitDelay()
        committedView.commitGroupTag()

        #expect(statusCode == 201)
        #expect(headers?["Content-Type"] == "application/json")
        #expect(headers?["X-Request-ID"] == "abc-123")
        #expect(body == #"{"ok":true}"#)
        #expect(delay == 125)
        #expect(groupTag == "Users")
    }
}
