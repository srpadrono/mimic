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

    /// The one test in this file that claims only "nothing trapped", and says so in its name.
    ///
    /// Hosting a view is not a formality: it runs layout, makes and updates every representable, and
    /// runs every `@State` initialiser — which is where these components crash if they are going to.
    /// `DSSplitPane` is the reason it is worth keeping at all. It installs a custom `NSSplitView` from
    /// `loadView`, and the unguarded `splitView(_:shouldHideDividerAt:)` underneath that threw out of
    /// `_updateStackConstraints` before a single frame was drawn — a launch crash no value assertion
    /// can reach, because nothing is wrong with any value.
    ///
    /// What it replaced was nine `#expect(size.width >= 0)` lines on `NSHostingController.fittingSize`,
    /// a quantity that cannot be negative. They read as coverage of the whole component set and
    /// asserted nothing at all; the geometry tests below carry the claims that can fail.
    @Test("Hosting every component does not trap during layout")
    func hostingComponentsDoesNotTrap() {
        render(
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

        render(DrawerHarness())
        render(EdgeDrawerHarness())
        render(SplitPaneHarness(axis: .vertical))
        render(SplitPaneHarness(axis: .horizontal))
        // A pane that starts collapsed must not load its content into a zero-height frame and trap;
        // `NSSplitViewItem` defers the view load until it is uncollapsed, and this is the only place
        // that path is exercised.
        render(SplitPaneHarness(axis: .vertical, startsCollapsed: true))

        // 0.4s, because validation is debounced by 300ms — see `DSJSONEditor.resolvedValidationResult`.
        // A shorter wait finishes the render before the invalid-JSON path is ever taken, which is the
        // one of the three that has anything to go wrong in it.
        render(JSONEditorHarness(text: "{invalid}", onValidationChanged: { _ in }), wait: 0.4)
        render(
            JSONEditorHarness(text: #"{"ok":true}"#, onValidationChanged: { _ in })
                .environment(\.colorScheme, .light),
            wait: 0.4
        )
        render(
            JSONEditorHarness(text: #"[1,2,3]"#, onValidationChanged: { _ in })
                .environment(\.colorScheme, .dark),
            wait: 0.4
        )
    }

    /// The claim the component exists to make, stated where it can fail.
    ///
    /// A badge sized to its content came out around 32pt for `GET` and 52pt for `DELETE`, so a column
    /// of them left the paths beside them starting at a different x on every row — and compact
    /// `OPTIONS` wanted 58.2pt inside the 58pt frame `SidebarView` and `ImportReviewList` both give
    /// it, which a `Text` resolves by wrapping onto a second line and taking the row's height with it.
    /// Every measurement here is a comparison between two renders rather than a literal, so it stays
    /// true across a font substitution and still fails the moment the fixed width comes off.
    @Test("A method badge is one width whatever method it holds")
    func methodBadgeWidthIsStableAcrossMethods() {
        let measure = CGSize(width: 200, height: 60)
        let compactGet = render(DSMethodBadge(method: "GET", size: .compact, identifier: "get"), size: measure)
        let compactOptions = render(DSMethodBadge(method: "OPTIONS", size: .compact, identifier: "options"), size: measure)
        let standardGet = render(DSMethodBadge(method: "GET", size: .standard, identifier: "get"), size: measure)
        let standardOptions = render(DSMethodBadge(method: "OPTIONS", size: .standard, identifier: "options"), size: measure)

        #expect(compactGet.width == compactOptions.width)
        #expect(standardGet.width == standardOptions.width)

        // And the widest method still fits the 58pt column its two callers reserve —
        // `SidebarView.EndpointSidebarRow` and `ImportColumns.method`. The badge is 56pt wide
        // (`DSMethodBadgeSize.badgeWidth`), so this passes with two points of slack rather than the
        // 0.2pt of overflow that caused the wrap.
        #expect(compactOptions.width <= 58)

        // The two sizes are genuinely two sizes: a dense list gets the smaller badge.
        #expect(standardGet.width > compactGet.width)
        #expect(standardGet.height > compactGet.height)
    }

    /// "Every panel wears one bar of chrome, `DSBarHeight.panelHeader` tall."
    ///
    /// The navigator wears a `DSTabStrip` where the other two panels wear a `DSPanelHeader`, and the
    /// only reason that is allowed is that the two stand the same height — otherwise the three panels'
    /// headers stop aligning horizontally, which is the state the window was in before either
    /// component existed. `DSTabStrip` states the parity in its own documentation; nothing checked it.
    ///
    /// Measured against a bare `Color` fixed to the token rather than against the literal 30, so the
    /// comparison cannot drift from the ladder and cannot be broken by anything the hosting layer adds
    /// to both sides equally.
    @Test("Panel chrome stands one height, whether a panel opens with a header or a tab strip")
    func panelChromeSharesOneHeight() {
        let measure = CGSize(width: 320, height: 120)
        let ruler = render(Color.clear.frame(height: DSBarHeight.panelHeader), size: measure)
        let header = render(DSPanelHeader("Endpoints", identifier: "sidebar"), size: measure)
        let loadedHeader = render(
            DSPanelHeader("Scenarios", subtitle: "12 requests", identifier: "inspector") {
                DSPanelHeaderButton(systemImage: "plus", help: "Add scenario", identifier: "add") {}
            },
            size: measure
        )
        let strip = render(
            DSTabStrip(
                tabs: [
                    DSTabStrip.Tab(id: "endpoints", systemImage: "list.bullet", help: "Show endpoints"),
                    DSTabStrip.Tab(id: "journeys", systemImage: "arrow.triangle.branch", help: "Show journeys"),
                ],
                selection: .constant("endpoints"),
                identifier: "navigator"
            ),
            size: measure
        )

        #expect(header.height == ruler.height)
        #expect(loadedHeader.height == header.height)
        #expect(strip.height == header.height)
    }

    /// A badge rides the corner of the selection shape as an overlay, so it takes no part in layout.
    ///
    /// Inline, it widened the cell by its own width: the icon drifted off centre the moment a count
    /// appeared and drifted back when it cleared, so the strip visibly shuffled while you watched it.
    @Test("A badged tab is the same shape as a bare one")
    func tabBadgeDoesNotChangeTheStripsGeometry() {
        let measure = CGSize(width: 320, height: 120)
        let bare = render(
            DSTabStrip(
                tabs: [DSTabStrip.Tab(id: "endpoints", systemImage: "list.bullet", help: "Show endpoints")],
                selection: .constant("endpoints"),
                identifier: "navigator"
            ),
            size: measure
        )
        let badged = render(
            DSTabStrip(
                tabs: [
                    DSTabStrip.Tab(id: "endpoints", systemImage: "list.bullet", help: "Show endpoints", badge: 128),
                ],
                selection: .constant("endpoints"),
                identifier: "navigator"
            ),
            size: measure
        )

        #expect(badged == bare)
    }

    /// The validation message is a row under the field, not an overlay on it.
    ///
    /// It sits as a sibling in `DSTextField`'s stack precisely so the form makes room for it — a
    /// message drawn over the control it is complaining about would cover the value you are being
    /// asked to correct. The height difference is the whole point, and it is what a caller sizing a
    /// sheet around this field is relying on.
    @Test("A field with something to complain about is taller than one without")
    func validationMessageTakesItsOwnRow() {
        let measure = CGSize(width: 320, height: 160)
        let quiet = render(
            DSTextField("Port", text: .constant("8080"), identifier: "port"),
            size: measure
        )
        let complaining = render(
            DSTextField(
                "Port",
                text: .constant("70000"),
                validation: "Port must be between 1 and 65535",
                identifier: "port"
            ),
            size: measure
        )

        #expect(complaining.height > quiet.height)
    }

    @Test("Drawer edges stay consistent")
    func drawerHelpersAndAdditionalEdges() {
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

    /// The third ladder, and the only one that arrived with a floor.
    ///
    /// `DSBarHeight` and `DSControlHeight` name points. `DSGlyph` names tiers, because the house rule
    /// it encodes states ranges — "Separators and menu indicators are 8pt, inline glyphs 9–10pt,
    /// control glyphs 11–13pt" — and it spent far longer than either as prose with nothing behind it:
    /// thirty-odd bare `.font(.system(size:))` literals across two modules, which is exactly the state
    /// the other two ladders were pinned on leaving.
    ///
    /// **The floor is asserted separately, and it is not redundant with the values above it.** A tier
    /// stated as a range invites a seventh rung, and a seventh rung would pass every value line here
    /// while sitting at 7pt — which is the failure the rule is actually about, since a menu indicator
    /// that small stops reading as a mark and the control it annotates stops being discovered.
    ///
    /// Not asserted, for want of a way to: three rungs are deliberately the sizes of
    /// `DSTypography.caption`, `.label` and `.body`, so a glyph beside a line of type matches the
    /// line. `Font` does not expose its point size, so that relationship stays a claim in the token's
    /// documentation rather than a check — unlike the `controlRow == row + sm * 2` line above, which
    /// is why that one is stated there and this one is not stated here.
    @Test("The glyph ladder is the measured values, and nothing sits below the floor")
    func glyphLadderIsPinned() {
        #expect(DSGlyph.indicator == 8)
        #expect(DSGlyph.inlineSmall == 9)
        #expect(DSGlyph.inline == 10)
        #expect(DSGlyph.control == 11)
        #expect(DSGlyph.controlLarge == 12)
        #expect(DSGlyph.controlProminent == 13)

        #expect(DSGlyph.minimum == 8)

        let ladder = [
            DSGlyph.indicator,
            DSGlyph.inlineSmall,
            DSGlyph.inline,
            DSGlyph.control,
            DSGlyph.controlLarge,
            DSGlyph.controlProminent
        ]

        // "No glyph below 8pt" — the rule, stated where it can fail rather than remembered.
        for rung in ladder {
            #expect(rung >= DSGlyph.minimum)
        }

        // And the floor is reached, not merely respected: a `minimum` that drifted above every rung
        // would satisfy the loop above while no longer describing the ladder it bounds.
        #expect(ladder.min() == DSGlyph.minimum)
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
