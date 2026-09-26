import SwiftUI
import Domain
import DesignSystem

/// Shared columns for endpoint options and the editable header table.
private enum EditorRowMetrics {
    static let labelColumn: CGFloat = 80
    static let numericFieldWidth: CGFloat = 72
    static let textFieldWidth: CGFloat = 240
    static let headerKeyWidth: CGFloat = 200
    static let valueInset: CGFloat = DSSpacing.md + labelColumn + DSSpacing.sm
}

private enum EditorBody {
    /// Keep a usable text viewport when a short window requires the whole form to scroll.
    static let minHeight: CGFloat = 180
}

/// Center pane endpoint editor — method, path, response config, headers, body, and settings.
struct EndpointEditorView: View {
    let endpoint: Endpoint
    let activeScenario: Scenario?
    let globalDelayMs: Int
    var backends: [BackendConfiguration] = []
    let actions: EndpointEditorActions

    @State private var statusCodeString = ""
    @State private var responseBody = ""
    /// Identity of the body actually hydrated into the draft. Fresh selection IDs arrive before
    /// onChange synchronizes these State values, so passing those directly would mix documents in
    /// the native editor's undo history for one render.
    @State private var bodyDocumentID: String?
    @State private var delayString = ""
    @State private var groupTag = ""
    @State private var headers: [HeaderEntry] = []
    @State private var headersExpanded = false
    @State private var optionsExpanded = false
    @State private var responseHeight = DSBarHeight.controlRow
    @State private var headersHeight = DSBarHeight.controlRow
    @State private var optionsHeight = DSBarHeight.controlRow
    /// The message under the status code field, or `nil` when there is nothing to say.
    ///
    /// Written only when a value has *settled* — see `debounceStatusCode()`. A status code is typed
    /// one digit at a time and "6" and "60" are both prefixes of a perfectly good "600", so
    /// validating on every keystroke would flash a complaint at someone who is still typing.
    @State private var statusCodeError: String?
    @State private var delayError: String?
    /// The Format button only enables for the body whose bounded output was checked.
    @State private var formatCandidate: (source: String, output: String)?
    @State private var showDeleteConfirmation = false
    /// The edits that have been typed and not yet written — one object rather than three more
    /// `@State` values, for the reason in `EndpointEditorPendingEdits`' own note.
    @State private var pendingEdits: EndpointEditorPendingEdits
    /// Focus for the two fields that commit on blur rather than on every keystroke. A delay of "5"
    /// is a valid prefix of "500", so debouncing these would write a value nobody asked for.
    @FocusState private var isGroupTagFocused: Bool
    @FocusState private var isDelayFocused: Bool

    init(endpoint: Endpoint, activeScenario: Scenario?, globalDelayMs: Int, backends: [BackendConfiguration] = [], actions: EndpointEditorActions) {
        self.init(
            endpoint: endpoint,
            activeScenario: activeScenario,
            globalDelayMs: globalDelayMs,
            backends: backends,
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
                // Measure the controls, then give the body all remaining height. The outer scroll
                // view keeps every option reachable when a short window hits the body’s minimum.
                GeometryReader { geometry in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            responseSection
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { responseHeight = $0 }
                            headersSection
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { headersHeight = $0 }
                            bodySection(height: max(
                                EditorBody.minHeight,
                                geometry.size.height - responseHeight - headersHeight - optionsHeight
                                    - DSBarHeight.controlRow - DSSpacing.md
                            ))
                            settingsSection
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { optionsHeight = $0 }
                        }
                    }
                }
            }
        }
        // A narrow split pane must compress the fields rather than grow past its leading edge.
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .onAppear { syncFromModel() }
        .onChange(of: endpoint.id) { endpointSelectionChanged() }
        .onChange(of: endpoint.activeScenarioID) { scenarioSelectionChanged() }
        .onChange(of: endpoint) { previous, current in
            guard previous.id == current.id,
                  previous.activeScenarioID == current.activeScenarioID else { return }
            refreshUneditedFields(from: previous)
        }
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
        DSEditorHeader(identifier: "endpoint") {
            DSMethodBadge(method: endpoint.method.rawValue, identifier: "editor.method")

            // `.lineLimit(1)` and `.truncationMode(.middle)`, and no layout priority. A negative one
            // looks like the way to say "yield first", but the `Spacer` claims slack at default
            // priority, so the path lost every contest and a narrow editor showed a badge, a gap, and
            // no path at all. Plain compression truncates only once the row genuinely runs out of
            // room — which is the behaviour wanted, and the same fix `DSPanelHeader` took.
            Text(endpoint.path)
                .font(DSTypography.codeHeading)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(endpoint.path)
                .accessibilityIdentifier("endpointEditor.path")

        } action: {
            moreMenu
        }
    }

    /// The endpoint's own actions use the shared 26pt icon menu. The delete confirmation remains
    /// here because it belongs to this endpoint, not to the menu component.
    @ViewBuilder
    private var moreMenu: some View {
        DSIconMenu(
            systemImage: "ellipsis",
            help: "More actions for this endpoint",
            identifier: "endpointEditor.moreMenu"
        ) {
            Button("Rename\u{2026}", systemImage: "pencil", action: actions.onRename)
                .accessibilityIdentifier("endpointEditor.moreMenu.rename")
            Button("Edit request\u{2026}", action: actions.onEditRequest)
                .accessibilityIdentifier("endpointEditor.moreMenu.editRequest")
            Divider()
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

    private var responseSection: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            HStack(spacing: DSSpacing.sm) {
                Text("Status")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                TextField("200", text: $statusCodeString)
                    .textFieldStyle(.plain)
                    .font(DSTypography.code)
                    .dsFieldWell(
                        width: EditorRowMetrics.numericFieldWidth,
                        isInvalid: statusCodeError != nil
                    )
                    .accessibilityIdentifier("endpointEditor.statusCode")
                    .accessibilityLabel("Status code")
                    .onSubmit { commitStatusCode() }
                if let code = Self.statusCodeValue(from: statusCodeString) {
                    Text(code == 200 ? "OK" : HTTPURLResponse.localizedString(forStatusCode: code).localizedCapitalized)
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.httpStatusColor(for: code))
                        .lineLimit(1)
                        .accessibilityIdentifier("endpointEditor.statusDescription")
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(height: DSBarHeight.controlRow)

            if let statusCodeError {
                validationNote(statusCodeError, identifier: "endpointEditor.statusCode.error", leadingInset: DSSpacing.md)
                    .padding(.bottom, DSSpacing.sm)
            }
        }
        .overlay(alignment: .bottom) { sectionDivider }
    }

    private var headersSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSSpacing.sm) {
                sectionDisclosure("Headers", isExpanded: headersExpanded, identifier: "endpointEditor.toggleHeaders") {
                    headersExpanded.toggle()
                }
                Text(headers.isEmpty ? "No custom headers" : "\(headers.count)")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .accessibilityIdentifier(headers.isEmpty ? "endpointEditor.headers.empty" : "endpointEditor.headers.count")
                Spacer(minLength: DSSpacing.sm)
                Button {
                    headersExpanded = true
                    headers.append(HeaderEntry(key: "", value: ""))
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.accentText)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(height: DSControlHeight.field)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dsPlain)
                .help("Add a response header")
                .accessibilityIdentifier("endpointEditor.addHeaderButton")
                .accessibilityLabel("Add header")
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(height: DSBarHeight.controlRow)

            if headersExpanded && !headers.isEmpty {
                VStack(spacing: DSSpacing.sm) {
                    // Bind by identity so removing an earlier row never leaves a stale index.
                    ForEach($headers) { header in
                        headerRow(header)
                    }
                }
                .padding(.horizontal, DSSpacing.md)
                .padding(.bottom, DSSpacing.sm)
            }
        }
        .overlay(alignment: .bottom) { sectionDivider }
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
                .dsFieldWell(maxWidth: EditorRowMetrics.headerKeyWidth)
                .accessibilityIdentifier("endpointEditor.headerKey.\(index)")
                .accessibilityLabel("Header name")
                .onSubmit { commitHeaders() }

            TextField("Value", text: header.value)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .dsFieldWell()
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
                    .frame(width: DSControlHeight.field, height: DSControlHeight.field)
                    .contentShape(Rectangle())
            }
            // The same well the two section-header actions above it wear, and now the same pressed
            // state. This button sat between them with neither: the one control in the row that
            // destroys something was also the only one that never acknowledged being pointed at.
            .buttonStyle(.dsPlain)
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

    private func bodySection(height: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Response body")
                    .font(DSTypography.controlLabel)
                    .foregroundStyle(DSColors.labelPrimary)
                Spacer(minLength: DSSpacing.sm)
                Button {
                    if let formatCandidate, formatCandidate.source == responseBody {
                        responseBody = formatCandidate.output
                        commitBody()
                    }
                } label: {
                    Label("Format", systemImage: "text.alignleft")
                        .font(DSTypography.label)
                        .foregroundStyle(canFormatBody ? DSColors.accentText : DSColors.labelTertiary)
                        .padding(.horizontal, DSSpacing.xs)
                        .frame(height: DSControlHeight.field)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.dsPlain)
                .disabled(!canFormatBody)
                .help("Pretty-print the JSON body")
                .accessibilityIdentifier("endpointEditor.prettyPrintButton")
                .accessibilityLabel("Pretty-print JSON")
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(height: DSBarHeight.controlRow)

            // Fill the available workspace regardless of payload length. Formatting a long payload
            // changes the document, never the height of the editor or the position of its options.
            DSJSONEditor(text: $responseBody, identifier: "editor.body", documentID: bodyDocumentID)
            .frame(height: height)
            .padding(.horizontal, DSSpacing.md)
            .padding(.bottom, DSSpacing.md)
            .onChange(of: responseBody) { debounceBody() }
            .task(id: responseBody) {
                let source = responseBody
                // Typing cancels this task before it starts a new parse and bounded reflow.
                do { try await Task.sleep(for: Self.settling) } catch { return }
                let output = await Task.detached(priority: .userInitiated) {
                    DSJSONEditor.prettyPrint(source)
                }.value
                guard !Task.isCancelled, responseBody == source else { return }
                formatCandidate = output.map { (source: source, output: $0) }
            }
        }
    }

    private var settingsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: DSSpacing.sm) {
                sectionDisclosure("Endpoint options", isExpanded: optionsExpanded, identifier: "endpointEditor.toggleOptions") {
                    // Commit before removing a focused field from the view hierarchy.
                    if optionsExpanded {
                        if isGroupTagFocused { commitGroupTag() }
                        if isDelayFocused { commitDelay() }
                        isGroupTagFocused = false
                        isDelayFocused = false
                    }
                    optionsExpanded.toggle()
                }
                Spacer(minLength: DSSpacing.sm)
            }
            .padding(.horizontal, DSSpacing.md)
            .frame(height: DSBarHeight.controlRow)
            if optionsExpanded {
                VStack(alignment: .leading, spacing: DSSpacing.sm) {
                    endpointOptions
                }
                .padding(.bottom, DSSpacing.md)
            }
        }
        .overlay(alignment: .top) { sectionDivider }
    }

    @ViewBuilder
    private var endpointOptions: some View {
        formRow("Backend") {
            Picker("Backend", selection: Binding<UUID?>(
                get: { endpoint.backendID },
                set: { actions.onUpdateBackend($0) }
            )) {
                Text(backends.first { $0.id == ServerConfiguration.primaryID }?.name ?? "Primary").tag(nil as UUID?)
                ForEach(backends.filter { $0.id != ServerConfiguration.primaryID }) { backend in
                    Text(backend.name).tag(backend.id as UUID?)
                }
            }
            .labelsHidden()
            .accessibilityIdentifier("endpointEditor.backend")
            .accessibilityLabel("Backend")
        }

        formRow("Group tag") {
            TextField("e.g. Users, Auth", text: $groupTag)
                .textFieldStyle(.plain)
                .font(DSTypography.code)
                .dsFieldWell(maxWidth: EditorRowMetrics.textFieldWidth)
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
                .dsFieldWell(width: EditorRowMetrics.numericFieldWidth)
                .accessibilityIdentifier("endpointEditor.delay")
                .onChange(of: delayString) { delayError = nil }
                .onChange(of: isDelayFocused) { _, focused in
                    if !focused { commitDelay() }
                }
                .accessibilityLabel("Endpoint delay in milliseconds")
                .focused($isDelayFocused)
                .onSubmit { commitDelay() }

            unitLabel("ms")
        }
        if let delayError {
            validationNote(delayError, identifier: "endpointEditor.delay.error")
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

        note(
            "Project delay is added to this endpoint’s delay.",
            identifier: "endpointEditor.globalDelay.note"
        )
    }

    private var sectionDivider: some View {
        Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
    }

    private func sectionDisclosure(
        _ title: String,
        isExpanded: Bool,
        identifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: DSGlyph.indicator, weight: .semibold))
                    .frame(width: DSGlyph.control)
                    .accessibilityHidden(true)
                Text(title).font(DSTypography.metaBold)
            }
            .foregroundStyle(DSColors.labelSecondary)
            .frame(height: DSControlHeight.field)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
        .help(isExpanded ? "Collapse \(title.lowercased())" : "Expand \(title.lowercased())")
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
                .lineLimit(1)
                .frame(width: EditorRowMetrics.labelColumn, alignment: .trailing)

            content()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, DSSpacing.md)
        // At least a control tall, so a row whose value is text keeps the rhythm of one holding a
        // field.
        .frame(minHeight: DSControlHeight.field)
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
    /// The glyph is not decoration. Red 13pt text alone is one channel of meaning, and with
    /// Differentiate Without Color on, in a greyscale screenshot, or to a reader with a red
    /// deficiency, a complaint and a hint look identical. It sits at the value seam like `note()`,
    /// so it reads as belonging to the field it is about rather than to the section.
    @ViewBuilder
    private func validationNote(_ message: String, identifier: String, leadingInset: CGFloat = EditorRowMetrics.valueInset) -> some View {
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
        .padding(.leading, leadingInset)
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
        bodyDocumentID = activeScenario.map { "\(endpoint.id.uuidString):\($0.id.uuidString)" }
        delayString = synced.delayString
        groupTag = synced.groupTag
        headers = synced.headers.map { HeaderEntry(key: $0.0, value: $0.1) }
        headersExpanded = !headers.isEmpty
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
        guard let previousScenario = previous.scenarios.first(where: { $0.id == previous.activeScenarioID }),
              let activeScenario else { return }

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
