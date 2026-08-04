import DesignSystem
import Domain
import SwiftUI

/// Adds or edits one journey step.
///
/// A step either answers or fails at the transport level, so the form asks that first and then shows
/// only the fields that apply — a status code and a timeout hold are not fields you fill in together.
///
/// The chrome follows the shared sheet convention: a sentence-case heading inside the sheet,
/// `DSSpacing.lg` between the heading, the form and the button row, `DSSpacing.lg` of outer padding,
/// and a trailing button row with cancel to the left of the confirm action. This is the one sheet
/// that keeps a grouped `Form` — it is the only multi-section one — so it declares a wider ideal
/// width while sharing the same minimum as the rest.
struct JourneyStepSheet: View {
    @Environment(\.dismiss) private var dismiss

    /// `nil` when adding.
    let step: JourneyStep?
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
    @State private var path = ""
    @State private var statusCode = "200"
    @State private var responseBody = ""
    @State private var headerText = ""
    @State private var delayMs = "0"
    @State private var repeatCount = "1"
    @State private var holdMs = String(NetworkFailure.defaultTimeoutHoldMs)
    @State private var validation: Validation?
    @FocusState private var focusedField: Field?

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.lg) {
            Text(step == nil ? "Add step" : "Edit step")
                .font(DSTypography.title)
                .foregroundStyle(DSColors.labelPrimary)

            Form {
                Section {
                    TextField("Name", text: $name, prompt: Text("Optional — defaults to the route"))
                        .focused($focusedField, equals: .name)
                        .accessibilityIdentifier("stepSheet.nameField")
                        .accessibilityLabel("Step name")

                    Picker("Method", selection: $method) {
                        ForEach(HTTPMethod.allCases, id: \.self) { method in
                            Text(method.rawValue).tag(method)
                        }
                    }
                    .accessibilityIdentifier("stepSheet.methodPicker")
                    .accessibilityLabel("HTTP method")

                    TextField("Path", text: $path, prompt: Text("/account-summary"))
                        .focused($focusedField, equals: .path)
                        .accessibilityIdentifier("stepSheet.pathField")
                        .accessibilityLabel("Path")
                        .onChange(of: path) { clearValidation(for: .path) }

                    validationMessage(under: .path)
                }

                Section {
                    Picker("Outcome", selection: $kind) {
                        ForEach(Kind.allCases) { kind in
                            Text(kind.title).tag(kind)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("stepSheet.outcomePicker")
                    .accessibilityLabel("Outcome")
                    // Switching outcome hides the field a message was pointing at, and a complaint
                    // with nothing to point at reads as a bug in the sheet.
                    .onChange(of: kind) { validation = nil }

                    switch kind {
                    case .respond:
                        TextField("Status code", text: $statusCode)
                            .focused($focusedField, equals: .statusCode)
                            .accessibilityIdentifier("stepSheet.statusField")
                            .accessibilityLabel("Status code")
                            .onChange(of: statusCode) { clearValidation(for: .statusCode) }

                        validationMessage(under: .statusCode)

                        TextField("Headers", text: $headerText, prompt: Text("Retry-After: 30"), axis: .vertical)
                            .lineLimit(2...4)
                            .font(DSTypography.code)
                            .focused($focusedField, equals: .headers)
                            .accessibilityIdentifier("stepSheet.headersField")
                            .accessibilityLabel("Response headers, one per line, option-Return for a new line")

                        // The prompt used to say "one per line" and stop there, which is the half of
                        // the instruction that does not help. Driven from the keyboard, Return in this
                        // field ends the edit — it neither adds a line nor commits the sheet — so
                        // somebody following the prompt types one header, presses Return, and finds no
                        // second line and no explanation. ⌥Return is the key that works, and it is not
                        // guessable. The caption idiom is already this sheet's, twice below.
                        Text("One per line \u{2014} press \u{2325}\u{21A9} for a new line.")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.labelSecondary)
                            .accessibilityIdentifier("stepSheet.headersHint")

                        TextField("Body", text: $responseBody, prompt: Text("{\"balance\": 1520.44}"), axis: .vertical)
                            .lineLimit(4...10)
                            .font(DSTypography.code)
                            .focused($focusedField, equals: .body)
                            .accessibilityIdentifier("stepSheet.bodyField")
                            .accessibilityLabel("Response body")

                    case .drop:
                        Text("The connection is torn down mid-response. The client sees a network "
                            + "failure rather than a status code.")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                    case .timeout:
                        TextField("Hold for (ms)", text: $holdMs)
                            .focused($focusedField, equals: .hold)
                            .accessibilityIdentifier("stepSheet.holdField")
                            .accessibilityLabel("Hold duration in milliseconds")
                            .onChange(of: holdMs) { clearValidation(for: .hold) }

                        validationMessage(under: .hold)

                        Text("Nothing is sent for this long, so the client's own timeout fires first.")
                            .font(DSTypography.caption)
                            .foregroundStyle(DSColors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Section {
                    TextField("Delay before answering (ms)", text: $delayMs)
                        .focused($focusedField, equals: .delay)
                        .onChange(of: delayMs) { clearValidation(for: .delay) }
                        .accessibilityIdentifier("stepSheet.delayField")
                        .accessibilityLabel("Delay in milliseconds")

                    validationMessage(under: .delay)

                    TextField("Serve this many times", text: $repeatCount)
                        .focused($focusedField, equals: .repeatCount)
                        .onChange(of: repeatCount) { clearValidation(for: .repeatCount) }
                        .accessibilityIdentifier("stepSheet.repeatField")
                        .accessibilityLabel("Repeat count")

                    validationMessage(under: .repeatCount)

                    Text("A repeat above 1 keeps the step current across several requests — how a poll "
                        + "stays pending before it completes.")
                        .font(DSTypography.caption)
                        // Matches the two identical captions above it in this sheet.
                        .foregroundStyle(DSColors.labelSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .formStyle(.grouped)

            HStack(spacing: DSSpacing.md) {
                Spacer()
                DSButton(
                    "Cancel",
                    variant: .ghost,
                    size: .medium,
                    identifier: "stepSheet.cancel",
                    action: dismiss.callAsFunction
                )
                .accessibilityIdentifier("stepSheet.cancelButton")
                .accessibilityLabel("Cancel")
                .keyboardShortcut(.cancelAction)

                DSButton(
                    step == nil ? "Add step" : "Save step",
                    variant: .primary,
                    size: .medium,
                    identifier: "stepSheet.save",
                    action: commit
                )
                .accessibilityIdentifier("stepSheet.saveButton")
                .accessibilityLabel(step == nil ? "Add step" : "Save step")
                // Only the empty case disables the button. A path that is present but malformed has
                // to stay clickable, because the explanation of *why* it is malformed is what the
                // click produces.
                .disabled(trimmedPath.isEmpty)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(DSSpacing.lg)
        .frame(minWidth: 420, idealWidth: 520)
        .defaultFocus($focusedField, .name)
        .onAppear(perform: loadExistingStep)
    }

    private var trimmedPath: String {
        path.trimmingCharacters(in: .whitespacesAndNewlines)
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

        // Checked, not coerced. `Int(delayMs) ?? 0` turned "abc" into a step that answers instantly
        // and `max(1, …)` turned "0" into 1, both without a word — and since `commit()` ends in
        // `onCommit` then `dismiss()` unconditionally, anything the executor rejected afterwards had
        // no sheet left to report against. In the main window there is no alert at all, so the step
        // simply never appeared. The `.timeout` branch below already guards its own field this way.
        guard let delay = Int(delayMs), delay >= 0 else {
            validation = Validation(
                field: .delay,
                message: "Delay must be a whole number of milliseconds, zero or more."
            )
            return
        }

        guard let repeats = Int(repeatCount), repeats >= 1 else {
            validation = Validation(field: .repeatCount, message: "Serve count must be 1 or more.")
            return
        }

        var spec = JourneyStepSpec(
            name: name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : name,
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
            spec.headers = Self.parseHeaders(headerText)
            // An empty body field means "no body", which is different from an empty string body only
            // in intent; sending nil keeps the response bodyless.
            spec.body = responseBody.isEmpty ? nil : responseBody
        case .drop:
            spec.failure = .connectionDrop
        case .timeout:
            guard let hold = Int(holdMs), hold >= 0 else {
                validation = Validation(field: .hold, message: "Hold duration must be zero or greater.")
                return
            }
            spec.failure = .timeout(holdMs: hold)
        }

        validation = nil
        onCommit(spec)
        dismiss()
    }

    /// Accepts `Name: Value` per line, tolerating blank lines and colons inside the value.
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
