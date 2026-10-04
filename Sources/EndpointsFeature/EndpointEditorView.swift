import AppKit
import SwiftUI
import Domain
import DesignSystem
import FeatureSupport

private enum EditorMetrics {
    static let statusFieldWidth: CGFloat = 196
    static let delayFieldWidth: CGFloat = 92
    static let contentTypeFieldWidth: CGFloat = 120
    static let headerKeyWidth: CGFloat = 200
    /// The least height of the body's text viewport, the part that scrolls. Above it the body and
    /// headers cards take whatever the pane has left, down to the request log.
    static let bodyMinHeight: CGFloat = 120
    /// The scenario title row: as tall as the boards' Make live button, 24pt with a half-point
    /// border above and below (`.btn` is content-box).
    static let titleRowHeight: CGFloat = 25
    /// The boards' link-button slot for an icon: 14pt mark, 6pt either side.
    static let copyURLWidth: CGFloat = 26
    /// The scenario menu's slot: the boards' 16pt icon with 6pt either side.
    static let scenarioMenuWidth: CGFloat = 28
}

/// The endpoint editor: the request it answers, the scenario being edited, and that scenario's response.
public struct EndpointEditorView: View {
    enum Pane: Hashable {
        case body
        case headers
    }

    let endpoint: Endpoint
    /// The scenario being edited. It is live only when it is the endpoint's active scenario.
    let activeScenario: Scenario?
    let globalDelayMs: Int
    var backends: [BackendConfiguration] = []
    /// `localhost:8080`, shown before the path in the request bar.
    var baseAddress: String?
    let actions: EndpointEditorActions

    @State private var statusCodeString = ""
    @State private var responseBody = ""
    @State private var bodyDocumentID: String?
    @State private var delayString = ""
    @State private var groupTag = ""
    @State private var headers: [HeaderEntry] = []
    @State private var pane: Pane = .body
    @State private var statusCodeError: String?
    @State private var delayError: String?
    @State private var formatCandidate: (source: String, output: String)?
    /// The body as the model last filled it in, which needs no settling before Format can use it.
    @State private var lastSyncedBody: String?
    @State private var showDeleteConfirmation = false
    @State private var renameScenarioTarget: Scenario?
    @State private var didCopyURL = false
    @State private var pendingEdits: EndpointEditorPendingEdits
    @FocusState private var isDelayFocused: Bool
    @FocusState private var isStatusFocused: Bool

    public init(endpoint: Endpoint, activeScenario: Scenario?, globalDelayMs: Int, backends: [BackendConfiguration] = [],
         baseAddress: String? = nil, actions: EndpointEditorActions) {
        self.init(
            endpoint: endpoint,
            activeScenario: activeScenario,
            globalDelayMs: globalDelayMs,
            backends: backends,
            baseAddress: baseAddress,
            actions: actions,
            initialStatusCodeString: "",
            initialResponseBody: "",
            initialDelayString: "",
            initialGroupTag: "",
            initialHeaders: []
        )
    }

    init(
        endpoint: Endpoint,
        activeScenario: Scenario?,
        globalDelayMs: Int,
        backends: [BackendConfiguration] = [],
        baseAddress: String? = nil,
        actions: EndpointEditorActions,
        initialStatusCodeString: String,
        initialResponseBody: String,
        initialDelayString: String,
        initialGroupTag: String,
        initialHeaders: [(String, String)],
        pendingEdits: EndpointEditorPendingEdits? = nil
    ) {
        self.endpoint = endpoint
        self.activeScenario = activeScenario
        self.globalDelayMs = globalDelayMs
        self.backends = backends
        self.baseAddress = baseAddress
        self.actions = actions
        _statusCodeString = State(initialValue: initialStatusCodeString)
        _responseBody = State(initialValue: initialResponseBody)
        _delayString = State(initialValue: initialDelayString)
        _groupTag = State(initialValue: initialGroupTag)
        _headers = State(initialValue: initialHeaders.map { HeaderEntry(key: $0.0, value: $0.1) })
        // Passed in only where two view values have to share one store, which is what SwiftUI does
        // for real: the editor carries no `.id(…)`, so the endpoint you click arrives as a new view
        // value over the boxes the old one was using.
        _pendingEdits = State(initialValue: pendingEdits ?? EndpointEditorPendingEdits())
    }

    private var isLive: Bool {
        activeScenario != nil && activeScenario?.id == endpoint.activeScenarioID
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            requestBar

            if let scenario = activeScenario {
                scenarioTitleRow(scenario)
                responseFields
                paneBar
                switch pane {
                case .body: bodyEditor
                case .headers: headersEditor
                }
            } else {
                DSEmptyState(
                    heading: "No live scenario",
                    message: "Add a scenario in the inspector, or make one live, to edit this endpoint's response.",
                    identifier: "editor.noActiveScenario"
                )
            }
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, DSSpacing.lg)
        // As tall as the pane: the body or headers card takes the room the request log leaves, so
        // the log still starts right below the editor and moving or hiding the log resizes the card
        // rather than leaving empty space under it.
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear { syncFromModel() }
        .onChange(of: endpoint.id) { endpointSelectionChanged() }
        .onChange(of: activeScenario?.id) { scenarioSelectionChanged() }
        .onChange(of: endpoint) { previous, current in
            guard previous.id == current.id else { return }
            refreshUneditedFields(from: previous)
        }
        .onChange(of: statusCodeString) { debounceStatusCode() }
        // Worded as the sidebar's confirmation, which the Alerts board draws.
        .alert(SidebarView.deleteTitle(for: endpoint), isPresented: $showDeleteConfirmation) {
            Button("Delete endpoint", role: .destructive) { actions.onDelete() }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(SidebarView.deleteMessage(scenarioCount: endpoint.scenarios.count))
        }
        .sheet(item: $renameScenarioTarget) { scenario in
            RenameItemSheet(
                title: "Rename scenario", fieldLabel: "Scenario name",
                identifier: "scenarioRename", initialName: scenario.name
            ) { name in
                actions.onRenameScenario(scenario.id, name)
            }
        }
        // Container first, then its name. The other order names every descendant "endpointEditor":
        // the path, status field, method menu and Add header all lost their own identifiers, while
        // only controls that declare their own container (the segmented control) kept theirs.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("endpointEditor")
    }

    // MARK: - Request bar

    /// The request this endpoint answers: method, address, and path, with the endpoint's actions
    /// behind the method.
    private var requestBar: some View {
        HStack(spacing: 10) {
            endpointMenu

            Rectangle()
                .fill(DSColors.separator)
                .frame(width: DSStroke.hairline, height: 18)
                .accessibilityHidden(true)

            // The path is what identifies the endpoint, so the base address gives way first: it is
            // drawn only while address and path both fit whole, and the path alone takes a middle
            // truncation after that.
            ViewThatFits(in: .horizontal) {
                if let baseAddress {
                    HStack(spacing: 0) {
                        Text(baseAddress)
                            .foregroundStyle(DSColors.labelTertiary)
                            .accessibilityHidden(true)
                        requestPath
                    }
                }
                requestPath
            }
            .font(DSTypography.codeLarge)
            .lineLimit(1)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: copyURL) {
                // The boards' link button: the two-squares copy mark at the compact button's glyph
                // size, in a 26pt slot.
                Image(systemName: didCopyURL ? "checkmark" : "square.on.square")
                    .font(.system(size: DSGlyph.field))
                    .contentTransition(.symbolEffect(.replace))
                    .frame(width: EditorMetrics.copyURLWidth, height: DSControlHeight.regular)
            }
            .buttonStyle(DSIconButtonStyle())
            .help("Copy the URL")
            .accessibilityIdentifier("endpointEditor.copyURL")
            .accessibilityLabel(didCopyURL ? "Copied URL" : "Copy URL")
        }
        .dsFieldChrome(height: DSControlHeight.prominent, cornerRadius: DSCornerRadius.card,
                       isFocused: false, horizontalPadding: 10)
        .padding(.trailing, 0)
        .task(id: didCopyURL) {
            guard didCopyURL else { return }
            try? await Task.sleep(for: .seconds(1.5))
            didCopyURL = false
        }
    }

    private var requestPath: some View {
        Text(endpoint.graphqlOperation.flatMap { $0.isEmpty ? nil : "\(endpoint.path) · \($0)" } ?? endpoint.path)
            .foregroundStyle(DSColors.labelPrimary)
            .truncationMode(.middle)
            .layoutPriority(1)
            .help(endpoint.path)
            .accessibilityIdentifier("endpointEditor.path")
    }

    private var endpointURL: String {
        "http://\(baseAddress ?? "localhost")\(endpoint.path)"
    }

    private func copyURL() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(endpointURL, forType: .string)
        didCopyURL = true
    }

    /// The method, which opens the endpoint's own actions.
    private var endpointMenu: some View {
        Menu {
            Button("Edit request\u{2026}", systemImage: "pencil.line", action: actions.onEditRequest)
                .accessibilityIdentifier("endpointEditor.moreMenu.editRequest")
            Button("Rename endpoint\u{2026}", systemImage: "pencil", action: actions.onRename)
                .accessibilityIdentifier("endpointEditor.moreMenu.rename")
            Button("Duplicate endpoint", systemImage: "doc.on.doc", action: actions.onDuplicate)
                .accessibilityIdentifier("endpointEditor.moreMenu.duplicate")
            Divider()
            Button("Delete endpoint\u{2026}", systemImage: "trash", role: .destructive) {
                showDeleteConfirmation = true
            }
            .accessibilityIdentifier("endpointEditor.moreMenu.delete")
        } label: {
            // The label is the chevron alone, framed across the method as well, as `DSIconMenu`
            // frames its glyph. A label with text is flattened into the pop-up button's title, and
            // AppKit then sizes the control to that title — a 14pt target — whatever the frame says.
            // The method is drawn behind it, inside the pop-up's frame.
            // It stays an SF Symbol: AppKit's pop-up button takes only an image from the label, and a
            // drawn shape left the control without one, so it vanished from accessibility.
            Label("Endpoint actions", systemImage: "chevron.down")
                .labelStyle(.iconOnly)
                .font(.system(size: DSGlyph.disclosure - 1, weight: .semibold))
                .foregroundStyle(DSColors.labelTertiary)
                .frame(width: endpointMenuWidth, height: DSControlHeight.regular, alignment: .trailing)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: endpointMenuWidth, height: DSControlHeight.regular)
        // Drawn behind the menu, whose pop-up button spans the method too, so a click on the
        // method's letters opens it.
        .background(alignment: .leading) {
            DSMethodLabel(endpoint.method.rawValue, fixedWidth: false, identifier: "editor.method")
                .fixedSize()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .help("Endpoint actions")
        .accessibilityIdentifier("endpointEditor.moreMenu")
        .accessibilityLabel("Endpoint actions, \(endpoint.method.rawValue)")
    }

    /// The method, the gap and the chevron's slot. Measured from the method's font rather than read
    /// back from layout: the pop-up button takes its size from the label's first frame and keeps it,
    /// so a width that arrived a pass later left the click target at the chevron alone.
    private var endpointMenuWidth: CGFloat {
        let method = endpoint.method.rawValue.uppercased()
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold) // `DSTypography.method`
        let text = (method as NSString).size(withAttributes: [.font: font]).width
        let tracking = 0.2 * CGFloat(method.count)
        return (text + tracking).rounded(.up) + DSSpacing.xs + DSGlyph.disclosure
    }

    // MARK: - Scenario

    private func scenarioTitleRow(_ scenario: Scenario) -> some View {
        HStack(spacing: 10) {
            Text(scenario.name)
                .font(DSTypography.headline)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .accessibilityIdentifier("endpointEditor.scenarioName")
                .accessibilityAddTraits(.isHeader)

            HStack(spacing: 5) {
                DSLiveIndicator(isLive: isLive, size: 12)
                Text(isLive ? "Live" : "Not live")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("endpointEditor.liveState")

            Spacer(minLength: DSSpacing.sm)

            if !isLive {
                DSButton("Make live", variant: .secondary, size: .medium, identifier: "endpointEditor.makeLive") {
                    actions.onMakeLive(scenario.id)
                }
                .help("Serve this scenario on every request")
            }

            DSIconMenu(systemImage: "ellipsis", help: "Scenario actions", identifier: "endpointEditor.scenarioMenu",
                       width: EditorMetrics.scenarioMenuWidth) {
                Button("Rename scenario\u{2026}", systemImage: "pencil") { renameScenarioTarget = scenario }
                    .accessibilityIdentifier("endpointEditor.scenarioMenu.rename")
                Button("Duplicate scenario", systemImage: "doc.on.doc") { actions.onDuplicateScenario(scenario.id) }
                    .accessibilityIdentifier("endpointEditor.scenarioMenu.duplicate")
                Divider()
                Button("Delete scenario", systemImage: "trash", role: .destructive) {
                    actions.onDeleteScenario(scenario.id)
                }
                .disabled(endpoint.scenarios.count <= 1)
                .accessibilityIdentifier("endpointEditor.scenarioMenu.delete")
            }
        }
        .frame(minHeight: EditorMetrics.titleRowHeight)
    }

    // MARK: - Response fields

    private var responseFields: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs + 2) {
            ViewThatFits(in: .horizontal) {
                // The design's one row.
                HStack(spacing: DSSpacing.xl) {
                    labeled("Status") { statusControl(width: EditorMetrics.statusFieldWidth) }
                    labeled("Delay") { delayControl }
                    labeled("Content type") { contentTypeControl }
                }
                // Status on its own row, Delay and Content type below it.
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    labeled("Status") { statusControl(width: EditorMetrics.statusFieldWidth) }
                    HStack(spacing: DSSpacing.xl) {
                        labeled("Delay") { delayControl }
                        labeled("Content type") { contentTypeControl }
                    }
                }
                // Narrowest: one field a row, labels in a column, and Status gives up its fixed
                // width so the reason phrase truncates instead of the field running off the pane.
                Grid(alignment: .leading, horizontalSpacing: DSSpacing.sm, verticalSpacing: DSSpacing.sm) {
                    GridRow {
                        fieldLabel("Status")
                        statusControl(width: nil)
                    }
                    GridRow {
                        fieldLabel("Delay")
                        delayControl
                    }
                    GridRow {
                        fieldLabel("Content type")
                        contentTypeControl
                    }
                }
            }
            if let statusCodeError {
                DSValidationMessage(statusCodeError, identifier: "endpointEditor.statusCode.error")
            }
            if let delayError {
                DSValidationMessage(delayError, identifier: "endpointEditor.delay.error")
            }
        }
    }

    private func labeled<Control: View>(_ title: String, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: DSSpacing.sm) {
            fieldLabel(title)
            control()
        }
    }

    private func fieldLabel(_ title: String) -> some View {
        Text(title)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(1)
            .fixedSize()
    }

    /// The status well at the design's `width`, or, with `nil`, filling what the row offers.
    private func statusControl(width: CGFloat?) -> some View {
        StatusCodeField(
            text: $statusCodeString,
            code: Self.statusCodeValue(from: statusCodeString),
            size: .panel,
            isInvalid: statusCodeError != nil,
            isFocused: $isStatusFocused,
            fieldIdentifier: "endpointEditor.statusCode",
            menuIdentifier: "endpointEditor.statusMenu",
            reasonIdentifier: "endpointEditor.statusDescription",
            onCommit: commitStatusCode
        )
        .frame(width: width)
        .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
    }

    private var delayControl: some View {
        HStack(spacing: DSSpacing.xs) {
            TextField("0", text: $delayString)
                .textFieldStyle(.plain)
                .font(DSTypography.Figure.regular)
                .focused($isDelayFocused)
                .accessibilityIdentifier("endpointEditor.delay")
                .accessibilityLabel("Endpoint delay in milliseconds")
                .onChange(of: delayString) { delayError = nil }
                .onChange(of: isDelayFocused) { _, focused in
                    if !focused { commitDelay() }
                }
                .onSubmit { commitDelay() }
            Text("ms")
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityHidden(true)
        }
        .dsFieldChrome(isFocused: isDelayFocused, isInvalid: delayError != nil)
        .frame(width: EditorMetrics.delayFieldWidth)
        .help(globalDelayMs > 0
              ? "The project adds \(globalDelayMs) ms to this delay"
              : "Wait this long before answering")
    }

    private var contentTypeControl: some View {
        Menu {
            Button("JSON") { actions.onUpdateContentType(.json) }
                .accessibilityIdentifier("endpointEditor.contentType.json")
            Button("Plain text") { actions.onUpdateContentType(.plainText) }
                .accessibilityIdentifier("endpointEditor.contentType.plainText")
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text(activeScenario?.bodyContentType == .plainText ? "Plain text" : "JSON")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                DSDisclosureChevron(.down)
            }
            .dsFieldChrome(isFocused: false)
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .frame(width: EditorMetrics.contentTypeFieldWidth)
        .accessibilityIdentifier("endpointEditor.contentType")
        .accessibilityLabel("Content type")
        // A menu's label is flattened into the button, so the chosen type is not a text of its
        // own: say it as the value, as the new-endpoint sheet's menu does.
        .accessibilityValue(activeScenario?.bodyContentType == .plainText ? "Plain text" : "JSON")
    }

    // MARK: - Body and headers

    private var paneBar: some View {
        HStack(spacing: DSSpacing.sm) {
            DSSegmentedControl(
                "Response part",
                segments: [
                    .init("Body", value: Pane.body, identifier: "endpointEditor.tab.body"),
                    .init("Headers", value: Pane.headers, count: headers.isEmpty ? nil : headers.count,
                          identifier: "endpointEditor.toggleHeaders"),
                ],
                selection: $pane,
                identifier: "endpointEditor.pane"
            )
            .layoutPriority(1)
            Spacer(minLength: DSSpacing.sm)
            // Labelled while there is room, icon-only below that: a label cut to "…" says nothing.
            // Both variants keep the identifiers, accessibility labels and tooltips.
            ViewThatFits(in: .horizontal) {
                paneActions(showsTitles: true)
                paneActions(showsTitles: false)
            }
        }
    }

    @ViewBuilder
    private func paneActions(showsTitles: Bool) -> some View {
        HStack(spacing: DSSpacing.sm) {
            switch pane {
            case .body:
                DSButton("Format", systemImage: "text.alignleft", variant: .ghost, size: .compact,
                         showsTitle: showsTitles, identifier: "endpointEditor.format") {
                    if let formatCandidate, formatCandidate.source == responseBody {
                        responseBody = formatCandidate.output
                        commitBody()
                    }
                }
                .disabled(!canFormatBody)
                .help("Pretty-print the JSON body")
                .accessibilityIdentifier("endpointEditor.prettyPrintButton")
                .accessibilityLabel("Pretty-print JSON")
                DSButton("Copy", systemImage: "square.on.square", variant: .ghost, size: .compact,
                         showsTitle: showsTitles, identifier: "endpointEditor.copyBody") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(responseBody, forType: .string)
                }
                .disabled(responseBody.isEmpty)
                .help("Copy the response body")
            case .headers:
                DSButton("Add header", systemImage: "plus", variant: .ghost, size: .compact,
                         showsTitle: showsTitles, identifier: "endpointEditor.addHeader") {
                    headers.append(HeaderEntry(key: "", value: ""))
                }
                .help("Add a response header")
                .accessibilityIdentifier("endpointEditor.addHeaderButton")
                .accessibilityLabel("Add header")
            }
        }
        .fixedSize()
    }

    private var bodyEditor: some View {
        // The minimum is the text viewport's, not the card's: the card adds its own padding around
        // it, and a short pane squeezes the body to exactly this minimum.
        DSJSONEditor(text: $responseBody, identifier: "editor.body", documentID: bodyDocumentID,
                     minimumViewportHeight: EditorMetrics.bodyMinHeight)
            .frame(maxHeight: .infinity, alignment: .top)
            .onChange(of: responseBody) { debounceBody() }
            .task(id: responseBody) {
                let source = responseBody
                // A body read from the model is already settled, so Format is ready as soon as the
                // scenario shows; only typing waits for the person to pause.
                if source != lastSyncedBody {
                    do { try await Task.sleep(for: Self.settling) } catch { return }
                }
                let output = await Task.detached(priority: .userInitiated) {
                    DSJSONEditor.prettyPrint(source)
                }.value
                guard !Task.isCancelled, responseBody == source else { return }
                formatCandidate = output.map { (source: source, output: $0) }
            }
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 0) {
            if headers.isEmpty {
                // Centred in the card both ways, as every other empty state is.
                Text("No custom headers")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelTertiary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .accessibilityIdentifier("endpointEditor.headers.empty")
            } else {
                ScrollView {
                    VStack(spacing: DSSpacing.sm) {
                        ForEach($headers) { header in
                            headerRow(header)
                        }
                    }
                    .padding(DSSpacing.md)
                }
                .accessibilityIdentifier("endpointEditor.headers.count")
            }
        }
        // The body card's extent, so switching between Body and Headers moves nothing below them.
        .frame(minHeight: EditorMetrics.bodyMinHeight + DSJSONEditor.cardVerticalPadding, maxHeight: .infinity, alignment: .top)
        .background(DSColors.code)
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.card, style: .continuous)
                .strokeBorder(DSColors.separator, lineWidth: DSStroke.hairline)
        }
        .onChange(of: headers) { debounceHeaders() }
    }

    @ViewBuilder
    private func headerRow(_ header: Binding<HeaderEntry>) -> some View {
        let index = position(of: header.wrappedValue)

        HStack(spacing: DSSpacing.sm) {
            TextField("Name", text: header.key)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .dsFieldChrome(isFocused: false)
                .frame(maxWidth: EditorMetrics.headerKeyWidth)
                .accessibilityIdentifier("endpointEditor.headerKey.\(index)")
                .accessibilityLabel("Header name")
                .onSubmit { commitHeaders() }

            TextField("Value", text: header.value)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .dsFieldChrome(isFocused: false)
                .accessibilityIdentifier("endpointEditor.headerValue.\(index)")
                .accessibilityLabel("Header value")
                .onSubmit { commitHeaders() }

            DSIconButton("Remove header", systemImage: "minus.circle",
                         identifier: "endpointEditor.removeHeader.\(index)") {
                removeHeader(id: header.wrappedValue.id)
            }
        }
    }

    private func position(of entry: HeaderEntry) -> Int {
        headers.firstIndex { $0.id == entry.id } ?? 0
    }

    private func removeHeader(id: HeaderEntry.ID) {
        headers.removeAll { $0.id == id }
        commitHeaders()
    }

    // MARK: - Derived state

    private var canFormatBody: Bool {
        // The scanner can reject valid JSON when indentation would exceed its output budget.
        // Compare the source as well so a result from the previous body cannot enable Format.
        formatCandidate?.source == responseBody
    }

    // MARK: - Sync & Commit

    /// What "settled" means for the three debounced fields. `debounceStatusCode` carries the
    /// reasoning; the number lives here so the three cannot come apart by a keystroke.
    private static let settling: Duration = .milliseconds(300)

    /// What `.onChange(of: endpoint.id)` runs when the sidebar selection moves.
    ///
    /// The flush comes first, and it belongs here rather than inside `syncFromModel`.
    ///
    /// First, because the sync *is* what loses the edit: every assignment it makes trips an
    /// `onChange`, and each handler opens by dropping the timer holding the value still being typed.
    /// The `…IsDirty` guards below stop a sync from *scheduling* a write, which is a different half
    /// of the problem and the only half they were ever able to see.
    ///
    /// `onAppear` has nothing to finish. A scenario change does have pending edits to finish;
    /// `scenarioSelectionChanged()` does so through actions captured for the old scenario.
    ///
    /// The scenario modifier usually fires on a selection change too, since a different endpoint
    /// owns different scenarios — though not always: two endpoints that carry no scenarios at all
    /// both hold a `nil` active id, and that state is legal (`ProjectValidator` refuses a missing id
    /// only *beside* scenarios). Either way this modifier is the one that matters, and either order
    /// is fine: an `onChange` action runs on the update *after* the assignment that triggered it, so
    /// a sync the scenario modifier performs cannot have cancelled anything by the time this one
    /// flushes.
    func endpointSelectionChanged() {
        pendingEdits.flush()
        syncFromModel()
    }

    /// Finish text typed into the previous scenario before showing the newly active one.
    /// `CenterPaneView` captures the scenario id in each action closure, so this flush cannot
    /// redirect an old edit to the scenario that has just become active.
    func scenarioSelectionChanged() {
        pendingEdits.flush()
        syncFromModel()
    }

    /// Fills the fields from whatever the model currently holds.
    ///
    /// Every assignment here trips the `.onChange` handlers above, which cannot tell a character a
    /// person typed from one this method just wrote — so merely *selecting* an endpoint used to
    /// schedule a write of the data it had that moment finished reading. The three `…IsDirty` guards
    /// close that: a field filled from the model matches the model, so nothing is scheduled. A flag
    /// raised around this method would not work, because SwiftUI runs an `onChange` action on the
    /// *next* update, by which time a flag lowered on the way out of here has been lowered for some
    /// time.
    ///
    /// What those guards do not close — and what this note used to claim they did — is the opposite
    /// direction. A handler *cancels* before it reaches its guard, so an edit that was still settling
    /// when the fields changed underneath it was dropped by the sync that replaced it, and since
    /// every keystroke restarts the timer, continuous typing lost the whole edit rather than its
    /// tail. `endpointSelectionChanged()` finishes those edits before this method runs at all.
    private func syncFromModel() {
        guard let synced = Self.syncedValues(endpoint: endpoint, activeScenario: activeScenario) else { return }
        statusCodeString = synced.statusCodeString
        responseBody = synced.responseBody
        lastSyncedBody = synced.responseBody
        bodyDocumentID = activeScenario.map { "\(endpoint.id.uuidString):\($0.id.uuidString)" }
        delayString = synced.delayString
        groupTag = synced.groupTag
        headers = synced.headers.map { HeaderEntry(key: $0.0, value: $0.1) }
        delayError = nil
        // A complaint about the endpoint you just navigated away from is not about anything on
        // screen any more.
        statusCodeError = nil
    }

    /// A control command can update the selected model without changing either selection ID.
    /// Refresh each clean field independently so another writer cannot leave a stale response on
    /// screen, while a local draft (including an invalid status or an unfinished header row) stays
    /// intact. Selection changes still take the separate flush-and-sync path above.
    private func refreshUneditedFields(from previous: Endpoint) {
        guard let activeScenario,
              let previousScenario = previous.scenarios.first(where: { $0.id == activeScenario.id }) else { return }

        if previousScenario.statusCode != activeScenario.statusCode,
           statusCodeString == String(previousScenario.statusCode) {
            pendingEdits.cancel(.statusCode)
            statusCodeString = String(activeScenario.statusCode)
            statusCodeError = nil
        }
        if previousScenario.body != activeScenario.body,
           responseBody == (previousScenario.body ?? "") {
            pendingEdits.cancel(.body)
            responseBody = activeScenario.body ?? ""
            lastSyncedBody = responseBody
        }
        if previousScenario.headers != activeScenario.headers,
           headers.count == previousScenario.headers.count,
           Set(headers.map(\.key)).count == headers.count,
           headers.allSatisfy({ previousScenario.headers[$0.key] == $0.value }) {
            pendingEdits.cancel(.headers)
            headers = activeScenario.headers.sorted { $0.key < $1.key }
                .map { HeaderEntry(key: $0.key, value: $0.value) }
        }
        if previous.delayMs != endpoint.delayMs, delayString == String(previous.delayMs) {
            delayString = String(endpoint.delayMs)
            delayError = nil
        }
        if previous.groupTag != endpoint.groupTag, groupTag == (previous.groupTag ?? "") {
            groupTag = endpoint.groupTag ?? ""
        }
    }

    /// Writes the status code if it is one the server can serve, and says why not if it is not.
    ///
    /// Both callers reach here only once the value has settled — the debounce below, and Return,
    /// which is a person saying "I have finished typing" in as many words. Dropping the timer first
    /// is what stops the same value being written again 300ms later.
    func commitStatusCode() {
        pendingEdits.cancel(.statusCode)
        commit(statusCode: statusCodeString)
    }

    /// The write itself, taking the text rather than reading the field.
    ///
    /// A pending value is taken when it is typed, not read when it lands. `statusCodeString` is a
    /// `@State` box the endpoint that replaces this one writes through, so a pending write that read
    /// the field would say something different depending on whether the sync had happened yet — and
    /// the whole business of this file is that it is about to. `actions` needs no such care: `self`
    /// is a struct, so the copy a pending closure captured still addresses the endpoint the text was
    /// typed into.
    private func commit(statusCode text: String) {
        guard let code = Self.statusCodeValue(from: text) else {
            statusCodeError = Self.statusCodeValidationMessage(for: text)
            return
        }
        statusCodeError = nil
        actions.onUpdateScenario(code, nil, nil)
    }

    /// Waits for the typing to stop, then commits — and, if the settled value is not serveable, is
    /// also where the complaint under the field comes from.
    ///
    /// Settling here rather than on blur is deliberate. "6" and "60" are honest prefixes of "600",
    /// so raising a message on every keystroke would flash a complaint twice while someone types
    /// three digits; waiting for focus to leave would hold the news back until after the user had
    /// moved on, and this field is edited by clicking straight into it and typing, often without
    /// ever leaving — the delay and group tag fields commit on blur precisely because nothing else
    /// tells them when a value is finished, which is not true here. The 300ms the commit already
    /// waits for is the moment the value stops being a prefix and starts being an answer, so the
    /// message rides the timer that is already there: no second timer, and no state that says
    /// "typing" separately from "committing".
    func debounceStatusCode() {
        pendingEdits.cancel(.statusCode)

        // Raised only at a settle point, but kept current on every keystroke once it is up: a
        // message that is already on screen has to track the field under it, and it comes down the
        // instant the text is serveable again rather than 300ms later. Clearing it unconditionally
        // here would be worse than either — the message would blink off and back on for anyone
        // typing with pauses longer than the debounce.
        if statusCodeError != nil {
            statusCodeError = Self.statusCodeValidationMessage(for: statusCodeString)
        }

        let pendingStatusCode = statusCodeString
        guard Self.statusCodeIsDirty(pendingStatusCode, against: activeScenario) else { return }

        // The text goes in by value and `self` goes in as a struct copy, which together are what
        // make a flush land where it should: the copy keeps the `actions` this view was built with,
        // so the write still addresses the endpoint the text was typed into once the selection has
        // moved. Only the `@State` boxes are shared with the view value that replaces it.
        pendingEdits.schedule(.statusCode, after: Self.settling) {
            commit(statusCode: pendingStatusCode)
        }
    }

    /// See `commitStatusCode()` for why the timer is dropped first.
    func commitHeaders() {
        pendingEdits.cancel(.headers)
        commit(headers: headers.map { ($0.key, $0.value) })
    }

    private func commit(headers entries: [(String, String)]) {
        actions.onUpdateScenario(nil, Self.headersDictionary(from: entries), nil)
    }

    func debounceHeaders() {
        pendingEdits.cancel(.headers)

        let pendingHeaders = headers.map { ($0.key, $0.value) }
        guard Self.headersAreDirty(pendingHeaders, against: activeScenario) else { return }

        // See `debounceStatusCode` for why the rows and the actions are both taken now.
        pendingEdits.schedule(.headers, after: Self.settling) {
            commit(headers: pendingHeaders)
        }
    }

    /// See `commitStatusCode()` for why the timer is dropped first.
    func commitBody() {
        pendingEdits.cancel(.body)
        commit(body: responseBody)
    }

    /// The action was bound to the scenario shown when the text was typed.
    private func commit(body text: String) {
        // nil means "leave this field unchanged" in ScenarioSpec. An empty string is the explicit
        // clear operation, so deleting the last character must still be forwarded to the model.
        actions.onUpdateScenario(nil, nil, text)
    }

    func debounceBody() {
        pendingEdits.cancel(.body)

        let pendingBody = responseBody
        guard Self.bodyIsDirty(pendingBody, against: activeScenario) else { return }

        // See `debounceStatusCode` for why the text and the actions are both taken now.
        pendingEdits.schedule(.body, after: Self.settling) {
            commit(body: pendingBody)
        }
    }

    /// Says why, instead of returning quietly.
    ///
    /// This used to be a bare `guard … else { return }`: type "abc" or "-5", click away, and the
    /// field kept showing what you typed while the endpoint kept its old delay — no message, and no
    /// sign anything had been rejected. Switching endpoints then restored the old value, so a change
    /// that looked accepted had never happened. `statusCodeError` in this same file already had the
    /// answer; the delay field just never got one.
    func commitDelay() {
        if Int(delayString) == endpoint.delayMs { delayError = nil; return }
        guard let delay = Self.delayValue(from: delayString) else {
            delayError = "Delay must be a whole number from 0 to \(ResponseDelay.maximumMilliseconds) ms"
            return
        }
        guard ResponseDelay.isWithinLimit(globalMs: globalDelayMs, localMs: delay)
                || delay < endpoint.delayMs else {
            delayError = "Global plus endpoint delay must not exceed \(ResponseDelay.maximumDescription)"
            return
        }
        delayError = nil
        actions.onUpdateDelay(delay)
    }

    func commitGroupTag() {
        actions.onUpdateGroupTag(Self.groupTagValue(from: groupTag))
    }

    static func syncedValues(
        endpoint: Endpoint,
        activeScenario: Scenario?
    ) -> (
        statusCodeString: String,
        responseBody: String,
        delayString: String,
        groupTag: String,
        headers: [(String, String)]
    )? {
        guard let activeScenario else { return nil }
        return (
            "\(activeScenario.statusCode)",
            activeScenario.body ?? "",
            "\(endpoint.delayMs)",
            endpoint.groupTag ?? "",
            activeScenario.headers
                .sorted { $0.key < $1.key }
                .map { ($0.key, $0.value) }
        )
    }

    static func statusCodeValue(from text: String) -> Int? {
        guard let code = Int(text), EndpointValidator.serveableStatusCodes.contains(code) else { return nil }
        return code
    }

    /// What to say about a status code that will not be committed, or `nil` when it will be.
    ///
    /// Phrased as the rule rather than as a verdict on the digits — "Port must be between 1 and
    /// 65535" is the sentence `NewProjectSheet` uses for the same job, and the user can already see
    /// what they typed. Unlike that sheet, an empty field is worth a message here: a port typed into
    /// a sheet is applied when the sheet is confirmed, so a blank one is only an unfinished form,
    /// while this field is live and a blank one means the endpoint is still serving a code the
    /// editor has stopped showing.
    static func statusCodeValidationMessage(for text: String) -> String? {
        guard statusCodeValue(from: text) == nil else { return nil }
        return text.isEmpty
            ? "Enter a status code between 200 and 599"
            : "Status code must be between 200 and 599"
    }

    /// Whether the typed status code is something the model does not already hold.
    ///
    /// `false` for a field that was filled from the model — that is the whole point — and `false`
    /// when there is no active scenario, because then there is nothing to write into.
    static func statusCodeIsDirty(_ text: String, against scenario: Scenario?) -> Bool {
        guard let scenario else { return false }
        return text != "\(scenario.statusCode)"
    }

    /// Whether the edited headers say anything the model does not already say.
    ///
    /// Compared as dictionaries, not as rows: `syncFromModel` rebuilds every `HeaderEntry` with a
    /// fresh `id`, so the array is never equal to the one before it even when the headers are
    /// identical, and an added-but-empty row is not yet a header.
    static func headersAreDirty(_ entries: [(String, String)], against scenario: Scenario?) -> Bool {
        guard let scenario else { return false }
        return headersDictionary(from: entries) != scenario.headers
    }

    /// Whether the edited body says anything the model does not already say. A missing body and an
    /// empty one are the same thing to the editor, which is why the comparison is against `?? ""`.
    static func bodyIsDirty(_ text: String, against scenario: Scenario?) -> Bool {
        guard let scenario else { return false }
        return text != (scenario.body ?? "")
    }

    static func headersDictionary(from headers: [(String, String)]) -> [String: String] {
        var dict: [String: String] = [:]
        for header in headers {
            let key = header.0.trimmingCharacters(in: .whitespaces)
            if !key.isEmpty {
                dict[key] = header.1
            }
        }
        return dict
    }

    static func delayValue(from text: String) -> Int? {
        guard let delay = Int(text), (0...ResponseDelay.maximumMilliseconds).contains(delay) else { return nil }
        return delay
    }

    static func groupTagValue(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Supporting Types

/// The edits the editor has scheduled and not yet written, one slot per debounced field.
///
/// A reference type, and it is `@State`'s semantics that force it. The editor carries no `.id(…)` —
/// see `CenterPaneView` — so clicking a second endpoint hands the *same* `@State` boxes to a new
/// view value. A pending write therefore has to be reachable from a struct that no longer knows the
/// endpoint it was typed into, which three more `@State` values cannot do: whatever the old view
/// wrote into them, the new view reads. One object behind them can be handed over intact.
///
/// The write is a closure rather than a value, because writing it is the whole point of holding it:
/// each one closes over the view value that scheduled it, so it addresses the endpoint whose fields
/// were on screen at the time. `.onChange(of: endpoint.id)` runs the closure from the *new* body —
/// Apple documents that, and it is why the modifier has a two-value form — so a flush that read
/// `actions` off the view at that moment would move the old endpoint's text onto the new one, which
/// is worse than losing it.
@MainActor
final class EndpointEditorPendingEdits {
    /// The three fields that commit on a timer. Delay and group tag commit on blur rather than on a
    /// timer, so they hold no pending value in this store.
    ///
    /// `nonisolated` because `AppFeatures` compiles under `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`
    /// and this enum is nested in a `@MainActor` type: without it, `CaseIterable`'s `allCases` is a
    /// main-actor-isolated static, which is a conformance this repository has already been bitten by
    /// twice. Nothing here is isolated — the only reader is `flush()`, which is on the main actor
    /// anyway — so it costs nothing.
    nonisolated enum Field: Hashable, CaseIterable {
        case statusCode
        case headers
        case body
    }

    private var writes: [Field: () -> Void] = [:]
    private var timers: [Field: Task<Void, Never>] = [:]

    /// Holds `write` for `settling` and then makes it, unless the field is rescheduled, cancelled or
    /// flushed first. Every keystroke reschedules, so a field carries at most one edit — which is
    /// also why an edit lost this way was the whole of the typing rather than its tail.
    ///
    /// The timer holds this object rather than referring to it weakly, which is deliberate on both
    /// counts. The cycle it makes is bounded — the task resumes 300ms later at the latest, and both
    /// exits below drop the handle that closed it — and a `weak` capture would mean an edit typed
    /// just before the editor went away silently going away with it, which is the defect this type
    /// exists to end rather than a variant of it worth keeping.
    func schedule(_ field: Field, after settling: Duration, write: @escaping () -> Void) {
        cancel(field)
        writes[field] = write
        timers[field] = Task { @MainActor in
            try? await Task.sleep(for: settling)
            guard !Task.isCancelled else { return }
            self.fire(field)
        }
    }

    /// Drops what `field` was going to write, without writing it. Every reschedule opens with this,
    /// and so does every commit that writes immediately.
    func cancel(_ field: Field) {
        timers.removeValue(forKey: field)?.cancel()
        writes.removeValue(forKey: field)
    }

    /// Makes every write still outstanding, and stops the timers that were going to make them later.
    func flush() {
        for field in Field.allCases {
            fire(field)
        }
    }

    /// Taken out of the slot before it is made, so a write that reaches back in here — through the
    /// model change it causes, and the `onChange` that follows — cannot find itself still pending.
    private func fire(_ field: Field) {
        timers.removeValue(forKey: field)?.cancel()
        writes.removeValue(forKey: field)?()
    }
}

private struct HeaderEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}
