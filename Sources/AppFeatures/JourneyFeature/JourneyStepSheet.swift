import AppKit
import DesignSystem
import Domain
import SwiftUI

/// Adds or edits one journey step.
///
/// A step either answers or fails at the transport level, so the form asks that first and then shows
/// only the fields that apply — a status code and a timeout hold are not fields you fill in together.
///
/// Common request and response fields stay visible. Headers and timing are available in compact
/// disclosures, so a new step does not open as a full settings page with its last section hidden.
struct JourneyStepSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// `nil` when adding.
    let step: JourneyStep?
    var backends: [BackendConfiguration] = []
    var globalDelayMs: Int = 0
    let onCommit: (JourneyStepSpec) -> Void

    private enum Kind: String, CaseIterable, Identifiable {
        case respond
        case drop
        case timeout

        var id: String { rawValue }

        var title: String {
            switch self {
            case .respond: "Respond"
            case .drop: "Drop the connection"
            case .timeout: "Time out"
            }
        }
    }

    /// The form's inputs, named so focus and validation can both point at one.
    ///
    /// A complaint belongs under the input that caused it. This sheet used to print every message in
    /// one slot above the buttons, which meant a bad status code was explained three rows away from
    /// the status code.
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
    @State private var headersExpanded = false
    @State private var timingExpanded = false
    @State private var validation: Validation?
    @State private var scrollPresentationID = UUID()
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Text(step == nil ? "Add step" : "Edit step")
                    .font(DSTypography.title)
                    .foregroundStyle(DSColors.labelPrimary)
                    .accessibilityIdentifier("stepSheet.title")
                Text("Match a request, then choose what the client receives.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(DSSpacing.lg)

            DSDivider(identifier: "stepSheet.heading")

            ScrollViewReader { scroll in
                ScrollView {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        requestFields
                        outcomeFields
                        timingFields
                    }
                    .padding(DSSpacing.lg)
                }
                .onChange(of: validation) { _, newValue in
                    guard let newValue else { return }
                    // Let a newly expanded disclosure lay out before bringing its field into view.
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation { scroll.scrollTo(newValue.field, anchor: .center) }
                        focusedField = newValue.field
                    }
                }
                .onChange(of: headersExpanded) { _, expanded in
                    guard expanded else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation { scroll.scrollTo(Field.headers, anchor: .bottom) }
                    }
                }
                .onChange(of: timingExpanded) { _, expanded in
                    guard expanded else { return }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(100))
                        withAnimation { scroll.scrollTo(Field.delay, anchor: .bottom) }
                    }
                }
            }
            .id(scrollPresentationID)

            DSDivider(identifier: "stepSheet.footer")
            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton("Cancel", variant: .ghost, size: .medium,
                         identifier: "stepSheet.cancel", action: dismiss.callAsFunction)
                    .accessibilityIdentifier("stepSheet.cancelButton")
                    .accessibilityLabel("Cancel")
                    .keyboardShortcut(.cancelAction)
                DSButton(step == nil ? "Add step" : "Save step", variant: .primary, size: .medium,
                         identifier: "stepSheet.save", action: commit)
                    .accessibilityIdentifier("stepSheet.saveButton")
                    .accessibilityLabel(step == nil ? "Add step" : "Save step")
                    .disabled(trimmedPath.isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(DSSpacing.lg)
        }
        .frame(width: DSSheetWidth.medium,
               height: min(DSFormMetrics.journeyStepHeight,
                           (NSScreen.main?.visibleFrame.height ?? DSFormMetrics.maximumTallSheetHeight)
                               - DSFormMetrics.screenVerticalAllowance))
        .defaultFocus($focusedField, .path)
        .onAppear {
            loadExistingStep()
            // AppKit may reuse the same scroll view when switching between Add and Edit sheets.
            // Recreate only the scroll container for each presentation so its old offset is not restored.
            scrollPresentationID = UUID()
        }
    }

    private var requestFields: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            sectionHeading("Request", detail: "Match this call")
            DSTextField("Step name (optional)", text: $name, placeholder: "e.g. Charge declined",
                        identifier: "stepSheet.nameField")
                .focused($focusedField, equals: .name)
                .accessibilityIdentifier("stepSheet.nameField")
                .accessibilityLabel("Step name")
            HStack(alignment: .top, spacing: DSSpacing.md) {
                DSFormPicker("Method", selection: $method, identifier: "stepSheet.methodPicker") {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .frame(width: DSFormMetrics.compactFieldWidth)
                DSTextField("Path", text: $path, placeholder: "/account-summary",
                            validation: validationText(for: .path),
                            validationIdentifier: "stepSheet.validationMessage",
                            inputIdentifier: "stepSheet.pathField",
                            identifier: "stepSheet.pathField")
                    .focused($focusedField, equals: .path)
                    .onChange(of: path) { clearValidation(for: .path) }
                    .id(Field.path)
            }
            if backends.count > 1 {
                DSFormPicker("Server", selection: $selectedBackend, identifier: "stepSheet.backendPicker") {
                    Text(backends.first { $0.id == ServerConfiguration.primaryID }?.name ?? "Primary").tag("primary")
                    ForEach(backends.filter { $0.id != ServerConfiguration.primaryID }) { backend in
                        Text(backend.name).tag(backend.id.uuidString)
                    }
                }
            }
        }
    }

    private var outcomeFields: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            sectionHeading("Outcome", detail: "What the client sees")
            Picker("Outcome", selection: $kind) {
                ForEach(Kind.allCases) { kind in Text(kind.title).tag(kind) }
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: DSSheetWidth.medium - DSSpacing.lg * 2)
            .accessibilityIdentifier("stepSheet.outcomePicker")
            .accessibilityLabel("Outcome")
            .onChange(of: kind) { validation = nil }

            switch kind {
            case .respond:
                DSTextField("Status code", text: $statusCode,
                            validation: validationText(for: .statusCode),
                            validationIdentifier: "stepSheet.validationMessage",
                            controlWidth: DSFormMetrics.compactFieldWidth,
                            inputIdentifier: "stepSheet.statusField",
                            identifier: "stepSheet.statusField")
                    .focused($focusedField, equals: .statusCode)
                    .onChange(of: statusCode) { clearValidation(for: .statusCode) }
                    .id(Field.statusCode)
                DSMultilineField("Response body", text: $responseBody,
                                 height: DSControlHeight.field * 5,
                                 identifier: "stepSheet.bodyField") {
                    Button {
                        if let formatted = DSJSONEditor.prettyPrint(responseBody) {
                            responseBody = formatted
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
                    .accessibilityIdentifier("stepSheet.prettyPrintButton")
                    .accessibilityLabel("Pretty-print JSON")
                }
                .focused($focusedField, equals: .body)
                disclosureRow("Response headers", summary: headerText.isEmpty ? "None" : "Custom",
                              expanded: $headersExpanded, identifier: "stepSheet.headersDisclosure")
                if headersExpanded {
                    VStack(alignment: .leading, spacing: DSSpacing.xs) {
                        DSMultilineField("Headers", text: $headerText,
                                         height: DSControlHeight.field * 3,
                                         identifier: "stepSheet.headersField")
                            .focused($focusedField, equals: .headers)
                            .accessibilityLabel("Response headers, one per line")
                            .onChange(of: headerText) { clearValidation(for: .headers) }
                            .id(Field.headers)
                        Text("Name: Value, one per line.")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                            .accessibilityIdentifier("stepSheet.headersHint")
                        validationMessage(under: .headers)
                    }
                }
            case .drop:
                Text("The connection closes without a response. The client sees a network failure.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepSheet.dropHint")
            case .timeout:
                DSTextField("Hold for (ms)", text: $holdMs,
                            validation: validationText(for: .hold),
                            validationIdentifier: "stepSheet.validationMessage",
                            controlWidth: DSFormMetrics.compactFieldWidth,
                            inputIdentifier: "stepSheet.holdField",
                            identifier: "stepSheet.holdField")
                    .focused($focusedField, equals: .hold)
                    .onChange(of: holdMs) { clearValidation(for: .hold) }
                    .id(Field.hold)
                Text("Nothing is sent while the client waits for its own timeout.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("stepSheet.timeoutHint")
            }
        }
    }

    private var timingFields: some View {
        VStack(alignment: .leading, spacing: DSSpacing.md) {
            DSDivider(identifier: "stepSheet.timing")
            disclosureRow("Timing & repeats", summary: timingSummary,
                          expanded: $timingExpanded, identifier: "stepSheet.timingDisclosure")
            if timingExpanded {
                HStack(alignment: .top, spacing: DSSpacing.md) {
                    DSTextField("Delay (ms)", text: $delayMs,
                                validation: validationText(for: .delay),
                                validationIdentifier: "stepSheet.validationMessage",
                                inputIdentifier: "stepSheet.delayField",
                                identifier: "stepSheet.delayField")
                        .focused($focusedField, equals: .delay)
                        .onChange(of: delayMs) { clearValidation(for: .delay) }
                        .id(Field.delay)
                    DSTextField("Serve count", text: $repeatCount,
                                validation: validationText(for: .repeatCount),
                                validationIdentifier: "stepSheet.validationMessage",
                                inputIdentifier: "stepSheet.repeatField",
                                identifier: "stepSheet.repeatField")
                        .focused($focusedField, equals: .repeatCount)
                        .onChange(of: repeatCount) { clearValidation(for: .repeatCount) }
                        .id(Field.repeatCount)
                }
                Text("Use repeats to keep a polling response current for several requests.")
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sectionHeading(_ title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(DSTypography.controlLabel).foregroundStyle(DSColors.labelPrimary)
                Spacer()
                Text(detail).font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
            }
            DSDivider(identifier: "stepSheet.section.\(title)")
        }
    }

    private func disclosureRow(_ title: String, summary: String, expanded: Binding<Bool>,
                               identifier: String) -> some View {
        Button { expanded.wrappedValue.toggle() } label: {
            HStack(spacing: DSSpacing.sm) {
                Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right")
                    .font(.system(size: DSGlyph.indicator, weight: .semibold))
                    .frame(width: DSGlyph.control)
                    .accessibilityHidden(true)
                Text(title).font(DSTypography.bodyMedium)
                Spacer()
                Text(summary).font(DSTypography.label).foregroundStyle(DSColors.labelSecondary)
            }
            .foregroundStyle(DSColors.labelPrimary)
            .frame(minHeight: DSControlHeight.navigation)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(title)
        .accessibilityValue(expanded.wrappedValue ? "Expanded" : "Collapsed")
    }

    private var timingSummary: String {
        let delay = delayMs == "0" ? "No delay" : "\(delayMs) ms delay"
        let repeats = repeatCount == "1" ? "Once" : "\(repeatCount) times"
        return "\(delay) · \(repeats)"
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canFormatBody: Bool {
        !responseBody.isEmpty && DSJSONEditor.prettyPrint(responseBody) != nil
    }

    private func validationText(for field: Field) -> String? {
        validation?.field == field ? validation?.message : nil
    }

    /// The complaint about one field, shown directly under it.
    @ViewBuilder
    private func validationMessage(under field: Field) -> some View {
        if let validation, validation.field == field {
            Text(validation.message)
                .font(DSTypography.label)
                .foregroundStyle(DSColors.destructive)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("stepSheet.validationMessage")
                .accessibilityLabel(validation.message)
                // Six different rules refuse through this one view, so the identifier alone says
                // only "something was rejected". The value carries *which* — the same string the
                // label reads — so a test can assert the sheet refused for the reason it meant to
                // test rather than for whichever complaint happened to fire first.
                .accessibilityValue(validation.message)
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
        timingExpanded = step.delayMs != 0 || step.repeatCount != 1

        switch step.outcome {
        case let .respond(response):
            kind = .respond
            statusCode = String(response.statusCode)
            responseBody = response.body ?? ""
            headerText = response.headers
                .sorted { $0.key < $1.key }
                .map { "\($0.key): \($0.value)" }
                .joined(separator: "\n")
            headersExpanded = !headerText.isEmpty
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

        // Checked, not coerced. `Int(delayMs) ?? 0` turned "abc" into a step that answers instantly
        // and `max(1, …)` turned "0" into 1, both without a word — and since `commit()` ends in
        // `onCommit` then `dismiss()` unconditionally, anything the executor rejected afterwards had
        // no sheet left to report against. In the main window there is no alert at all, so the step
        // simply never appeared. The `.timeout` branch below already guards its own field this way.
        guard let delay = Int(delayMs), delay >= 0,
              delay <= ResponseDelay.maximumMilliseconds || delay == step?.delayMs else {
            timingExpanded = true
            validation = Validation(
                field: .delay,
                message: "Delay must be a whole number from 0 to \(ResponseDelay.maximumMilliseconds) ms."
            )
            return
        }

        guard let repeats = Int(repeatCount), repeats >= 1 else {
            timingExpanded = true
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
                headersExpanded = true
                validation = Validation(field: .headers,
                                        message: "Use Name: Value for every header (line \(invalidLine)).")
                return
            }
            spec.headers = Self.parseHeaders(headerText)
            // An empty body field means "no body", which is different from an empty string body only
            // in intent; sending nil keeps the response bodyless.
            spec.body = responseBody.isEmpty ? nil : responseBody
        case .drop:
            spec.failure = .connectionDrop
        case .timeout:
            let existingHold: Int?
            if let step, case let .networkFailure(.timeout(value)) = step.outcome { existingHold = value }
            else { existingHold = nil }
            guard let hold = Int(holdMs), hold >= 0,
                  hold <= ResponseDelay.maximumMilliseconds || hold == existingHold else {
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
            timingExpanded = true
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

    /// Accepts `Name: Value` per line, tolerating blank lines and colons inside the value.
    static func firstInvalidHeaderLine(_ text: String) -> Int? {
        for (index, line) in text.components(separatedBy: .newlines).enumerated() {
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
            guard let separator = line.firstIndex(of: ":"),
                  !line[..<separator].trimmingCharacters(in: .whitespaces).isEmpty else {
                return index + 1
            }
        }
        return nil
    }

    /// Convert header lines after validation. Duplicate names keep their final value.
    static func parseHeaders(_ text: String) -> [String: String] {
        var headers: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<separator].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { continue }
            headers[name] = value
        }
        return headers
    }
}
