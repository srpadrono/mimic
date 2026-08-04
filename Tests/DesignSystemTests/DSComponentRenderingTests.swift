import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DesignSystem Components")
@MainActor
struct DSComponentRenderingTests {
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

    private struct JSONEditorHarness: View {
        @State var text: String
        let onValidationChanged: (Bool) -> Void

        var body: some View {
            DSJSONEditor(
                text: $text,
                identifier: "json-editor",
                onValidationChanged: onValidationChanged
            )
            .frame(width: 420, height: 220)
        }
    }

    private struct DrawerHarness: View {
        @State private var showFixed = true
        @State private var showResizable = true
        @State private var drawerSize: CGFloat = 180

        var body: some View {
            VStack(spacing: 16) {
                DSDrawer(edge: .trailing, isPresented: $showFixed, identifier: "fixed") {
                    Text("Fixed drawer")
                        .padding()
                }
                .frame(height: 120)

                DSDrawer(
                    edge: .bottom,
                    isPresented: $showResizable,
                    size: $drawerSize,
                    minSize: 120,
                    maxSize: 240,
                    defaultSize: 160,
                    identifier: "resizable"
                ) {
                    Text("Resizable drawer")
                        .padding()
                }
                .frame(height: 240)
            }
            .frame(width: 500, height: 420)
        }
    }

    private struct EdgeDrawerHarness: View {
        @State private var showLeading = true
        @State private var showTop = true
        @State private var leadingSize: CGFloat = 180
        @State private var topSize: CGFloat = 140

        var body: some View {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    DSDrawer(
                        edge: .leading,
                        isPresented: $showLeading,
                        size: $leadingSize,
                        minSize: 120,
                        maxSize: 240,
                        defaultSize: 160,
                        identifier: "leading"
                    ) {
                        Text("Leading drawer")
                            .padding()
                    }

                    Text("Canvas")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 180)

                VStack(spacing: 0) {
                    DSDrawer(
                        edge: .top,
                        isPresented: $showTop,
                        size: $topSize,
                        minSize: 100,
                        maxSize: 220,
                        defaultSize: 150,
                        identifier: "top"
                    ) {
                        Text("Top drawer")
                            .padding()
                    }

                    Text("Inspector")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 220)
            }
            .frame(width: 500, height: 420)
        }
    }

    private struct DrawerDividerHarness: View {
        let axis: Axis
        let edge: DSDrawerEdge
        @State private var size: CGFloat = 180
        @State private var isPresented = true

        var body: some View {
            DSDrawerDivider(
                axis: axis,
                size: $size,
                isPresented: $isPresented,
                minSize: 120,
                maxSize: 240,
                defaultSize: 180,
                edge: edge,
                anchor: 220
            )
            .frame(
                width: axis == .horizontal ? 18 : 220,
                height: axis == .vertical ? 18 : 220
            )
        }
    }

    @Test("Core components render without crashing")
    func rendersCoreComponents() {
        let size = render(
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DSButton("Primary", variant: .primary, size: .small, identifier: "primary") {}
                    DSButton("Secondary", variant: .secondary, size: .medium, identifier: "secondary") {}
                    DSButton("Destructive", variant: .destructive, size: .large, identifier: "destructive") {}
                    DSButton("Ghost", variant: .ghost, size: .medium, identifier: "ghost") {}
                    DSCodeBlock("let value = 42", identifier: "code")
                    DSDivider(style: .subtle, axis: .horizontal, identifier: "subtle")
                    DSDivider(style: .strong, axis: .vertical, identifier: "strong")
                    DSEmptyState(
                        systemImage: "tray",
                        heading: "Nothing here",
                        message: "Start by creating a mock endpoint.",
                        actionTitle: "Create endpoint",
                        identifier: "empty"
                    ) {}
                    DSLoadingPlaceholder(identifier: "loading")
                        .frame(height: 160)
                    DSMethodBadge(method: "get", size: .standard, identifier: "get")
                    DSMethodBadge(method: "delete", size: .compact, identifier: "delete")
                    DSSectionHeader("Headers", identifier: "headers")
                    DSSectionHeader("Actions", identifier: "actions") {
                        Button("Refresh") {}
                    }
                    DSStatusBadge(state: .idle, identifier: "idle")
                    DSStatusBadge(state: .running, identifier: "running")
                    DSStatusBadge(state: .error, identifier: "error")
                    DSTextField("Project name", text: .constant("Mimic"), identifier: "project")
                    DSTextField(
                        "Port",
                        text: .constant("70000"),
                        validation: "Port must be between 1 and 65535",
                        identifier: "port"
                    )
                    Text("Hover me")
                        .padding()
                        .dsHoverHighlight()
                }
                .padding()
            }
        )

        #expect(size.width >= 0)
    }

    @Test("Drawer variants render")
    func rendersDrawers() {
        let size = render(DrawerHarness())
        #expect(size.height >= 0)
    }

    @Test("Drawer edges and divider helpers stay consistent")
    func drawerHelpersAndAdditionalEdges() {
        let edgeSize = render(EdgeDrawerHarness())
        let horizontalDividerSize = render(
            DrawerDividerHarness(axis: .horizontal, edge: .leading),
            size: CGSize(width: 40, height: 220)
        )
        let verticalDividerSize = render(
            DrawerDividerHarness(axis: .vertical, edge: .bottom),
            size: CGSize(width: 220, height: 40)
        )

        #expect(DSDrawerEdge.leading.swiftUIEdge == .leading)
        #expect(DSDrawerEdge.trailing.swiftUIEdge == .trailing)
        #expect(DSDrawerEdge.top.swiftUIEdge == .top)
        #expect(DSDrawerEdge.bottom.swiftUIEdge == .bottom)
        #expect(DSDrawerEdge.leading.isHorizontal)
        #expect(DSDrawerEdge.trailing.isHorizontal)
        #expect(!DSDrawerEdge.top.isHorizontal)
        #expect(!DSDrawerEdge.bottom.isHorizontal)
        #expect(!DSDrawerEdge.leading.dividerLeads)
        #expect(DSDrawerEdge.trailing.dividerLeads)
        #expect(!DSDrawerEdge.top.dividerLeads)
        #expect(DSDrawerEdge.bottom.dividerLeads)
        #expect(edgeSize.height >= 0)
        #expect(horizontalDividerSize.height >= 0)
        #expect(verticalDividerSize.width >= 0)
    }

    @Test("JSON editor renders valid and invalid content in both themes")
    func rendersJSONEditorWithThemeAndValidationStates() {
        let invalidSize = render(
            JSONEditorHarness(text: "{invalid}", onValidationChanged: { _ in }),
            wait: 0.4
        )
        let validSize = render(
            JSONEditorHarness(text: #"{"ok":true}"#, onValidationChanged: { _ in })
                .environment(\.colorScheme, .light),
            wait: 0.4
        )
        let darkSize = render(
            JSONEditorHarness(text: #"[1,2,3]"#, onValidationChanged: { _ in })
                .environment(\.colorScheme, .dark),
            wait: 0.4
        )

        #expect(invalidSize.height >= 0)
        #expect(validSize.width >= 0)
        #expect(darkSize.width >= 0)
    }

    @Test("JSON editor helpers validate and pretty print")
    func jsonEditorHelpers() async {
        #expect(DSJSONEditor.validationErrorMessage(text: "", isValid: false) == nil)
        #expect(DSJSONEditor.validationErrorMessage(text: "{", isValid: false) != nil)
        let formatted = DSJSONEditor.prettyPrint(#"{"b":1,"a":2}"#)
        #expect(formatted?.contains("\n") == true)
        // Key order survives the round trip — see `DSJSONEditorTests.prettyPrintCompact` for why
        // that is the assertion that matters here.
        if let formatted, let b = formatted.range(of: "\"b\""), let a = formatted.range(of: "\"a\"") {
            #expect(b.lowerBound < a.lowerBound)
        } else {
            Issue.record("Expected both keys in the formatted output")
        }
        #expect(DSJSONEditor.prettyPrint("plain text") == nil)
        #expect(await DSJSONEditor.validateAsync(#"{"ok":true}"#))
        #expect(await DSJSONEditor.validateAsync("{") == false)
    }

    @Test("Drawer divider helpers cover resize math and cursor paths")
    func drawerDividerHelpers() {
        #expect(DSDrawerDivider.lineThickness(isDragging: false) == 1)
        #expect(DSDrawerDivider.lineThickness(isDragging: true) == 2.5)
        #expect(DSDrawerDivider.anchorValue(
            forFrame: CGRect(x: 10, y: 20, width: 200, height: 100), edge: .bottom
        ) == 120)
        #expect(DSDrawerDivider.size(
            forLocation: CGPoint(x: 0, y: 140), anchor: 300, edge: .bottom, maxSize: 240
        ) == 160)
        #expect(DSDrawerDivider.size(
            forLocation: CGPoint(x: 0, y: 400), anchor: 300, edge: .bottom, maxSize: 240
        ) == 0)
        #expect(DSDrawerDivider.size(
            forLocation: CGPoint(x: 0, y: 0), anchor: 300, edge: .bottom, maxSize: 240
        ) == 240)
        #expect(DSDrawerDivider.size(
            forLocation: CGPoint(x: 200, y: 0), anchor: 0, edge: .leading, maxSize: 240
        ) == 200)

        let snapClosed = DSDrawerDivider.dragEndState(
            size: 40,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(snapClosed.isPresented == false)
        #expect(snapClosed.size == 180)

        let snapMinimum = DSDrawerDivider.dragEndState(
            size: 90,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(snapMinimum.shouldSnapToMinimum)
        #expect(snapMinimum.isPresented == nil)
        #expect(snapMinimum.size == 90)

        let keepOpen = DSDrawerDivider.dragEndState(
            size: 140,
            minSize: 120,
            defaultSize: 180,
            snapCloseThreshold: 72
        )
        #expect(keepOpen.shouldSnapToMinimum == false)
        #expect(keepOpen.isPresented == nil)

        // `handleHover` is now a pure predicate. It used to push and pop `NSCursor`, and this test
        // exercised a *balanced* pair — which is exactly why it never caught the bug: the cursor
        // stack has no owner, SwiftUI does not promise an `onHover(false)` when a view is removed,
        // and the divider is removed under the pointer every time a drawer snaps closed. The pop
        // never ran and the resize cursor stuck over the whole window. The cursor is `.pointerStyle`'s
        // business now, scoped to the view's lifetime, so there is no unbalanced call to make.
        #expect(DSDrawerDivider.handleHover(hovering: true, axis: .horizontal))
        #expect(DSDrawerDivider.handleHover(hovering: false, axis: .vertical) == false)
        _ = DSAnimation.drawerToggle
    }

    @Test("Token values and color mappings stay consistent")
    func tokenValuesStayConsistent() {
        _ = DSAnimation.spring()

        #expect(DSAnimation.micro < DSAnimation.fast)
        #expect(DSAnimation.fast < DSAnimation.normal)
        #expect(DSAnimation.normal < DSAnimation.slow)

        #expect(DSCornerRadius.xs < DSCornerRadius.sm)
        #expect(DSCornerRadius.sm < DSCornerRadius.md)
        #expect(DSCornerRadius.md < DSCornerRadius.lg)
        #expect(DSCornerRadius.lg < DSCornerRadius.xl)

        #expect(DSSpacing.xxs < DSSpacing.xs)
        #expect(DSSpacing.xs < DSSpacing.sm)
        #expect(DSSpacing.sm < DSSpacing.md)
        #expect(DSSpacing.md < DSSpacing.lg)
        #expect(DSSpacing.lg < DSSpacing.xl)
        #expect(DSSpacing.xl < DSSpacing.xxl)
        #expect(DSSpacing.xxl < DSSpacing.xxxl)

        #expect(DSColors.methodColor(for: "HEAD") != .secondary)
        #expect(DSColors.methodColor(for: "OPTIONS") != .secondary)
        #expect(DSColors.methodColor(for: "TRACE") == .secondary)
    }
}
