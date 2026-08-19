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

    /// How wide a card is allowed to get.
    ///
    /// The widest row this has to hold is a response header: a 200pt name column, a gap, and a value
    /// field that should still be worth typing into — plus the card's own 12pt insets on both sides.
    /// 640 seats that with room to spare and keeps the form readable along one edge instead of
    /// stretching a 68pt label away from its control.
    ///
    /// A cap, not a width: a centre pane narrower than this still gets a card that fits it.
    static let cardMaxWidth: CGFloat = 640
}

/// The well every editable field in this pane wears.
///
/// One height, one radius, one hairline — the rule the request log states for its own control row,
/// applied here for the same reason: fields that differ by a couple of points read as unrelated
/// controls that happen to be near each other.
///
/// Read from the design system rather than restated, so this row and the request log's cannot drift
/// apart by a point the way four independently written literals eventually do. `field` is the rung a
/// control a user types into stands on; it is also the minimum height of a row, so a row whose value
/// is plain text keeps the rhythm of one holding a field.
/// How tall the response-body well stands.
///
/// Bounded rather than free: below the floor a one-line body collapses the card and leaves nowhere
/// to type, and above the ceiling a 500-line payload runs off the window instead of scrolling inside
/// the well that owns it.
private enum EditorBody {
    /// Roughly seven lines. Sized to be a comfortable place to start typing, and to absorb a
    /// minified payload — one logical line that wraps to several, which `lineCount` cannot see.
    static let minHeight: CGFloat = 100

    /// Unchanged. Past this the payload scrolls within its own well rather than pushing the cards
    /// below it off the pane.
    static let maxHeight: CGFloat = 420

    /// The well's natural height for this text, before the bounds are applied.
    ///
    /// `DSJSONEditor` owns the arithmetic because it owns the font. The editor's frame also has to
    /// cover the validation row it draws underneath itself when the JSON does not parse, which is
    /// why this adds a line's worth rather than measuring the editor alone.
    static func height(for text: String) -> CGFloat {
        DSJSONEditor.height(forLines: DSJSONEditor.lineCount(of: text) + 1)
    }
}

private enum EditorField {
    static let verticalPadding = DSControlHeight.verticalPadding
    static let height = DSControlHeight.field
    static let cornerRadius = DSCornerRadius.sm
    static let borderWidth = DSStroke.hairline
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
    /// The edits that have been typed and not yet written — one object rather than three more
    /// `@State` values, for the reason in `EndpointEditorPendingEdits`' own note.
    @State private var pendingEdits: EndpointEditorPendingEdits
    /// Focus for the two fields that commit on blur rather than on every keystroke. A delay of "5"
    /// is a valid prefix of "500", so debouncing these would write a value nobody asked for.
    @FocusState private var isGroupTagFocused: Bool
    @FocusState private var isDelayFocused: Bool

    init(endpoint: Endpoint, activeScenario: Scenario?, globalDelayMs: Int, actions: EndpointEditorActions) {
        self.init(
            endpoint: endpoint,
            activeScenario: activeScenario,
            globalDelayMs: globalDelayMs,
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
        .onChange(of: endpoint.id) { endpointSelectionChanged() }
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
    /// The group tag used to be repeated above the path as a dead caption. It is a crumb in the jump
    /// bar now, where it is also a menu you can steer with.
    @ViewBuilder
    private var endpointHeader: some View {
        HStack(spacing: DSSpacing.sm) {
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
                .frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
    }

    /// The endpoint's own actions.
    ///
    /// `DSIconMenu`, which is where the block this used to spell out now lives — the same block the
    /// journeys navigator's "+" spelled out too, whose own note named this one as its twin. The hover
    /// well is the point of the shape: an ellipsis that never responds to the pointer reads as
    /// decoration, and the well has to sit on the `Menu` rather than inside its label, because a
    /// `Menu` renders its own label and a frame in there fights the control it builds.
    ///
    /// What this note used to argue was that `.menuStyle(.borderlessButton)` was right here and
    /// `.button` right for `BreadcrumbJumpBar` — which split the app's four hand-styled menus two
    /// and two. The component takes `.borderlessButton` for both, and the reason it still does has
    /// changed: it used to be that the menu style decides the AppKit element type and
    /// `JourneyUITests` separated two identically-labelled "Add journey" controls by element type
    /// alone. That is fixed — the journeys navigator's menu and the journeys empty state's button
    /// carry different labels now, and the suite separates them by name. What is left is the hit
    /// target, which is the question `DSIconMenu`'s own note ends on and which this menu shares:
    /// its 22pt frame and hover well sit outside the `Menu`, not inside a `Button`'s label.
    /// `.buttonStyle(.plain)` *is* shared with the breadcrumb and `DSFilterField.ScopeMenu`; see
    /// that note for why `.plain` and not the `.borderless` Apple's deprecation message suggests.
    ///
    /// The alert stays here. It is this endpoint's confirmation, not a property of icon menus.
    @ViewBuilder
    private var moreMenu: some View {
        DSIconMenu(
            systemImage: "ellipsis",
            help: "More actions for this endpoint",
            identifier: "endpointEditor.moreMenu"
        ) {
            Button {
                actions.onDuplicate()
            } label: {
                Label("Duplicate", systemImage: "doc.on.doc")
            }
            .accessibilityIdentifier("endpointEditor.moreMenu.duplicate")
            Divider()
            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Label("Delete endpoint\u{2026}", systemImage: "trash")
            }
            .accessibilityIdentifier("endpointEditor.moreMenu.delete")
        }
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
                        // The rung that matches the line of type beside it: `DSGlyph.control` is 11,
                        // which is `DSTypography.label`'s size, so the glyph sits level with the
                        // sentence rather than a point proud of it.
                        .font(.system(size: DSGlyph.control))
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityHidden(true)

                    // `labelSecondary`. 36% is an alpha for a glyph that decorates a sentence, not
                    // for the sentence.
                    Text("No custom headers")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.labelSecondary)
                        // On the `Text`, not on the `HStack` around it. The glyph beside it is
                        // `.accessibilityHidden`, so there is exactly one element here worth
                        // naming, and naming the wrapper instead risks the identifier landing on a
                        // group that a `staticTexts` query never reaches.
                        .accessibilityIdentifier("endpointEditor.headers.empty")
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
                    .font(.system(size: DSGlyph.controlLarge))
                    .foregroundStyle(DSColors.labelSecondary)
                    .frame(width: EditorField.height, height: EditorField.height)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // The same hover well the two section-header actions above it wear. This button sat
            // between them with none: a `.plain` button gives no pressed state and no pointer
            // response, so the one control in the row that destroys something was also the only one
            // that never acknowledged being pointed at.
            .dsHoverHighlight(cornerRadius: DSCornerRadius.sm)
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
        // nothing, or the whole payload. The fix used to be a fixed `idealHeight` of 240, and the
        // cost of that was the largest object in the window being mostly empty: a five-line body
        // measures about 72pt and was given 240 regardless, on the one surface in this app that
        // holds real content.
        //
        // `DSJSONEditor.height(forLines:)` measures the face the editor actually draws with. The
        // floor is what absorbs a *minified* payload, which is one logical line that wraps to many
        // and so under-reports — see that method's note.
        .frame(
            minHeight: EditorBody.minHeight,
            idealHeight: EditorBody.height(for: responseBody),
            maxHeight: EditorBody.maxHeight
        )
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
                // The number, said as the row's value. An explicit `.accessibilityLabel` *replaces*
                // what a `Text` would otherwise expose, so naming this row took its digits out of
                // the accessibility tree entirely: VoiceOver announced "Global delay in
                // milliseconds" with nothing under it, and a test could read the label back but
                // never the value it labels. Found by the UI sweep, which could assert the row
                // exists and not what it says.
                .accessibilityValue("\(globalDelayMs)")

            unitLabel("ms")
        }

        // Non-breaking spaces inside the command: wrapped at 420pt the sentence broke it across two
        // lines as "configure --" / "delay", which is not a thing anyone can copy.
        note(
            "Project-wide, and added on top of this endpoint's own delay. Nothing in this window sets it — mimic\u{00A0}server\u{00A0}configure\u{00A0}--delay does.",
            identifier: "endpointEditor.globalDelay.note"
        )
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
                // `inline`, the rung `DSTextField` and `DSJSONEditor` draw their validation marks at
                // — this row is the third of the three and was the one still writing the number.
                .font(.system(size: DSGlyph.inline, weight: .semibold))

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
    ///
    /// The identifier is a parameter, the way ``validationNote(_:identifier:)`` above takes one: this
    /// sentence is the only thing telling you the number above it is the project's rather than this
    /// endpoint's, so a test asserts the note is there without pinning the prose word for word.
    @ViewBuilder
    private func note(_ message: String, identifier: String) -> some View {
        Text(message)
            .font(DSTypography.caption)
            // `labelSecondary`, not `labelTertiary`: 36% is the alpha for a timestamp you glance at,
            // and this is the sentence that explains why the number above it cannot be typed into.
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, EditorRowMetrics.valueInset)
            .padding(.trailing, DSSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityIdentifier(identifier)
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
        // Capped, not `.infinity`. `formRow` is a 68pt label column, a fixed field and a
        // `Spacer(minLength: 0)` — so whatever width the card is given, the spacer swallows it, and
        // a 68pt label with a 72pt field beside it was spanning the better part of 900pt. A form is
        // read along its leading edge; the rest of that width was carrying nothing.
        //
        // Leading-aligned rather than centred: the cards hang off the same edge as the section
        // headers above them and the identity row above those.
        .frame(maxWidth: EditorRowMetrics.cardMaxWidth, alignment: .leading)
        .background(DSColors.secondary.opacity(0.35))
        .clipShape(RoundedRectangle(cornerRadius: DSCornerRadius.lg))
        .overlay(
            RoundedRectangle(cornerRadius: DSCornerRadius.lg)
                .stroke(DSColors.border, lineWidth: DSStroke.hairline)
        )
        // After the fill and the stroke, never before. This frame is what pins the capped card to
        // the pane's leading edge; applied first, the background would paint *it* rather than the
        // card, and the cap above would draw nothing.
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Derived state

    private var canFormatBody: Bool {
        isJSONValid && !responseBody.isEmpty
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
    /// Second, because `syncFromModel`'s other two callers must not flush. `onAppear` has nothing to
    /// finish, and a change of *active scenario* has nowhere correct to put it:
    /// `EndpointEditorActions.onUpdateScenario` addresses the active scenario of an endpoint rather
    /// than a scenario by name, so once a different scenario is active the pending text would land on
    /// one nobody typed it into. Dropping it there is the lesser of two bad answers and is what
    /// already happens; see the seam note on `commit(body:)`.
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

    /// The one write that is still addressed loosely, and the seam worth knowing about.
    ///
    /// `onUpdateScenario` names an endpoint and lets `AppState` resolve "whichever scenario is
    /// active", which is why a pending edit survives a change of *selection* — neither endpoint's
    /// active scenario moves — and cannot survive a change of *active scenario*. Making it survive
    /// that too means the actions carrying a scenario id, which is a change to `CenterPaneView`'s
    /// closures and to `AppState.updateActiveScenario`.
    private func commit(body text: String) {
        actions.onUpdateScenario(nil, nil, Self.bodyValue(from: text))
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
