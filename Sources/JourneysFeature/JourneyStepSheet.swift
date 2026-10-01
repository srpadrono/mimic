import AppKit
import DesignSystem
import Domain
import SwiftUI
import FeatureSupport

/// Adds or edits one journey step.
///
/// A step either answers or fails at the transport level, so the form asks that first and then shows
/// only the fields that apply. Status, delay and repeat share one row; the body and the headers share
/// the space below it through a Body/Headers switch, as the endpoint editor's do.
public struct JourneyStepSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `nil` when adding.
    let step: JourneyStep?
    /// The step's position, for the title: "Edit step 3".
    var stepNumber: Int? = nil
    var backends: [BackendConfiguration] = []
    var globalDelayMs: Int = 0
    /// The project's endpoints, to say whether the request also matches one.
    var endpoints: [Endpoint] = []
    let onCommit: (JourneyStepSpec) -> Void
    /// Offered only when editing an existing step.
    var onRemove: (() -> Void)? = nil
    /// The visible screen height the sheet fits itself under. `nil` reads the main screen; a test
    /// pins it to reach the short-screen layout, where the form scrolls.
    var visibleScreenHeight: CGFloat? = nil

    private enum Kind: String, CaseIterable, Identifiable {
        case respond
        case drop
        case timeout

        var id: String { rawValue }

        var title: String {
            switch self {
            case .respond: "Respond"
            case .drop: "Drop connection"
            case .timeout: "Time out"
            }
        }
    }

    /// What the response well below the status row shows.
    private enum Pane: Hashable {
        case body
        case headers
    }

    /// The form's inputs, named so focus and validation can both point at one. A complaint is shown
    /// under the input that caused it.
    private enum Field: Hashable {
        case name
        case path
        case statusCode
        case headers
        case body
        case hold
        case delay
        case repeatCount
    }

    private struct Validation: Equatable {
        let field: Field
        let message: String
    }

    @State private var kind: Kind = .respond
    @State private var name = ""
    @State private var method: HTTPMethod = .get
    @State private var selectedBackend = "primary"
    @State private var path = ""
    @State private var statusCode = "200"
    @State private var responseBody = ""
    @State private var headerText = ""
    @State private var delayMs = "0"
    @State private var repeatCount = "1"
    @State private var holdMs = String(NetworkFailure.defaultTimeoutHoldMs)
    @State private var pane: Pane = .body
    @State private var validation: Validation?
    @State private var scrollPresentationID = UUID()
    @FocusState private var focusedField: Field?
    /// The request field is shared with the endpoint sheets, which focus it with a plain flag.
    @FocusState private var pathIsFocused: Bool

    public init(
        step: JourneyStep? = nil,
        stepNumber: Int? = nil,
        backends: [BackendConfiguration] = [],
        globalDelayMs: Int = 0,
        endpoints: [Endpoint] = [],
        onCommit: @escaping (JourneyStepSpec) -> Void,
        onRemove: (() -> Void)? = nil
    ) {
        self.step = step
        self.stepNumber = stepNumber
        self.backends = backends
        self.globalDelayMs = globalDelayMs
        self.endpoints = endpoints
        self.onCommit = onCommit
        self.onRemove = onRemove
    }

    public var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpacing.xs) {
                Text(title)
                    .font(DSTypography.headline)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityIdentifier("stepSheet.title")
                Text("Match a request, then choose what the client gets.")
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, DSSpacing.xl)
            .padding(.top, DSSpacing.xl)

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: Self.rowSpacing) {
                        matchFields
                        DSDivider(identifier: "stepSheet.outcome")
                        outcomeFields
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, DSSpacing.xl)
                    .padding(.vertical, 18)
                }
                .task(id: validation) {
                    guard let validation else { return }
                    // Let a newly shown pane lay out before bringing its field into view.
                    do { try await Task.sleep(for: .milliseconds(100)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    withAnimation(reduceMotion ? nil : .default) {
                        scroll.scrollTo(validation.field, anchor: .center)
                    }
                    if validation.field == .path {
                        pathIsFocused = true
                    } else {
                        focusedField = validation.field
                    }
                }
            }
            .id(scrollPresentationID)

            DSDivider(identifier: "stepSheet.footer")
            footer
        }
        .frame(width: DSSheetWidth.form,
               height: min(DSFormMetrics.journeyStepHeight,
                           (visibleScreenHeight ?? NSScreen.main?.visibleFrame.height
                               ?? DSFormMetrics.maximumTallSheetHeight)
                               - DSFormMetrics.screenVerticalAllowance))
        .background(DSColors.sheet)
        .dsFormLabelWidth(Self.labelWidth)
        .defaultFocus($pathIsFocused, true)
        .onAppear {
            loadExistingStep()
            // AppKit may reuse the scroll view between Add and Edit sheets; recreate it so its old
            // offset is not restored.
            scrollPresentationID = UUID()
        }
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: DSSpacing.sm) {
            if step != nil, let onRemove {
                DSButton("Remove step", variant: .destructive, size: .large, identifier: "stepSheet.removeButton") {
                    onRemove()
                    dismiss()
                }
                .help("Remove this step from the journey")
                .accessibilityIdentifier("stepSheet.removeButton")
            }
            Spacer(minLength: DSSpacing.sm)
            DSButton("Cancel", variant: .secondary, size: .large,
                     identifier: "stepSheet.cancel", action: dismiss.callAsFunction)
                .accessibilityIdentifier("stepSheet.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)
            DSButton(step == nil ? "Add step" : "Save step", variant: .primary, size: .large,
                     identifier: "stepSheet.save", action: commit)
                .accessibilityIdentifier("stepSheet.saveButton")
                .accessibilityLabel(step == nil ? "Add step" : "Save step")
                .disabled(trimmedPath.isEmpty)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, DSSpacing.xl)
        .padding(.vertical, Self.rowSpacing)
    }

    // MARK: - Match

    private var matchFields: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            sectionTitle("Match")
            DSFormRow("Request", alignment: .top) {
                SheetRequestField(
                    method: $method,
                    path: $path,
                    validation: validation?.field == .path ? validation?.message : nil,
                    pickerIdentifier: "stepSheet.methodPicker",
                    fieldIdentifier: "stepSheet.pathField",
                    validationIdentifier: "stepSheet.validationMessage",
                    isFocused: $pathIsFocused,
                    onSubmit: commit,
                    matchNote: JourneyStepSheet.matchingEndpoint(method: method, path: trimmedPath, in: endpoints) == nil
                        ? nil : "Matches an endpoint"
                )
                .onChange(of: path) { clearValidation(for: .path) }
            }
            .id(Field.path)

            DSTextField("Name", text: $name, placeholder: "Optional, for example \u{201C}Charge clears\u{201D}",
                        inputIdentifier: "stepSheet.nameField", identifier: "stepSheet.name")
                .focused($focusedField, equals: .name)

            if backends.count > 1 {
                DSFormRow("Server") {
                    Picker("Server", selection: $selectedBackend) {
                        Text(backends.first { $0.id == ServerConfiguration.primaryID }?.name ?? "Primary").tag("primary")
                        ForEach(backends.filter { $0.id != ServerConfiguration.primaryID }) { backend in
                            Text(backend.name).tag(backend.id.uuidString)
                        }
                    }
                    .pickerStyle(.menu)
                    .labelsHidden()
                    .fixedSize()
                    .accessibilityIdentifier("stepSheet.backendPicker")
                    .accessibilityLabel("Server")
                }
            }
        }
    }

    // MARK: - Outcome

    private var outcomeFields: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            sectionTitle("Outcome")
            // Neutral, like every segmented control in the app: the selection is a choice of form,
            // not an accent-coloured state.
            DSSegmentedControl(
                "Outcome",
                segments: Kind.allCases.map {
                    DSSegmentedControl<Kind>.Segment($0.title, value: $0, identifier: "stepSheet.outcome.\($0.rawValue)")
                },
                selection: $kind,
                fillsWidth: true,
                identifier: "stepSheet.outcomePicker"
            )
            .onChange(of: kind) { validation = nil }

            switch kind {
            case .respond:
                DSFormRow("Status", alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: DSSpacing.xl) {
                            statusField
                            inlineTimingFields
                        }
                        validationMessage(under: [.statusCode, .delay, .repeatCount])
                    }
                }
                bodyFields
            case .drop:
                DSFormRow("Delay", alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        timingFields(showsDelayLabel: false)
                        validationMessage(under: [.delay, .repeatCount])
                    }
                }
                DSFormHint("The connection closes without a response. The client sees a network failure.")
                    .accessibilityIdentifier("stepSheet.dropHint")
            case .timeout:
                DSFormRow("Hold for", alignment: .top) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: DSSpacing.xl) {
                            numberField("Hold for (ms)", text: $holdMs, field: .hold, unit: "ms",
                                        width: 112, identifier: "stepSheet.holdField")
                            inlineTimingFields
                        }
                        validationMessage(under: [.hold, .delay, .repeatCount])
                    }
                }
                DSFormHint("Nothing is sent while the client waits for its own timeout. "
                           + "Repeat keeps the step current for several requests.")
                    .accessibilityIdentifier("stepSheet.timeoutHint")
            }
        }
    }

    /// Code, reason phrase and a status dot, in one 28pt field, with a menu of common codes at its
    /// trailing edge. The code stays typeable, as the endpoint editor's is.
    private var statusField: some View {
        let code = Int(statusCode)
        return HStack(spacing: 6) {
            Circle()
                .fill(code.map { DSColors.httpStatusColor(for: $0) } ?? DSColors.labelTertiary)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            TextField("200", text: $statusCode)
                .textFieldStyle(.plain)
                .font(DSTypography.status)
                .foregroundStyle(code.map { DSColors.httpStatusColor(for: $0) } ?? DSColors.labelPrimary)
                .frame(width: 32)
                .focused($focusedField, equals: .statusCode)
                .accessibilityIdentifier("stepSheet.statusField")
                .accessibilityLabel("Status code")
                .onChange(of: statusCode) { clearValidation(for: .statusCode) }
            Text(Self.reasonPhrase(for: code))
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHidden(true)
            Menu {
                ForEach(Self.commonStatusCodes, id: \.self) { option in
                    Button("\(option) \(Self.reasonPhrase(for: option))") {
                        statusCode = String(option)
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: DSGlyph.minimum, weight: .semibold))
                    .foregroundStyle(DSColors.labelTertiary)
                    .frame(width: 12, height: DSControlHeight.large)
                    .contentShape(Rectangle())
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Choose a common status code")
            .accessibilityIdentifier("stepSheet.statusMenu")
            .accessibilityLabel("Common status codes")
        }
        .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment,
                       isFocused: focusedField == .statusCode,
                       isInvalid: validation?.field == .statusCode, horizontalPadding: 10)
        .frame(width: 160)
        .id(Field.statusCode)
    }

    private var inlineTimingFields: some View {
        timingFields(showsDelayLabel: true)
    }

    private func timingFields(showsDelayLabel: Bool) -> some View {
        HStack(spacing: DSSpacing.xl) {
            HStack(spacing: DSSpacing.sm) {
                if showsDelayLabel { inlineLabel("Delay") }
                numberField("Delay (ms)", text: $delayMs, field: .delay, unit: "ms",
                            width: 80, identifier: "stepSheet.delayField")
            }
            HStack(spacing: DSSpacing.sm) {
                inlineLabel("Repeat")
                numberField("Serve count", text: $repeatCount, field: .repeatCount, unit: "\u{00D7}",
                            width: 64, identifier: "stepSheet.repeatField")
            }
        }
        .fixedSize()
    }

    private func inlineLabel(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .fixedSize()
            .accessibilityHidden(true)
    }

    private func numberField(_ label: String, text: Binding<String>, field: Field, unit: String,
                             width: CGFloat, identifier: String) -> some View {
        HStack(spacing: DSSpacing.xs) {
            TextField("0", text: text)
                .textFieldStyle(.plain)
                .font(DSTypography.Figure.regular)
                .focused($focusedField, equals: field)
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
                .onChange(of: text.wrappedValue) { clearValidation(for: field) }
            Text(unit)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityHidden(true)
        }
        .dsFieldChrome(height: DSControlHeight.large, cornerRadius: DSCornerRadius.segment,
                       isFocused: focusedField == field,
                       isInvalid: validation?.field == field, horizontalPadding: 10)
        .frame(width: width)
        .id(field)
    }

    /// Body and headers, aligned with the field column: a Body/Headers switch with a quiet Format
    /// beside it, then the same line-numbered JSON editor the endpoint body uses.
    private var bodyFields: some View {
        VStack(alignment: .leading, spacing: Self.rowSpacing) {
            HStack(spacing: DSSpacing.sm) {
                DSSegmentedControl(
                    "Response part",
                    segments: [
                        .init("Body", value: Pane.body, identifier: "stepSheet.tab.body"),
                        .init("Headers", value: Pane.headers, count: headerCount == 0 ? nil : headerCount,
                              identifier: "stepSheet.tab.headers"),
                    ],
                    selection: $pane,
                    identifier: "stepSheet.pane"
                )
                Spacer(minLength: DSSpacing.sm)
                if pane == .body {
                    Button {
                        if let formatted = DSJSONEditor.prettyPrint(responseBody) {
                            responseBody = formatted
                        }
                    } label: {
                        Text("Format")
                            .font(DSTypography.callout)
                            .foregroundStyle(canFormatBody ? DSColors.labelSecondary : DSColors.labelTertiary)
                            .padding(.horizontal, 6)
                            .frame(height: DSControlHeight.regular)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.dsPlain)
                    .disabled(!canFormatBody)
                    .help("Pretty-print the JSON body")
                    .accessibilityIdentifier("stepSheet.prettyPrintButton")
                    .accessibilityLabel("Pretty-print JSON")
                }
            }

            switch pane {
            case .body:
                DSJSONEditor(text: $responseBody, identifier: "stepSheet.body",
                             documentID: "stepSheet.body.\(step?.id.uuidString ?? "new")")
                    .frame(height: JourneyStepSheet.bodyHeight)
                    .id(Field.body)
            case .headers:
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    DSMultilineField("Headers", text: $headerText,
                                     height: JourneyStepSheet.bodyHeight - DSSpacing.xl,
                                     identifier: "stepSheet.headersField", isFocused: focusBinding(for: .headers),
                                     labelPlacement: .hidden)
                        .accessibilityLabel("Response headers, one per line")
                        .onChange(of: headerText) { clearValidation(for: .headers) }
                    Text("Name: Value, one per line.")
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelTertiary)
                        .accessibilityIdentifier("stepSheet.headersHint")
                    validationMessage(under: .headers)
                }
                .id(Field.headers)
            }
        }
        .padding(.leading, Self.labelWidth + DSSpacing.md)
    }

    /// The design's 200pt code well.
    private static let bodyHeight: CGFloat = 200
    /// The journey step design's label column: 80pt, right-aligned, 12pt before the fields.
    static let labelWidth: CGFloat = 80
    /// The design's rhythm down the form: 14pt between rows, sections and their dividers.
    private static let rowSpacing: CGFloat = 14
    /// The codes the status menu offers; any other is typed.
    static let commonStatusCodes = [200, 201, 202, 204, 301, 302, 304, 400, 401, 403, 404, 409, 422, 429,
                                    500, 502, 503, 504]

    private var title: String {
        guard step != nil else { return "Add step" }
        return stepNumber.map { "Edit step \($0)" } ?? "Edit step"
    }

    /// The endpoint a step's request would also reach, when there is one. Journeys answer first,
    /// so this is information, never a requirement.
    static func matchingEndpoint(method: HTTPMethod, path: String, in endpoints: [Endpoint]) -> Endpoint? {
        guard !path.isEmpty else { return nil }
        let key = PathPattern.matchingKey(for: path)
        return endpoints.first {
            $0.method == method
                && (PathPattern.matchingKey(for: $0.path) == key
                    || PathPattern.matches(requestPath: path, pattern: $0.path))
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DSTypography.captionSemibold)
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityAddTraits(.isHeader)
            .accessibilityIdentifier("stepSheet.section.\(title)")
    }

    private var headerCount: Int {
        headerText.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .count
    }

    /// "Created" for 201, in the words the endpoint editor uses; empty for a code outside HTTP's range.
    private static func reasonPhrase(for code: Int?) -> String {
        guard let code, (100..<600).contains(code) else { return "" }
        return HTTPStatusText.reasonPhrase(for: code)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canFormatBody: Bool {
        !responseBody.isEmpty && DSJSONEditor.prettyPrint(responseBody) != nil
    }

    private func focusBinding(for field: Field) -> Binding<Bool> {
        Binding(get: { focusedField == field }, set: { focused in
            if focused { focusedField = field }
            else if focusedField == field { focusedField = nil }
        })
    }

    /// The complaint about one field, shown directly under it.
    @ViewBuilder
    private func validationMessage(under field: Field) -> some View {
        validationMessage(under: [field])
    }

    /// One message slot for a row of fields. The value repeats the message so a test can tell
    /// which rule refused.
    @ViewBuilder
    private func validationMessage(under fields: [Field]) -> some View {
        if let validation, fields.contains(validation.field) {
            DSValidationMessage(validation.message, identifier: "stepSheet.validationMessage")
        }
    }

    /// Drops a message as soon as its field is edited — the user is already fixing it.
    private func clearValidation(for field: Field) {
        if validation?.field == field {
            validation = nil
        }
    }

    // MARK: - Loading

    private func loadExistingStep() {
        guard let step else { return }
        name = step.name
        method = step.method
        selectedBackend = step.backendID?.uuidString ?? "primary"
        path = step.path
        delayMs = String(step.delayMs)
        repeatCount = String(step.repeatCount)

        switch step.outcome {
        case let .respond(response):
            kind = .respond
            statusCode = String(response.statusCode)
            responseBody = response.body ?? ""
            headerText = response.headers
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
        case let .networkFailure(failure):
            switch failure {
            case .connectionDrop:
                kind = .drop
            case let .timeout(hold):
                kind = .timeout
                holdMs = String(hold)
            }
        }
    }

    // MARK: - Committing

    private func commit() {
        let trimmedPath = self.trimmedPath
        guard !trimmedPath.isEmpty else {
            validation = Validation(field: .path, message: "A step needs a path, e.g. /account-summary.")
            return
        }
        do {
            try EndpointValidator.validatePath(trimmedPath)
        } catch {
            validation = Validation(field: .path, message: error.localizedDescription)
            return
        }

        // Checked, not coerced: a bad value is refused here, while the sheet can still explain it.
        guard let delay = Self.validatedWaitValue(delayMs, existingValue: step?.delayMs) else {
            validation = Validation(
                field: .delay,
                message: "Delay must be a whole number from 0 to \(ResponseDelay.maximumMilliseconds) ms."
            )
            return
        }

        guard let repeats = Int(repeatCount), repeats >= 1 else {
            validation = Validation(field: .repeatCount, message: "Serve count must be 1 or more.")
            return
        }

        var spec = JourneyStepSpec(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
            backend: selectedBackend,
            method: method,
            path: trimmedPath,
            delayMs: delay,
            repeatCount: repeats
        )

        switch kind {
        case .respond:
            guard let code = Int(statusCode), EndpointValidator.serveableStatusCodes.contains(code) else {
                validation = Validation(field: .statusCode, message: "Status code must be between 200 and 599.")
                return
            }
            spec.statusCode = code
            if let invalidLine = Self.firstInvalidHeaderLine(headerText) {
                pane = .headers
                validation = Validation(field: .headers,
                                        message: "Use Name: Value for every header (line \(invalidLine)).")
                return
            }
            spec.headers = Self.parseHeaders(headerText)
            do {
                try EndpointValidator.validateHeaders(spec.headers ?? [:])
            } catch {
                pane = .headers
                validation = Validation(field: .headers, message: error.localizedDescription)
                return
            }
            // Updates are partial: nil preserves the old body, so clearing must send an empty value.
            spec.body = responseBody.isEmpty && step == nil ? nil : responseBody
        case .drop:
            spec.failure = .connectionDrop
        case .timeout:
            let existingHold: Int?
            if let step, case let .networkFailure(.timeout(value)) = step.outcome { existingHold = value }
            else { existingHold = nil }
            guard let hold = Self.validatedWaitValue(holdMs, existingValue: existingHold) else {
                validation = Validation(field: .hold,
                    message: "Hold duration must be from 0 to \(ResponseDelay.maximumMilliseconds) ms.")
                return
            }
            spec.failure = .timeout(holdMs: hold)
        }

        let requestedHold: Int
        if case let .timeout(hold)? = spec.failure { requestedHold = hold }
        else { requestedHold = 0 }
        let oldHold: Int
        if let step, case let .networkFailure(.timeout(hold)) = step.outcome { oldHold = hold }
        else { oldHold = 0 }
        let unchanged = step.map { $0.delayMs == delay && oldHold == requestedHold } == true
        let correction = step.map {
            delay <= $0.delayMs && requestedHold <= oldHold
                && (delay < $0.delayMs || requestedHold < oldHold)
        } == true
        guard unchanged || correction || ResponseDelay.isWithinLimit(
            globalMs: globalDelayMs, localMs: delay, holdMs: requestedHold
        ) else {
            validation = Validation(
                field: kind == .timeout ? .hold : .delay,
                message: "Total wait must not exceed \(ResponseDelay.maximumDescription)."
            )
            return
        }

        validation = nil
        onCommit(spec)
        dismiss()
    }

    /// Existing excessive waits may be preserved or reduced while a saved project is repaired.
    static func validatedWaitValue(_ text: String, existingValue: Int?) -> Int? {
        guard let value = Int(text), value >= 0,
              value <= ResponseDelay.maximumMilliseconds || value <= (existingValue ?? 0) else {
            return nil
        }
        return value
    }

    /// Accepts `Name: Value` per line, tolerating blank lines and colons inside the value.
    static func firstInvalidHeaderLine(_ text: String) -> Int? {
        for (index, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let header = headerLine(line), !header.name.isEmpty else {
                return index + 1
            }
        }
        return nil
    }

    /// Convert header lines after validation. Duplicate names keep their final value.
    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let header = headerLine(line), !header.name.isEmpty else { continue }
            headers[header.name] = header.value
        }
        return headers
    }

    private static func headerLine(_ line: Substring) -> (name: String, value: String)? {
        let scalars = line.unicodeScalars
        guard let separator = scalars.firstIndex(of: ":") else { return nil }
        let name = String(scalars[..<separator]).trimmingCharacters(in: .whitespaces)
        let value = String(scalars[scalars.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
        return (name, value)
    }
}
