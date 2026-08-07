import SwiftUI
import Domain
import DesignSystem

/// Geometry shared by every labelled row in the editor.
///
/// Xcode's inspectors right-align a row's label in a fixed column and start every value at the same
/// x, so a form reads as one vertical seam rather than as labels ending wherever their own text
/// happens to stop. `InspectorRowMetrics` says that for the 280pt inspector; the editor needs its own
/// numbers because it is as wide as the window and its labels are different ones.
///
/// The part that matters is that the seam is shared across *both* cards. "Status code" lives in one
/// and "Group tag" in another, but the eye reads them as a single form, and a seam that shifted
/// between two cards 16pt apart would look like a mistake rather than a grouping.
private enum EditorRowMetrics {
    /// Width of the right-aligned label column. Sized for "Global delay", the longest label, which
    /// measures 64.6pt at `DSTypography.label` (SF Pro 11pt regular). A longer label has to raise
    /// this rather than wrap — a two-line label loses its alignment with the control beside it.
    static let labelColumn: CGFloat = 68

    /// Width of a field holding a number: a status code, or a millisecond count. Both are at most
    /// four characters, and one width means the numeric rows share a right edge as well as a left.
    static let numericFieldWidth: CGFloat = 72

    /// Width of the group tag field. Bounded rather than flexible: stretched across a full-width
    /// editor, a field for the word "Users" reads as a text area.
    static let textFieldWidth: CGFloat = 240

    /// Width of the header name column. A response header's name is short and its value is not, so
    /// the two do not deserve equal halves of the row.
    static let headerKeyWidth: CGFloat = 200

    /// Where a value starts, measured from the card's leading edge. Prose that explains a row lines
    /// up here rather than at the card edge, so it reads as belonging to the row above it.
    static let valueInset: CGFloat = DSSpacing.md + labelColumn + DSSpacing.sm
}

/// The well every editable field in this pane wears.
///
/// One height, one radius, one hairline — the rule the request log states for its own control row,
/// applied here for the same reason: fields that differ by a couple of points read as unrelated
/// controls that happen to be near each other.
private enum EditorField {
    /// 3pt above and below a 12pt monospaced line.
    static let verticalPadding: CGFloat = 3
    /// 22pt — the line plus `verticalPadding` top and bottom. Also the minimum height of a row, so a
    /// row whose value is plain text keeps the rhythm of one holding a field.
    static let height: CGFloat = 22
    /// 4pt, from `DSCornerRadius.sm`.
    static let cornerRadius: CGFloat = DSCornerRadius.sm
    /// A hairline, not a border. At 1pt a column of these reads as a grid.
    static let borderWidth: CGFloat = 0.5
}

private extension View {
    /// Wraps a field in the editor's shared well. Only the width varies, because width is the only
    /// part of the geometry that carries meaning — a status code is not as wide as a group tag.
    ///
    /// `maxWidth` rather than `width` for a field that shares its row with another: a hard 200pt name
    /// column took half of a narrow editor and left the value it describes with less room than the
    /// name, where a ceiling caps the column when there is room and yields when there is not.
    ///
    /// `isInvalid` recolours the hairline and nothing else, which is the rule `DSTextField` follows:
    /// the well differs from its neighbours by *state*, not by weight. The colour is never the only
    /// channel — a field that turns its border red always has the message underneath it too.
    func editorFieldWell(
        width: CGFloat? = nil,
        maxWidth: CGFloat? = nil,
        isInvalid: Bool = false
    ) -> some View {
        padding(.horizontal, DSSpacing.sm)
            .padding(.vertical, EditorField.verticalPadding)
            .frame(width: width)
            .frame(maxWidth: maxWidth)
            .frame(height: EditorField.height)
            .background {
                RoundedRectangle(cornerRadius: EditorField.cornerRadius)
                    .fill(DSColors.tertiary)
            }
            .overlay {
                RoundedRectangle(cornerRadius: EditorField.cornerRadius)
                    .stroke(
                        isInvalid ? DSColors.destructive : DSColors.border,
                        lineWidth: EditorField.borderWidth
                    )
            }
    }
}

/// Center pane endpoint editor — method, path, response config, headers, body, and settings.
struct EndpointEditorView: View {
    let endpoint: Endpoint
    let activeScenario: Scenario?
    let globalDelayMs: Int
    /// Back/forward and the lateral moves the jump bar used to carry. Defaulted so previews and
    /// tests can build the editor without wiring navigation they do not exercise.
    var navigation: CenterPaneNavigation = CenterPaneNavigation()
    let actions: EndpointEditorActions

    @State private var statusCodeString = ""
    @State private var responseBody = ""
    @State private var delayString = ""
    @State private var groupTag = ""
    @State private var headers: [HeaderEntry] = []
    /// The message under the status code field, or `nil` when there is nothing to say.
    ///
    /// Written only when a value has *settled* — see `debounceStatusCode()`. A status code is typed
    /// one digit at a time and "6" and "60" are both prefixes of a perfectly good "600", so
    /// validating on every keystroke would flash a complaint at someone who is still typing.
    @State private var statusCodeError: String?
    @State private var delayError: String?
    @State private var isJSONValid = true
    @State private var showDeleteConfirmation = false
    @State private var isMoreMenuHovered = false
    @State private var statusCommitTask: Task<Void, Never>?
    @State private var bodyCommitTask: Task<Void, Never>?
    @State private var headerCommitTask: Task<Void, Never>?
    /// Focus for the two fields that commit on blur rather than on every keystroke. A delay of "5"
    /// is a valid prefix of "500", so debouncing these would write a value nobody asked for.
    @FocusState private var isGroupTagFocused: Bool
    @FocusState private var isDelayFocused: Bool

    init(
        endpoint: Endpoint,
        activeScenario: Scenario?,
        globalDelayMs: Int,
        navigation: CenterPaneNavigation = CenterPaneNavigation(),
        actions: EndpointEditorActions
    ) {
        self.init(
            endpoint: endpoint,
            activeScenario: activeScenario,
            globalDelayMs: globalDelayMs,
            navigation: navigation,
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
        navigation: CenterPaneNavigation = CenterPaneNavigation(),
        actions: EndpointEditorActions,
        initialStatusCodeString: String,
        initialResponseBody: String,
        initialDelayString: String,
        initialGroupTag: String,
        initialHeaders: [(String, String)]
    ) {
        self.endpoint = endpoint
        self.activeScenario = activeScenario
        self.globalDelayMs = globalDelayMs
        self.navigation = navigation
        self.actions = actions
        _statusCodeString = State(initialValue: initialStatusCodeString)
        _responseBody = State(initialValue: initialResponseBody)
        _delayString = State(initialValue: initialDelayString)
        _groupTag = State(initialValue: initialGroupTag)
        _headers = State(initialValue: initialHeaders.map { HeaderEntry(key: $0.0, value: $0.1) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // No `DSDivider` under this: the header draws its own hairline, and the two together laid
            // 1.5pt of rule under the row — three times the weight every other bar in the window ends
            // with, in a lighter colour than any of them.
            endpointHeader

            if activeScenario == nil {
                DSEmptyState(
                    systemImage: "exclamationmark.bubble",
                    heading: "No active scenario",
                    message: "Activate or add a scenario from the inspector to edit this endpoint's response.",
                    identifier: "editor.noActiveScenario"
                )
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        editorCard { responseSection }
                        editorCard { headersSection }
                        editorCard { bodySection }
                        editorCard { settingsSection }
                    }
                    .padding(DSSpacing.md)
                }
            }
        }
        // Clamped to the pane, so the stack cannot size itself to its widest child: the editor cards
        // carry fixed field widths that a narrow centre pane can be smaller than, and without this
        // the whole editor would grow past the pane's trailing edge instead of letting the cards
        // truncate inside it.
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColors.dominant)
        .onAppear { syncFromModel() }
        .onChange(of: endpoint.id) { syncFromModel() }
        .onChange(of: endpoint.activeScenarioID) { syncFromModel() }
        .onChange(of: statusCodeString) { debounceStatusCode() }
        .accessibilityIdentifier("endpointEditor")
        // The mandatory partner to the identifier above. On its own it renames every descendant, so
        // `endpointEditor.statusCode`, `.delay`, `.groupTag` and every header field would report
        // "endpointEditor" instead of their own names and stop being addressable.
        .accessibilityElement(children: .contain)
    }

    // MARK: - Header

    /// Method, path, and the endpoint's own actions — the identity of what is being edited.
    ///
    /// Now also the centre pane's navigation. The jump bar above this header was deleted so all four
    /// panel headers could start at the same y; its back/forward pair moved here, and its sideways
    /// moves into ``moreMenu``. The pair leads the row for the same reason Xcode's jump bar puts it
    /// first — history is about the pane, not about the thing in it.
    @ViewBuilder
    private var endpointHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            EditorHistoryControls(
                canGoBack: navigation.canGoBack,
                canGoForward: navigation.canGoForward,
                onBack: navigation.onBack,
                onForward: navigation.onForward
            )

            DSMethodBadge(method: endpoint.method.rawValue, identifier: "editor.method")

            // `.lineLimit(1)` and `.truncationMode(.middle)`, and no layout priority. A negative one
            // looks like the way to say "yield first", but the `Spacer` claims slack at default
            // priority, so the path lost every contest and a narrow editor showed a badge, a gap, and
            // no path at all. Plain compression truncates only once the row genuinely runs out of
            // room — which is the behaviour wanted, and the same fix `DSPanelHeader` took.
            Text(endpoint.path)
                .font(DSTypography.codeLarge)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(endpoint.path)
                .accessibilityIdentifier("endpointEditor.path")

            Spacer(minLength: DSSpacing.sm)

            moreMenu
        }
        .padding(.horizontal, DSSpacing.md)
        // Fixed, not padded. With vertical padding the row grew to whatever its tallest control was,
        // so giving the menu a real hit target would have silently made the header 34pt.
        .frame(height: DSBarHeight.panelHeader)
        .background(DSColors.secondary)
        .overlay(alignment: .bottom) {
            Rectangle()
                // `separator`, the weight every horizontal bar in this window ends with.
                // `panelSeparator` is heavier and reserved for the seam *between* panels.
                .fill(DSColors.separator)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
    }

    /// The endpoint's own actions, and the lateral moves the jump bar used to offer.
    ///
    /// `.borderlessButton`, deliberately. The label here is a bare ellipsis, so the default bordered
    /// style only adds a permanent rounded well around it — chrome Xcode does not draw on an inline
    /// "more" control either. (`DSFilterField.ScopeMenu` takes `.button` + `.plain` instead, because
    /// its label is a *word* and a pop-up draws its indicator ahead of the label.)
    ///
    /// The hover well is the affordance instead: an ellipsis that never responds to the pointer
    /// reads as decoration. It sits on the `Menu`, not inside the label — a `Menu` renders its own
    /// label, so a frame and a `.contentShape` in there fight the control it builds.
    @ViewBuilder
    private var moreMenu: some View {
        Menu {
            Button {
                actions.onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete endpoint\u{2026}", systemImage: "trash")
            }

            // The jump bar's sideways moves. Last, and behind a divider, because they navigate away
            // from this endpoint while everything above acts on it — and because a destructive item
            // should not be the thing your pointer passes over on the way to a routine jump.
            if !navigation.usableSections.isEmpty {
                Divider()
                CenterPaneJumpSections(navigation: navigation)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isMoreMenuHovered ? DSColors.labelPrimary : DSColors.labelSecondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background {
            RoundedRectangle(cornerRadius: DSCornerRadius.sm)
                .fill(isMoreMenuHovered ? DSColors.accentSubtle : Color.clear)
        }
        .onHover { isMoreMenuHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isMoreMenuHovered)
        .help("More actions for this endpoint")
        .accessibilityIdentifier("endpointEditor.moreMenu")
        .alert(
            "Delete endpoint?",
            isPresented: $showDeleteConfirmation
        ) {
            Button("Delete", role: .destructive) {
                actions.onDelete()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will remove the endpoint and all its scenarios. This can't be undone.")
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private var responseSection: some View {
        DSSectionHeader("Response", identifier: "editor.response")

        formRow("Status code") {
            TextField("200", text: $statusCodeString)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .editorFieldWell(
                    width: EditorRowMetrics.numericFieldWidth,
                    isInvalid: statusCodeError != nil
                )
                .accessibilityIdentifier("endpointEditor.statusCode")
                .accessibilityLabel("Status code")
                .onSubmit { commitStatusCode() }

            // After the field, not before it. In front, the dot pushed the value off the seam the
            // other rows hang from — and it was drawn only when the text already parsed, so the field
            // slid sideways as you typed the first digit. `httpStatusColor` answers "no class" with
            // grey, so the dot can simply always be there.
            Circle()
                .fill(DSColors.httpStatusColor(for: Int(statusCodeString) ?? 0))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
        }

        // A rejected status code used to be rejected in silence: the field went on showing 600 while
        // the endpoint went on serving the code it had before. The row below is the whole of the
        // feedback, so it has to appear whenever the commit does not.
        if let statusCodeError {
            validationNote(statusCodeError, identifier: "endpointEditor.statusCode.error")
        }
    }

    @ViewBuilder
    private var headersSection: some View {
        DSSectionHeader("Response headers", identifier: "editor.headers") {
            Button {
                headers.append(HeaderEntry(key: "", value: ""))
            } label: {
                Label("Add", systemImage: "plus")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.accentText)
                    // A real target and a hover well. `.plain` with no frame made the clickable
                    // area the glyph box of the words themselves — about 34×13pt, with nothing
                    // responding to the pointer. That is verbatim the shape `DSPanelHeaderButton`
                    // exists to fix; these two section-header actions are the call sites that never
                    // adopted it.
                    .padding(.horizontal, DSSpacing.xs)
                    .frame(height: EditorField.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
            .help("Add a response header")
            .accessibilityIdentifier("endpointEditor.addHeaderButton")
            .accessibilityLabel("Add header")
        }

        VStack(spacing: DSSpacing.xs) {
            // Bound by identity, labelled by position. `ForEach($headers)` hands each row a
            // `Binding<HeaderEntry>` derived from the entry's `id`, so a row can outlive a removal
            // somewhere above it; the previous form iterated `enumerated()` and passed
            // `$headers[index]`, which meant every surviving row held an index that the row calling
            // `remove(at:)` had just invalidated — the classic way to read one element past the end.
            ForEach($headers) { header in
                headerRow(header)
            }

            if headers.isEmpty {
                HStack(spacing: DSSpacing.xs) {
                    Image(systemName: "tray")
                        .font(.system(size: 11))
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityHidden(true)

                    // `labelSecondary`. 36% is an alpha for a glyph that decorates a sentence, not
                    // for the sentence.
                    Text("No custom headers")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.labelSecondary)
                }
                .padding(.horizontal, DSSpacing.sm)
                .frame(maxWidth: .infinity, minHeight: EditorField.height, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: EditorField.cornerRadius)
                        .fill(DSColors.tertiary.opacity(0.5))
                )
            }
        }
        .padding(.horizontal, DSSpacing.md)
        .onChange(of: headers) { debounceHeaders() }
    }

    /// One header row: name, value, and the control that takes the row away.
    ///
    /// The entry arrives as a binding rather than as an index, so nothing here can be stale. The
    /// number in the identifiers is looked up fresh on every body evaluation — `MimicUITests` reaches
    /// these fields as `endpointEditor.headerKey.0`, so the label has to keep meaning "the first row",
    /// which is a question about *position* and not about which entry this is.
    @ViewBuilder
    private func headerRow(_ header: Binding<HeaderEntry>) -> some View {
        let index = position(of: header.wrappedValue)

        HStack(spacing: DSSpacing.xs) {
            TextField("Name", text: header.key)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .editorFieldWell(maxWidth: EditorRowMetrics.headerKeyWidth)
                .accessibilityIdentifier("endpointEditor.headerKey.\(index)")
                .accessibilityLabel("Header name")
                .onSubmit { commitHeaders() }

            TextField("Value", text: header.value)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .editorFieldWell()
                .accessibilityIdentifier("endpointEditor.headerValue.\(index)")
                .accessibilityLabel("Header value")
                .onSubmit { commitHeaders() }

            Button {
                removeHeader(id: header.wrappedValue.id)
            } label: {
                // Not destructive-red. A column of red circles down the side of a form shouts
                // at you about rows you are not removing; the colour is for the things that
                // need attention, and "remove this header" says what it does in its tooltip.
                Image(systemName: "minus.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(DSColors.labelSecondary)
                    .frame(width: EditorField.height, height: EditorField.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this header")
            .accessibilityIdentifier("endpointEditor.removeHeader.\(index)")
            .accessibilityLabel("Remove header")
        }
    }

    /// Where an entry currently sits. `0` is unreachable rather than a default: a row is only ever
    /// built from an entry `headers` is holding at that moment.
    private func position(of entry: HeaderEntry) -> Int {
        headers.firstIndex { $0.id == entry.id } ?? 0
    }

    /// By `id`, never by index. The button that removes a row is inside that row, so an index taken
    /// when the row was built is exactly the one the removal invalidates.
    private func removeHeader(id: HeaderEntry.ID) {
        headers.removeAll { $0.id == id }
        commitHeaders()
    }

    @ViewBuilder
    private var bodySection: some View {
        DSSectionHeader("Response body", identifier: "editor.body") {
            Button {
                if let pretty = DSJSONEditor.prettyPrint(responseBody) {
                    responseBody = pretty
                    commitBody()
                }
            } label: {
                // Worded, not a lone `text.alignleft`. The glyph is the one control in this pane
                // nobody can name on sight, and a tooltip is only discoverable once you have already
                // pointed at the thing you were trying to find.
                Label("Format", systemImage: "text.alignleft")
                    .font(DSTypography.label)
                    // Explicit, because a `.plain` button keeps its foreground when disabled: with no
                    // body to format the control still sat there in full accent blue, reading as
                    // pressable.
                    .foregroundStyle(canFormatBody ? DSColors.accentText : DSColors.labelTertiary)
                    // Same target and well as the "Add" action above it — see the note there.
                    .padding(.horizontal, DSSpacing.xs)
                    .frame(height: EditorField.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
            .disabled(!canFormatBody)
            .help("Pretty-print the JSON body")
            .accessibilityIdentifier("endpointEditor.prettyPrintButton")
            .accessibilityLabel("Pretty-print JSON")
        }

        DSJSONEditor(text: $responseBody, identifier: "editor.body") { valid in
            isJSONValid = valid
        }
        // A `CodeEditor` has no opinion about its own height and a `ScrollView` proposes none, so
        // `minHeight` alone handed the decision to whatever the representable reported — either
        // nothing, or the whole payload. `idealHeight` is what a nil proposal resolves to, and the
        // bounds stop a one-line body collapsing the card or a 500-line one running off the window.
        .frame(minHeight: 180, idealHeight: 240, maxHeight: 420)
        .padding(.horizontal, DSSpacing.md)
        .onChange(of: responseBody) { debounceBody() }
    }

    @ViewBuilder
    private var settingsSection: some View {
        DSSectionHeader("Settings", identifier: "editor.settings")

        formRow("Group tag") {
            TextField("e.g. Users, Auth", text: $groupTag)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .editorFieldWell(width: EditorRowMetrics.textFieldWidth)
                .accessibilityIdentifier("endpointEditor.groupTag")
                // Committed when focus leaves, not only on Return. Typing a value and clicking
                // somewhere else is the ordinary way to fill a form; without this the edit was
                // dropped, and `syncFromModel` then quietly restored the old value the next time you
                // switched endpoints — a change that looked accepted and never was.
                .onChange(of: isGroupTagFocused) { _, focused in
                    if !focused { commitGroupTag() }
                }
                .accessibilityLabel("Group tag")
                .focused($isGroupTagFocused)
                .onSubmit { commitGroupTag() }
        }

        formRow("Delay") {
            TextField("0", text: $delayString)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .editorFieldWell(width: EditorRowMetrics.numericFieldWidth)
                .accessibilityIdentifier("endpointEditor.delay")
                .onChange(of: delayString) { delayError = nil }
                .onChange(of: isDelayFocused) { _, focused in
                    if !focused { commitDelay() }
                }
                .accessibilityLabel("Endpoint delay in milliseconds")
                .focused($isDelayFocused)
                .onSubmit { commitDelay() }

            unitLabel("ms")

            if let delayError {
                validationNote(delayError, identifier: "endpointEditor.delay.error")
            }
        }

        formRow("Global delay") {
            // Not a disabled text field. A greyed-out well in a row of live ones reads as a control
            // that failed rather than as a value belonging to something else, and there is nothing to
            // type into: this number is the project's, shown here because it is added to the delay
            // above before any response goes out. The padding puts its digits at the same x as the
            // digits in the field above rather than 6pt to their left.
            Text("\(globalDelayMs)")
                .font(DSTypography.code)
                .foregroundStyle(DSColors.labelSecondary)
                .padding(.horizontal, DSSpacing.sm)
                .frame(width: EditorRowMetrics.numericFieldWidth, alignment: .leading)
                .accessibilityIdentifier("endpointEditor.globalDelay")
                .accessibilityLabel("Global delay in milliseconds")

            unitLabel("ms")
        }

        // Non-breaking spaces inside the command: wrapped at 420pt the sentence broke it across two
        // lines as "configure --" / "delay", which is not a thing anyone can copy.
        note("Project-wide, and added on top of this endpoint's own delay. Nothing in this window sets it — mimic\u{00A0}server\u{00A0}configure\u{00A0}--delay does.")
    }

    // MARK: - Row furniture

    /// Label right-aligned in a fixed column, value flush left in what is left — the macOS inspector
    /// convention, and the one `InspectorOverview` already draws. Labels used to sit *above* their
    /// fields in one section and in a three-column grid in another, so the same pane answered "beside
    /// or above?" two different ways and no two fields started at the same x.
    @ViewBuilder
    private func formRow<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(spacing: DSSpacing.sm) {
            Text(label)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .frame(width: EditorRowMetrics.labelColumn, alignment: .trailing)

            content()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.md)
        // At least a control tall, so a row whose value is text keeps the rhythm of one holding a
        // field.
        .frame(minHeight: EditorField.height)
    }

    /// The unit a number is in, beside the value rather than inside the label. "Delay (ms)" spent
    /// 27pt of the label column on two characters that belong to the value, and made the two delay
    /// labels the widest things in a column sized for all four.
    @ViewBuilder
    private func unitLabel(_ unit: String) -> some View {
        Text(unit)
            .font(DSTypography.label)
            .foregroundStyle(DSColors.labelSecondary)
            // The field's own label already says "in milliseconds"; VoiceOver does not need it twice.
            .accessibilityHidden(true)
    }

    /// Why the row above it was not accepted, in `DSTextField`'s language: a filled
    /// `exclamationmark.circle.fill` beside `DSColors.destructive` text.
    ///
    /// The glyph is not decoration. Red 11pt text alone is one channel of meaning, and with
    /// Differentiate Without Color on, in a greyscale screenshot, or to a reader with a red
    /// deficiency, a complaint and a hint look identical. It sits at the value seam like `note()`,
    /// so it reads as belonging to the field it is about rather than to the section.
    @ViewBuilder
    private func validationNote(_ message: String, identifier: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: DSSpacing.xs) {
            Image(systemName: "exclamationmark.circle.fill")
                .font(.system(size: 10, weight: .semibold))

            // Wraps rather than truncates: a validation message that ends in an ellipsis is a
            // validation message that has stopped explaining itself.
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(DSTypography.label)
        .foregroundStyle(DSColors.destructive)
        .padding(.leading, EditorRowMetrics.valueInset)
        .padding(.trailing, DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // One reading, not a glyph and a sentence read separately.
        .accessibilityElement()
        .accessibilityLabel(message)
        .accessibilityIdentifier(identifier)
    }

    /// Prose explaining the row above it, starting at the value seam so it reads as part of that row
    /// rather than as a footnote to the section.
    @ViewBuilder
    private func note(_ message: String) -> some View {
        Text(message)
            .font(DSTypography.caption)
            // `labelSecondary`, not `labelTertiary`: 36% is the alpha for a timestamp you glance at,
            // and this is the sentence that explains why the number above it cannot be typed into.
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, EditorRowMetrics.valueInset)
            .padding(.trailing, DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Card wrapper

    /// A titled group box, in the shape Xcode's Signing & Capabilities editor uses: the section's
    /// banded header *is* the card's top edge.
    ///
    /// `DSSectionHeader` grew a tinted band and a hairline this session. With the card's old 6pt of
    /// top padding the band floated inside the card with a stripe of card above it and square corners
    /// poking at the rounded ones — which reads as a rendering seam, not as a header. Clipping to the
    /// card's shape lets the band reach the edges and take the corner radius with it.
    @ViewBuilder
    private func editorCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            content()
        }
        .padding(.bottom, DSSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DSColors.secondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .stroke(DSColors.border, lineWidth: 0.5)
        )
    }

    // MARK: - Derived state

    private var canFormatBody: Bool {
        isJSONValid && !responseBody.isEmpty
    }

    // MARK: - Sync & Commit

    /// Fills the fields from whatever the model currently holds.
    ///
    /// Every assignment here trips the `.onChange` handlers above, which cannot tell a character a
    /// person typed from one this method just wrote — so merely *selecting* an endpoint used to
    /// schedule a write of the data it had that moment finished reading. Harmless when nothing else
    /// happens, and a lost update when two endpoints are clicked inside the 300ms window: the write
    /// scheduled for the first endpoint lands on the second.
    ///
    /// The suppression is in the three `debounce…` methods, each of which now asks whether the field
    /// actually differs from the model before it schedules anything — see `statusCodeIsDirty`,
    /// `headersAreDirty` and `bodyIsDirty`. A flag raised around this method would not work: SwiftUI
    /// runs an `onChange` action on the *next* update, by which time a flag lowered on the way out of
    /// here has been lowered for some time. Comparing against the model needs no flag, has no window
    /// in which it is wrong, and is the guard `debounceStatusCode` was already carrying alone.
    private func syncFromModel() {
        guard let synced = Self.syncedValues(endpoint: endpoint, activeScenario: activeScenario) else { return }
        statusCodeString = synced.statusCodeString
        responseBody = synced.responseBody
        delayString = synced.delayString
        groupTag = synced.groupTag
        headers = synced.headers.map { HeaderEntry(key: $0.0, value: $0.1) }
        // A complaint about the endpoint you just navigated away from is not about anything on
        // screen any more.
        statusCodeError = nil
    }

    /// Writes the status code if it is one the server can serve, and says why not if it is not.
    ///
    /// Both callers reach here only once the value has settled — the debounce below, and Return,
    /// which is a person saying "I have finished typing" in as many words.
    func commitStatusCode() {
        statusCommitTask?.cancel()
        guard let code = Self.statusCodeValue(from: statusCodeString) else {
            statusCodeError = Self.statusCodeValidationMessage(for: statusCodeString)
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
    private func debounceStatusCode() {
        statusCommitTask?.cancel()

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

        statusCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            guard pendingStatusCode == statusCodeString else { return }
            commitStatusCode()
        }
    }

    func commitHeaders() {
        let dict = Self.headersDictionary(from: headers.map { ($0.key, $0.value) })
        actions.onUpdateScenario(nil, dict, nil)
    }

    private func debounceHeaders() {
        headerCommitTask?.cancel()
        guard Self.headersAreDirty(headers.map { ($0.key, $0.value) }, against: activeScenario) else { return }

        headerCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitHeaders()
        }
    }

    func commitBody() {
        actions.onUpdateScenario(nil, nil, Self.bodyValue(from: responseBody))
    }

    private func debounceBody() {
        bodyCommitTask?.cancel()
        guard Self.bodyIsDirty(responseBody, against: activeScenario) else { return }

        bodyCommitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            commitBody()
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
        guard let delay = Self.delayValue(from: delayString) else {
            delayError = "Delay must be a whole number of milliseconds, zero or more"
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

    static func bodyValue(from text: String) -> String? {
        text.isEmpty ? nil : text
    }

    static func delayValue(from text: String) -> Int? {
        guard let delay = Int(text), delay >= 0 else { return nil }
        return delay
    }

    static func groupTagValue(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }
}

// MARK: - Supporting Types

private struct HeaderEntry: Identifiable, Equatable {
    let id = UUID()
    var key: String
    var value: String
}
