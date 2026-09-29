import AppKit
import SwiftUI
import Testing
@testable import DesignSystem

@Suite("DesignSystem Components", .serialized)
@MainActor
struct DSComponentRenderingTests {
    /// Hosted rendering checks share AppKit's active window, so this suite is serial.
    private func withHostedView<V: View>(
        _ view: V,
        size: CGSize = CGSize(width: 360, height: 160),
        inspect: (NSView) throws -> Void
    ) rethrows {
        let controller = NSHostingController(rootView: view)
        let window = NSWindow(
            contentRect: CGRect(origin: .zero, size: size),
            styleMask: [.titled], backing: .buffered, defer: false
        )
        window.isReleasedWhenClosed = false
        window.contentViewController = controller
        controller.view.frame = CGRect(origin: .zero, size: size)
        window.makeKeyAndOrderFront(nil)
        defer {
            window.orderOut(nil)
            window.close()
        }
        controller.view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        controller.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try inspect(controller.view)
    }

    private func menuItem(_ title: String, in menu: NSMenu) -> (menu: NSMenu, index: Int)? {
        for (index, item) in menu.items.enumerated() {
            if item.title == title { return (menu, index) }
            if let submenu = item.submenu, let found = menuItem(title, in: submenu) { return found }
        }
        return nil
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
                    DSButton("Secondary", systemImage: "plus", variant: .secondary, size: .medium,
                             identifier: "secondary") {}
                    DSButton("Destructive", variant: .destructive, size: .large, identifier: "destructive") {}
                    DSButton("Ghost", variant: .ghost, size: .medium, identifier: "ghost") {}
                    DSIconButton("Add", systemImage: "plus", identifier: "icon") {}
                    DSCodeBlock("let value = 42", identifier: "code")
                    DSDivider(axis: .horizontal, identifier: "horizontal")
                    DSDivider(axis: .vertical, identifier: "vertical")
                    DSEmptyState(
                        systemImage: "tray",
                        heading: "Nothing here",
                        message: "Start by creating a mock endpoint.",
                        actionTitle: "Create endpoint",
                        identifier: "empty"
                    ) {}
                    DSEmptyState(
                        heading: "No endpoints",
                        message: "Nothing matches the filter.",
                        prominence: .compact,
                        identifier: "compact"
                    )
                    // Both arms of the filter field, because they lay out differently: the first has
                    // a scope menu carrying a title and a clear button in the row, the second has
                    // neither and is the well with nothing but a field inside it.
                    DSFilterField(
                        text: .constant("/v1/accounts"),
                        scopeID: .constant("body"),
                        scopes: [
                            DSFilterField.Scope(id: "any", title: "Anything"),
                            DSFilterField.Scope(id: "body", title: "Response bodies")
                        ],
                        placeholder: "Filter endpoints",
                        identifier: "scoped"
                    )
                    DSFilterField(
                        text: .constant(""),
                        scopeID: .constant(""),
                        scopes: [],
                        placeholder: "Filter endpoints",
                        identifier: "unscoped"
                    )
                    DSLoadingPlaceholder(identifier: "loading")
                        .frame(height: 160)
                    DSMethodLabel("get", identifier: "get")
                    DSMethodLabel("delete", fixedWidth: false, identifier: "delete")
                    DSSectionHeader("Headers", identifier: "headers")
                    DSSectionHeader("Actions", identifier: "actions") {
                        Button("Refresh") {}
                    }
                    DSStatusLabel(statusCode: 200)
                    DSStatusLabel(statusCode: 500, reason: "Internal Server Error")
                    DSStatusLabel(statusCode: nil)
                    DSStatusLabel(statusCode: nil, reason: "timeout 30000ms")
                    DSStatusLabel("3 unmatched", color: DSColors.warning)
                    DSSegmentedControl(
                        "Scope",
                        segments: [
                            .init("All", value: "all", identifier: "all"),
                            .init("Unmatched", value: "unmatched", count: 3, countColor: DSColors.warning,
                                  identifier: "unmatched")
                        ],
                        selection: .constant("all"),
                        identifier: "scope"
                    )
                    DSBanner(.info, message: "Imported 12 endpoints.", identifier: "info")
                    DSBanner(.warning, message: "Restart to apply the new port.", actionTitle: "Restart",
                             identifier: "warning") {}
                    DSBanner(.error, message: "Port 8080 is in use.", identifier: "error")
                    DSLiveIndicator(isLive: true)
                    DSLiveIndicator(isLive: false, size: 10)
                    DSOptionCard("New project", message: "Start from an empty project.",
                                 shortcut: ["\u{2318}", "N"], isDefault: true, identifier: "new") {}
                    DSOptionCard("Open sample", message: "Explore a finished project.",
                                 footnote: "Read only", identifier: "sample") {}
                    Text("Field chrome")
                        .dsFieldChrome(isFocused: true)
                    Text("Invalid field chrome")
                        .dsFieldChrome(height: DSControlHeight.large, isFocused: false, isInvalid: true)
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
    /// In a list every method sits in one column, so the path beside it starts at the same x on
    /// every row. A label sized to its text would move the path by a character's width between
    /// `GET` and `OPTIONS`; the fixed column is 52pt, wide enough for the widest method in SF Mono 11.
    @Test("A method label is one width in a list, whatever method it holds")
    func methodLabelWidthIsStableAcrossMethods() {
        let measure = CGSize(width: 200, height: 60)
        let get = render(DSMethodLabel("GET", identifier: "get"), size: measure)
        let options = render(DSMethodLabel("OPTIONS", identifier: "options"), size: measure)
        let delete = render(DSMethodLabel("delete", identifier: "delete"), size: measure)

        #expect(get.width == 52)
        #expect(options.width == 52)
        #expect(delete.width == 52)
        #expect(get.height == options.height)

        // Outside a list the label is its text, so the two methods measure differently there.
        let bareGet = render(DSMethodLabel("GET", fixedWidth: false, identifier: "get"), size: measure)
        let bareOptions = render(DSMethodLabel("OPTIONS", fixedWidth: false, identifier: "options"), size: measure)
        #expect(bareGet.width < bareOptions.width)
        // And the widest method still fits the column rather than overflowing it.
        #expect(bareOptions.width <= 52)
    }

    /// A pane header is one 40pt bar whether it carries a subtitle and controls or only a title, so
    /// the request log's header and its neighbours line up.
    ///
    /// Measured against a bare `Color` fixed to 40pt rather than against the token, so the
    /// comparison cannot drift with the ladder and cannot be broken by anything the hosting layer
    /// adds to both sides equally.
    @Test("A pane header stands one height, bare or loaded")
    func panelHeaderSharesOneHeight() {
        let measure = CGSize(width: 320, height: 120)
        let ruler = render(Color.clear.frame(height: 40), size: measure)
        let header = render(DSPanelHeader("Endpoints", identifier: "sidebar"), size: measure)
        let loadedHeader = render(
            DSPanelHeader("Scenarios", subtitle: "12 requests", identifier: "inspector") {
                DSPanelHeaderButton(systemImage: "plus", help: "Add scenario", identifier: "add") {}
            },
            size: measure
        )

        #expect(header.height == ruler.height)
        #expect(loadedHeader.height == header.height)
        #expect(DSPanelHeader<EmptyView>.height == 40)
    }

    /// The inspector's header is the same 44pt bar as the toolbar and the navigator, so all three
    /// columns start their content at one y.
    @Test("The inspector header is the toolbar's height")
    func inspectorHeaderMatchesTheToolbar() {
        let measure = CGSize(width: 300, height: 120)
        let header = render(DSInspectorHeader { Text("Scenarios") }, size: measure)
        #expect(header.height == 44)
    }

    /// Counts sit inside their segment rather than beside the control, so a segment gaining a count
    /// does not change the control's height, and the control stays on the 24pt panel rung.
    @Test("A segmented control is 24pt tall, with or without counts")
    func segmentedControlKeepsItsHeight() {
        let measure = CGSize(width: 320, height: 80)
        let bare = render(
            DSSegmentedControl(
                "Scope",
                segments: [
                    .init("All", value: "all", identifier: "all"),
                    .init("Unmatched", value: "unmatched", identifier: "unmatched")
                ],
                selection: .constant("all"),
                identifier: "bare"
            ),
            size: measure
        )
        let counted = render(
            DSSegmentedControl(
                "Scope",
                segments: [
                    .init("All", value: "all", count: 128, identifier: "all"),
                    .init("Unmatched", value: "unmatched", count: 3, countColor: DSColors.warning,
                          identifier: "unmatched")
                ],
                selection: .constant("unmatched"),
                identifier: "counted"
            ),
            size: measure
        )

        #expect(bare.height == 24)
        #expect(counted.height == 24)
        #expect(counted.width > bare.width)
    }

    /// Focus and validation are drawn as a halo and a heavier border over the field, never as extra
    /// layout: a field that grew when it took focus would shove the form under the pointer.
    @Test("Field chrome keeps its height focused, invalid and at rest")
    func fieldChromeKeepsItsHeight() {
        let measure = CGSize(width: 240, height: 80)
        let rest = render(Text("8080").dsFieldChrome(isFocused: false), size: measure)
        let focused = render(Text("8080").dsFieldChrome(isFocused: true), size: measure)
        let invalid = render(Text("70000").dsFieldChrome(isFocused: false, isInvalid: true), size: measure)
        let sheet = render(Text("8080").dsFieldChrome(height: DSControlHeight.large, isFocused: false),
                           size: measure)

        #expect(rest.height == 24)
        #expect(focused.height == 24)
        #expect(invalid.height == 24)
        #expect(sheet.height == 28)
    }

    /// Every button stands on its size's rung, whatever its variant: 20pt inside a row, 24pt in a
    /// panel, 28pt in a sheet. A ghost button draws no fill but must not be shorter than the primary
    /// beside it.
    @Test("Every button variant stands on its size's rung")
    func buttonVariantsShareTheirSizeRung() {
        let measure = CGSize(width: 240, height: 80)
        let expected: [(DSButtonSize, CGFloat)] = [(.small, 20), (.medium, 24), (.large, 28)]
        for (size, height) in expected {
            #expect(size.height == height)
            for variant in DSButtonVariant.allCases {
                let button = render(
                    DSButton("Import", systemImage: "square.and.arrow.down", variant: variant, size: size,
                             identifier: "button") {},
                    size: measure
                )
                #expect(button.height == height, "\(variant) at \(size)")
            }
        }
    }

    /// The live radio holds its footprint when it fills, so a row's name does not shift sideways
    /// when a scenario goes live.
    @Test("The live indicator is one size, live or not")
    func liveIndicatorKeepsItsSize() {
        let measure = CGSize(width: 60, height: 60)
        #expect(render(DSLiveIndicator(isLive: true), size: measure) == CGSize(width: 14, height: 14))
        #expect(render(DSLiveIndicator(isLive: false), size: measure) == CGSize(width: 14, height: 14))
        #expect(render(DSLiveIndicator(isLive: true, size: 10), size: measure) == CGSize(width: 10, height: 10))
    }

    /// Option cards line up in a row on the welcome screen, so each is 220pt wide and at least
    /// 132pt tall whether it shows a shortcut or a footnote.
    @Test("An option card is 220pt wide and keeps its minimum height")
    func optionCardGeometry() {
        let measure = CGSize(width: 400, height: 300)
        let shortcut = render(
            DSOptionCard("New project", message: "Start from an empty project.",
                         shortcut: ["\u{2318}", "N"], isDefault: true, identifier: "new") {},
            size: measure
        )
        let footnote = render(
            DSOptionCard("Open sample", message: "Explore a finished project.",
                         footnote: "Read only", identifier: "sample") {},
            size: measure
        )

        #expect(shortcut.width == 220)
        #expect(footnote.width == 220)
        #expect(shortcut.height >= 132)
        #expect(footnote.height >= 132)
    }

    /// "Controls sharing a row share their geometry", measured on the one control that spent longest
    /// not measuring itself.
    ///
    /// `DSFilterField` once documented a 20pt row and stated no height, so its
    /// height was whatever the scope `Menu` inside it happened to want — which is the failure the
    /// house rule is about, since a panel's chrome is built out of controls that are supposed to line
    /// up. The scopeless arm is measured beside it because the scope menu is exactly what used to set
    /// the number: a well with no menu in it must still stand on the same rung, or a panel's footer
    /// changes height depending on whether its filter has anything to be pointed at.
    ///
    /// Pin the intended 24-point panel rung independently of the production token.
    @Test("A filter field stands on the control rung, with a scope menu and without one")
    func filterFieldStandsOnTheControlRung() {
        let measure = CGSize(width: 240, height: 80)
        let ruler = render(Color.clear.frame(height: 24), size: measure)
        let scoped = render(
            DSFilterField(
                text: .constant("/v1/accounts"),
                scopeID: .constant("body"),
                scopes: [
                    DSFilterField.Scope(id: "any", title: "Anything"),
                    DSFilterField.Scope(id: "body", title: "Response bodies")
                ],
                placeholder: "Filter endpoints",
                identifier: "scoped"
            ),
            size: measure
        )
        let unscoped = render(
            DSFilterField(
                text: .constant(""),
                scopeID: .constant(""),
                scopes: [],
                placeholder: "Filter endpoints",
                identifier: "unscoped"
            ),
            size: measure
        )

        #expect(scoped.height == ruler.height)
        #expect(unscoped.height == ruler.height)
    }

    @Test("Filter scope choices show one native checkmark and write the chosen value", arguments: ["any", "body"])
    func filterScopeIsANativeSelection(initial: String) throws {
        var selection = initial
        let menu = NSHostingMenu(rootView: DSFilterField.ScopeOptions(
            scopes: [.init(id: "any", title: "Anything"), .init(id: "body", title: "Response bodies")],
            scopeID: Binding(get: { selection }, set: { selection = $0 }),
            identifier: "filter"
        ))
        menu.update()
        let any = try #require(menuItem("Anything", in: menu))
        let body = try #require(menuItem("Response bodies", in: menu))
        #expect(any.menu.items[any.index].state == (initial == "any" ? .on : .off))
        #expect(body.menu.items[body.index].state == (initial == "body" ? .on : .off))

        let target = initial == "any" ? body : any
        target.menu.performActionForItem(at: target.index)
        #expect(selection == (initial == "any" ? "body" : "any"))
    }

    @Test("A custom plain button visibly dims when disabled", arguments: [1.0, 0.7])
    func disabledPlainButtonDims(backgroundWhite: Double) throws {
        struct UndimmedStyle: ButtonStyle {
            func makeBody(configuration: Configuration) -> some View {
                configuration.label
            }
        }

        func brightness<Style: ButtonStyle>(
            isEnabled: Bool,
            hidesLabel: Bool = false,
            style: Style
        ) throws -> [Double] {
            var pixels: [Double] = []
            try withHostedView(
                Button {} label: {
                    Text("Refresh")
                        .font(DSTypography.title)
                        .foregroundStyle(.black)
                        .padding(8)
                        .opacity(hidesLabel ? 0 : 1)
                }
                .buttonStyle(style)
                .disabled(!isEnabled)
                .allowsHitTesting(false)
                .frame(width: 180, height: 48)
                .background(Color(white: backgroundWhite))
                .environment(\.colorScheme, .light),
                size: CGSize(width: 180, height: 48)
            ) { view in
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        let color = try #require(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        pixels.append(Double((color.redComponent + color.greenComponent + color.blueComponent) / 3))
                    }
                }
            }
            return pixels
        }

        let background = try brightness(isEnabled: true, hidesLabel: true, style: .dsPlain)
        let enabled = try brightness(isEnabled: true, style: .dsPlain)
        let disabled = try brightness(isEnabled: false, style: .dsPlain)
        let undimmed = try brightness(isEnabled: false, style: UndimmedStyle())
        try #require([enabled.count, disabled.count, undimmed.count].allSatisfy { $0 == background.count })

        // Subtract an identical blank-label render so host chrome and background cannot dilute
        // the ratio. Sample the same visible glyph pixels in every image, avoiding antialias fringes.
        let labelPixels = background.indices.filter { background[$0] - enabled[$0] > 0.1 }
        func contrast(_ pixels: [Double]) -> Double {
            labelPixels.reduce(0) { $0 + max(0, background[$1] - pixels[$1]) }
        }
        let enabledContrast = contrast(enabled)
        try #require(enabledContrast > 1, "The hosted button label must actually be drawn")
        let disabledRatio = contrast(disabled) / enabledContrast
        #expect(disabledRatio > 0.1, "Disabled text must remain visible")
        #expect(disabledRatio < 0.7, "Disabled text should visibly fade instead of looking actionable")
        // This control omits the style's opacity, proving that native disabled state alone does
        // not satisfy the dimming assertion. Reverting DSPlainButtonStyle to opacity 1 must fail it.
        let undimmedRatio = contrast(undimmed) / enabledContrast
        #expect(undimmedRatio > 0.9, "The undimmed reference must retain the enabled label's contrast")
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
    /// 12 to 10 keeps every `<` true and moves every panel in the window. These numbers are the
    /// redesign's measured values, so changing one should mean editing a test and re-reading why the
    /// number is what it is.
    @Test("The bar, control, row and stroke ladders are the measured values")
    func laddersArePinned() {
        // Sidebar, content and inspector all start 44pt from the top.
        #expect(DSBarHeight.column == 44)
        #expect(DSBarHeight.jumpBar == 30)
        #expect(DSBarHeight.paneHeader == 40)
        #expect(DSBarHeight.footer == 44)

        #expect(DSControlHeight.small == 20)
        #expect(DSControlHeight.regular == 24)
        #expect(DSControlHeight.large == 28)
        #expect(DSControlHeight.prominent == 32)

        #expect(DSRowHeight.list == 28)
        #expect(DSRowHeight.table == 24)
        #expect(DSRowHeight.groupHeader == 22)
        #expect(DSRowHeight.step == 36)
        #expect(DSRowHeight.recent == 44)

        #expect(DSStroke.hairline == 0.5)
        #expect(DSStroke.emphasis == 1)
        #expect(DSStroke.focusHalo == 3.5)

        // The relationships the comments claim, stated where they can fail: the panels share the
        // column bar, and a panel header stands on the ladder rather than owning its own number.
        #expect(DSPanelHeader<EmptyView>.height == DSBarHeight.paneHeader)
        #expect(DSInspectorMetrics.headerHeight == DSBarHeight.column)
        #expect(DSInspectorMetrics.footerHeight == DSBarHeight.footer)
        #expect(DSNavigatorMetrics.footerHeight == DSBarHeight.footer)
        #expect(DSNavigatorMetrics.rowHeight == DSRowHeight.list)
        #expect(DSInspectorMetrics.rowHeight == DSRowHeight.list)
    }

    /// Panel widths and sheet widths: the numbers the window's layout turns on.
    @Test("Layout and sheet widths are the measured values")
    func layoutWidthsArePinned() {
        #expect(DSLayout.sidebarWidth == 264)
        #expect(DSLayout.sidebarMinimumWidth == 220)
        #expect(DSLayout.sidebarMaximumWidth == 360)
        #expect(DSLayout.inspectorWidth == 300)
        #expect(DSLayout.inspectorMinimumWidth == 260)
        #expect(DSLayout.inspectorMaximumWidth == 480)
        #expect(DSLayout.panelInset == 8)
        #expect(DSLayout.methodColumn == 52)

        #expect(DSSheetWidth.compact == 440)
        #expect(DSSheetWidth.medium == 560)
        #expect(DSSheetWidth.wide == 680)
        #expect(DSSheetWidth.split == 760)
        #expect(DSSheetWidth.review == 860)
    }

    /// The glyph ladder, and the floor under it.
    ///
    /// **The floor is asserted separately, and it is not redundant with the values above it.** A
    /// new rung would pass every value line here while sitting at 7pt — which is the failure the
    /// house rule is about, since a mark that small stops reading as a mark. `minimum` is a bound,
    /// not a size to draw at, so it is checked against rather than listed as a rung.
    @Test("The glyph ladder is the measured values, and nothing sits below the floor")
    func glyphLadderIsPinned() {
        #expect(DSGlyph.disclosure == 10)
        #expect(DSGlyph.field == 12)
        #expect(DSGlyph.button == 14)
        #expect(DSGlyph.control == 15)
        #expect(DSGlyph.toolbar == 16)
        #expect(DSGlyph.card == 22)
        #expect(DSGlyph.illustration == 28)

        #expect(DSGlyph.minimum == 8)

        let ladder = [
            DSGlyph.disclosure,
            DSGlyph.field,
            DSGlyph.button,
            DSGlyph.control,
            DSGlyph.toolbar,
            DSGlyph.card,
            DSGlyph.illustration
        ]

        // "No glyph below 8pt" — the rule, stated where it can fail rather than remembered. The
        // smallest derived size in the module is `disclosure - 1`, which is why that rung carries
        // headroom above the floor.
        for rung in ladder {
            #expect(rung >= DSGlyph.minimum)
        }
        #expect(DSGlyph.disclosure - 1 >= DSGlyph.minimum)
    }

    /// Spacing and radius are measured, so they are pinned by value; animation durations only have
    /// to stay in order and distinct, which is exactly what `<` says.
    @Test("Spacing and radius are pinned by value; animation tiers stay ordered")
    func tokenValuesStayConsistent() {
        // rung, what the token reads, what it is measured to be
        let spacing: [(String, CGFloat, CGFloat)] = [
            ("xxs", DSSpacing.xxs, 2),
            ("xs", DSSpacing.xs, 4),
            ("sm", DSSpacing.sm, 8),
            ("md", DSSpacing.md, 12),
            ("lg", DSSpacing.lg, 16),
            ("xl", DSSpacing.xl, 20),
            ("xxl", DSSpacing.xxl, 24),
            ("xxxl", DSSpacing.xxxl, 32)
        ]
        for (rung, measured, expected) in spacing {
            #expect(
                measured == expected,
                """
                DSSpacing.\(rung) is \(measured) where this pins \(expected), and every gap in the \
                window that names that rung has moved with it. If the change is deliberate, rewrite the \
                rung's doc comment in DSSpacing.swift and then this line; otherwise put the value back.
                """
            )
        }

        let radius: [(String, CGFloat, CGFloat)] = [
            ("mark", DSCornerRadius.mark, 4),
            ("field", DSCornerRadius.field, 7),
            ("segment", DSCornerRadius.segment, 8),
            ("card", DSCornerRadius.card, 10),
            ("panel", DSCornerRadius.panel, 12),
            ("sheet", DSCornerRadius.sheet, 20)
        ]
        for (rung, measured, expected) in radius {
            #expect(
                measured == expected,
                """
                DSCornerRadius.\(rung) is \(measured) where this pins \(expected). Moving a rung \
                reshapes every call site that draws it. If the change is deliberate, update the rung's \
                doc comment in DSCornerRadius.swift and then this line; otherwise put it back.
                """
            )
        }

        _ = DSAnimation.spring()
        _ = DSAnimation.panel

        #expect(DSAnimation.fast == 0.10)
        #expect(DSAnimation.normal == 0.20)
        #expect(DSAnimation.slow == 0.30)
        #expect(DSAnimation.fast < DSAnimation.normal)
        #expect(DSAnimation.normal < DSAnimation.slow)
    }
}
