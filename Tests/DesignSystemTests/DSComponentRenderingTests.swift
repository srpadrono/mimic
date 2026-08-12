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
        @State private var showTrailing = true
        @State private var showBottom = true

        var body: some View {
            VStack(spacing: 16) {
                DSDrawer(edge: .trailing, isPresented: $showTrailing, identifier: "trailing") {
                    Text("Trailing drawer")
                        .padding()
                }
                .frame(height: 120)

                DSDrawer(edge: .bottom, isPresented: $showBottom, identifier: "bottom") {
                    Text("Bottom drawer")
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

        var body: some View {
            VStack(spacing: 16) {
                HStack(spacing: 0) {
                    DSDrawer(edge: .leading, isPresented: $showLeading, identifier: "leading") {
                        Text("Leading drawer")
                            .padding()
                            .frame(width: 160)
                    }

                    Text("Canvas")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 180)

                VStack(spacing: 0) {
                    DSDrawer(edge: .top, isPresented: $showTop, identifier: "top") {
                        Text("Top drawer")
                            .padding()
                            .frame(height: 100)
                    }

                    Text("Inspector")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(height: 220)
            }
            .frame(width: 500, height: 420)
        }
    }

    /// Hosts a `DSSplitPane` so the representable is actually made, laid out and updated — which is
    /// where `NSHostingController` sizing, the initial collapse state and the position restore all
    /// have to agree. A pure unit test cannot reach any of that.
    private struct SplitPaneHarness: View {
        let axis: Axis
        let startsCollapsed: Bool
        @State private var isSecondaryPresented: Bool
        @State private var thickness: CGFloat = 150

        init(axis: Axis, startsCollapsed: Bool = false) {
            self.axis = axis
            self.startsCollapsed = startsCollapsed
            _isSecondaryPresented = State(initialValue: !startsCollapsed)
        }

        var body: some View {
            DSSplitPane(
                axis: axis,
                isSecondaryPresented: $isSecondaryPresented,
                secondaryThickness: $thickness,
                minimumPrimaryThickness: 120,
                minimumSecondaryThickness: 80,
                defaultSecondaryThickness: 150,
                identifier: "harness"
            ) {
                Text("Primary")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } secondary: {
                Text("Secondary")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .frame(width: 500, height: 420)
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

    @Test("Split panes render on both axes, collapsed and revealed")
    func rendersSplitPanes() {
        let vertical = render(SplitPaneHarness(axis: .vertical))
        let horizontal = render(SplitPaneHarness(axis: .horizontal))
        // A pane that starts collapsed must not load its content into a zero-height frame and trap;
        // `NSSplitViewItem` defers the view load until it is uncollapsed, and this is the only place
        // that path is exercised.
        let collapsed = render(SplitPaneHarness(axis: .vertical, startsCollapsed: true))

        #expect(vertical.height >= 0)
        #expect(horizontal.width >= 0)
        #expect(collapsed.height >= 0)
    }

    @Test("Drawer edges stay consistent")
    func drawerHelpersAndAdditionalEdges() {
        let edgeSize = render(EdgeDrawerHarness())

        #expect(DSDrawerEdge.leading.swiftUIEdge == .leading)
        #expect(DSDrawerEdge.trailing.swiftUIEdge == .trailing)
        #expect(DSDrawerEdge.top.swiftUIEdge == .top)
        #expect(DSDrawerEdge.bottom.swiftUIEdge == .bottom)
        #expect(DSDrawerEdge.leading.isHorizontal)
        #expect(DSDrawerEdge.trailing.isHorizontal)
        #expect(DSDrawerEdge.top.isHorizontal == false)
        #expect(DSDrawerEdge.bottom.isHorizontal == false)
        #expect(DSDrawerEdge.leading.dividerLeads == false)
        #expect(DSDrawerEdge.trailing.dividerLeads)
        #expect(DSDrawerEdge.top.dividerLeads == false)
        #expect(DSDrawerEdge.bottom.dividerLeads)
        #expect(edgeSize.height >= 0)
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

    /// Values, not orderings.
    ///
    /// An ordering assertion cannot catch the change that actually matters: `DSSpacing.md` going from
    /// 12 to 10 keeps every `<` true and moves every panel in the window. These numbers are measured
    /// against Xcode rather than chosen freely, so changing one should mean editing a test and
    /// re-reading why the number is what it is.
    ///
    /// The two ladders below had no coverage at all, having been six and twenty-three hand-written
    /// literals until they were named — which is precisely when a test is worth adding, because the
    /// literals are no longer there to compare against each other.
    @Test("The bar, control and stroke ladders are the measured values")
    func laddersArePinned() {
        #expect(DSBarHeight.panelHeader == 30)
        #expect(DSBarHeight.secondaryBar == 24)
        #expect(DSBarHeight.controlRow == 32)
        #expect(DSBarHeight.columnHeader == 22)

        #expect(DSControlHeight.row == 20)
        #expect(DSControlHeight.field == 22)
        #expect(DSControlHeight.prominent == 28)
        #expect(DSControlHeight.verticalPadding == 3)

        #expect(DSStroke.hairline == 0.5)
        #expect(DSStroke.seam == 1)
        #expect(DSStroke.focusRing == 1)

        // The relationships the comments claim, stated where they can fail: a control row is a row
        // control with `sm` above and below, and a panel header stands on the ladder rather than
        // owning its own number.
        #expect(DSBarHeight.controlRow == DSControlHeight.row + DSSpacing.sm * 2)
        #expect(DSPanelHeader<EmptyView>.height == DSBarHeight.panelHeader)
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
