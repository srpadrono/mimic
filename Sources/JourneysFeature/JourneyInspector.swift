import DesignSystem
import Domain
import SwiftUI

/// The inspector for the journeys screen: the selected step when there is one, the journey itself
/// when there is not.
///
/// A step shows what it matches and what the client gets, editable in place; the body and headers
/// stay in the step sheet, one "Edit step…" away. The journey shows its run, its description and
/// group, and auto-advance — the settings that do not earn a place above the step list.
public struct JourneyInspector: View {
    public struct Context {
        public let selected: Journey
        public let active: Journey?
        public let progress: String?
        public let serverState: ServerState
        /// The step the step list has selected, if any.
        public var selectedStepID: UUID?

        public init(selected: Journey, active: Journey?, progress: String?, serverState: ServerState,
                    selectedStepID: UUID? = nil) {
            self.selected = selected
            self.active = active
            self.progress = progress
            self.serverState = serverState
            self.selectedStepID = selectedStepID
        }

        public var selectedStepIndex: Int? {
            guard let selectedStepID else { return nil }
            return selected.steps.firstIndex { $0.id == selectedStepID }
        }

        public var selectedStep: JourneyStep? {
            selectedStepIndex.map { selected.steps[$0] }
        }

        /// "Step 3" while a step is selected, "Journey" otherwise.
        public var title: String {
            selectedStepIndex.map { "Step \($0 + 1)" } ?? "Journey"
        }
    }

    let model: any JourneyEditingModel
    let context: Context

    public init(model: any JourneyEditingModel, context: Context) {
        self.model = model
        self.context = context
    }

    public var body: some View {
        if let step = context.selectedStep, let index = context.selectedStepIndex {
            JourneyStepInspector(model: model, journey: context.selected, step: step, index: index)
                .id(step.id)
        } else {
            JourneySummaryInspector(model: model, context: context)
        }
    }
}

/// The inspector header's "…" for the selected step: the same actions as the row's context menu.
public struct JourneyStepActionsMenu: View {
    let model: any JourneyEditingModel
    let context: JourneyInspector.Context

    public init(model: any JourneyEditingModel, context: JourneyInspector.Context) {
        self.model = model
        self.context = context
    }

    public var body: some View {
        if let step = context.selectedStep, let index = context.selectedStepIndex {
            DSIconMenu(systemImage: "ellipsis", help: "More step actions",
                       identifier: "inspector.journeyStep.moreMenu") {
                JourneyStepMenuItems(model: model, journey: context.selected, step: step, index: index) {
                    model.editingJourneyStepID = step.id
                }
            }
        }
    }
}

// MARK: - Journey

private struct JourneySummaryInspector: View {
    let model: any JourneyEditingModel
    let context: JourneyInspector.Context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                // The panel header already says "Journey"; the rows sit directly under it.
                DSInspectorValueRow("Steps", value: "\(context.selected.steps.count)",
                                    identifier: "inspector.journey.steps")
                JourneyInspectorFieldRow("Description") {
                    JourneyTextField(
                        value: context.selected.summary ?? "",
                        placeholder: "What this journey tests",
                        identifier: "journeyEditor.summaryField",
                        label: "Journey description"
                    ) { summary in
                        update(JourneySpec(summary: summary))
                        return true
                    }
                }
                JourneyInspectorFieldRow("Group") {
                    JourneyTextField(
                        value: context.selected.groupTag ?? "",
                        placeholder: "Ungrouped",
                        identifier: "journeyEditor.groupTag",
                        label: "Journey group"
                    ) { group in
                        update(JourneySpec(groupTag: group))
                        return true
                    }
                    .help("Journeys with the same group appear together. Clear to leave ungrouped.")
                }

                DSInspectorSectionHeader("Run", identifier: "journey.run")
                DSInspectorValueRow("State", value: runState,
                                    color: isSelectedActive ? DSColors.success : DSColors.labelPrimary,
                                    identifier: "inspector.journey.state")
                if let active = context.active {
                    if active.id != context.selected.id {
                        DSInspectorValueRow("Active", value: active.name,
                                            identifier: "inspector.journey.activeName")
                    }
                    if let progress = context.progress {
                        DSInspectorValueRow("Progress", value: progress,
                                            identifier: "inspector.journey.progress")
                    }
                }
                DSInspectorValueRow("Server", value: serverStatus,
                                    color: serverColor,
                                    identifier: "inspector.journey.server")
                if context.active == nil {
                    JourneyInspectorNote("No journey active. Endpoints answer directly.")
                        .accessibilityIdentifier("inspector.journey.noActiveRun")
                } else if isSelectedActive, context.serverState.runningPort == nil {
                    JourneyInspectorNote("Restart and Next step set the step for the next server run.")
                }

                DSInspectorSectionHeader("Matching", identifier: "journey.matching")
                DSInspectorValueRow("Order", value: JourneyEditorView.title(for: context.selected.matchMode),
                                    identifier: "inspector.journey.matchMode")
                DSInspectorValueRow("Unscripted", value: JourneyEditorView.title(for: context.selected.unmatchedBehavior),
                                    identifier: "inspector.journey.unmatched")
                JourneyInspectorNote(matchExplanation)
                JourneyInspectorFieldRow("Auto-advance") {
                    Toggle("Move on once a step is served", isOn: autoAdvanceBinding)
                        .toggleStyle(.checkbox)
                        .font(DSTypography.callout)
                        .controlSize(.small)
                        .accessibilityIdentifier("journeyEditor.autoAdvanceToggle")
                        .accessibilityLabel("Advance automatically")
                }
                .padding(.top, DSSpacing.xs)
            }
            .padding(.bottom, DSSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(context.selected.name)")
        .accessibilityIdentifier("inspector.journey")
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { context.selected.autoAdvance },
            set: { update(JourneySpec(autoAdvance: $0)) }
        )
    }

    /// A field committing as it disappears may outlive its journey; a deleted one takes no edits.
    private func update(_ spec: JourneySpec) {
        guard model.journeys.contains(where: { $0.id == context.selected.id }) else { return }
        model.updateJourney(id: context.selected.id, spec: spec)
    }

    private var isSelectedActive: Bool { context.selected.id == context.active?.id }

    private var runState: String {
        guard isSelectedActive else { return "Inactive journey" }
        return context.serverState.runningPort == nil ? "Prepared for next server run" : "Active journey"
    }

    private var matchExplanation: String {
        switch context.selected.matchMode {
        case .orderedPerEndpoint: "The next available step for each route can answer."
        case .strictSequence: "Only the current step can answer."
        }
    }

    private var serverStatus: String {
        switch context.serverState {
        case .stopped: "Stopped"
        case .starting: "Starting\u{2026}"
        case .running: "Running"
        case .stopping: "Stopping\u{2026}"
        case .error: "Error"
        }
    }

    private var serverColor: Color {
        switch context.serverState {
        case .running: DSColors.success
        case .error: DSColors.error
        default: DSColors.labelSecondary
        }
    }
}

// MARK: - Step

/// One step, edited in place: Match (method, path) and Outcome (a response, or a connection failure).
private struct JourneyStepInspector: View {
    let model: any JourneyEditingModel

    let journey: Journey
    let step: JourneyStep
    let index: Int

    private enum OutcomeKind: Hashable {
        case response
        case failure
    }

    private enum FailureKind: Hashable {
        case drop
        case timeout
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                sectionTitle("Match")
                JourneyInspectorFieldRow("Method") { methodPicker }
                JourneyInspectorFieldRow("Path") {
                    JourneyTextField(
                        value: step.path,
                        placeholder: "/account-summary",
                        identifier: "inspector.journeyStep.path",
                        label: "Path",
                        monospaced: true
                    ) { path in
                        guard !path.isEmpty, (try? EndpointValidator.validatePath(path)) != nil else { return false }
                        update(JourneyStepSpec(path: path))
                        return true
                    }
                }
                matchNote

                Rectangle()
                    .fill(DSColors.separator)
                    .frame(height: DSStroke.hairline)
                    .padding(.horizontal, DSInspectorMetrics.inset)
                    .padding(.vertical, 14)
                    .accessibilityHidden(true)

                sectionTitle("Outcome")
                DSSegmentedControl(
                    "Outcome",
                    segments: [
                        .init("Response", value: OutcomeKind.response, identifier: "inspector.journeyStep.outcome.response"),
                        .init("Connection failure", value: OutcomeKind.failure,
                              identifier: "inspector.journeyStep.outcome.failure"),
                    ],
                    selection: outcomeBinding,
                    fillsWidth: true,
                    identifier: "inspector.journeyStep.outcome"
                )
                .padding(.horizontal, DSInspectorMetrics.inset)
                .padding(.bottom, DSSpacing.sm)

                switch step.outcome {
                case let .respond(response):
                    responseFields(response)
                case let .networkFailure(failure):
                    failureFields(failure)
                }
            }
            .padding(.bottom, DSSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for step \(index + 1)")
        .accessibilityIdentifier("inspector.journeyStep")
    }

    // MARK: Match

    /// The method in its colour inside a field, with one down chevron after it, as the design draws it.
    private var methodPicker: some View {
        DSMenuField(
            "HTTP method",
            selection: Binding(
                get: { step.method },
                set: { update(JourneyStepSpec(method: $0)) }
            ),
            options: HTTPMethod.allCases.map { DSMenuOption($0.rawValue, value: $0) },
            indicator: .down,
            indicatorFollowsLabel: true,
            identifier: "inspector.journeyStep.method"
        ) { method in
            // The method column the step rows use, so the chevron sits where the design puts it.
            Text(method.rawValue)
                .font(DSTypography.method)
                .foregroundStyle(DSColors.methodColor(for: method.rawValue))
                .frame(width: 44, alignment: .leading)
        }
    }

    /// Whether an endpoint serves the same route: useful to know, never required, since a journey
    /// answers before the endpoints do.
    @ViewBuilder
    private var matchNote: some View {
        let endpoint = JourneyStepSheet.matchingEndpoint(
            method: step.method, path: step.path, in: model.currentProject?.endpoints ?? []
        )
        // Wraps under the field rather than truncating mid-sentence in a narrow inspector.
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let endpoint {
                Image(systemName: "checkmark")
                    .font(.system(size: DSGlyph.disclosure, weight: .semibold))
                    .foregroundStyle(DSColors.success)
                    .accessibilityHidden(true)
                Text("Matches \(endpoint.method.rawValue) \(endpoint.path)")
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No endpoint serves this route")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(DSTypography.caption)
        .foregroundStyle(DSColors.labelTertiary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, DSInspectorMetrics.inset + JourneyInspectorMetrics.labelColumn + DSSpacing.md)
        .padding(.trailing, DSInspectorMetrics.inset)
        .frame(minHeight: 18)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("inspector.journeyStep.matchNote")
    }

    // MARK: Outcome

    @ViewBuilder
    private func responseFields(_ response: JourneyResponse) -> some View {
        JourneyInspectorFieldRow("Status") {
            JourneyNumberField(value: response.statusCode, unit: nil,
                               identifier: "inspector.journeyStep.status", label: "Status code") { code in
                guard EndpointValidator.serveableStatusCodes.contains(code) else { return false }
                update(JourneyStepSpec(statusCode: code))
                return true
            }
        }
        JourneyInspectorFieldRow("Delay") {
            JourneyNumberField(value: step.delayMs, unit: "ms",
                               identifier: "inspector.journeyStep.delay", label: "Delay in milliseconds") { delay in
                guard isWait(delay, allowedAgainst: step.delayMs, holdMs: 0) else { return false }
                update(JourneyStepSpec(delayMs: delay))
                return true
            }
        }
        repeatRow
        JourneyInspectorNote("The body and headers are in Edit step\u{2026}")
    }

    @ViewBuilder
    private func failureFields(_ failure: NetworkFailure) -> some View {
        JourneyInspectorFieldRow("Failure") {
            DSMenuField(
                "Failure",
                selection: Binding(
                    get: { failure == .connectionDrop ? FailureKind.drop : FailureKind.timeout },
                    set: { kind in
                        update(JourneyStepSpec(failure: kind == .drop
                            ? .connectionDrop : .timeout(holdMs: NetworkFailure.defaultTimeoutHoldMs)))
                    }
                ),
                options: [DSMenuOption("Hold, then drop", value: FailureKind.drop),
                          DSMenuOption("Time out", value: FailureKind.timeout)],
                identifier: "inspector.journeyStep.failure"
            )
        }
        JourneyInspectorFieldRow("Hold for") {
            switch failure {
            case .connectionDrop:
                // A dropped connection holds for the step's delay, then closes.
                JourneyNumberField(value: step.delayMs, unit: "ms",
                                   identifier: "inspector.journeyStep.hold", label: "Hold for, in milliseconds") { hold in
                    guard isWait(hold, allowedAgainst: step.delayMs, holdMs: 0) else { return false }
                    update(JourneyStepSpec(delayMs: hold))
                    return true
                }
            case let .timeout(holdMs):
                JourneyNumberField(value: holdMs, unit: "ms",
                                   identifier: "inspector.journeyStep.hold", label: "Hold for, in milliseconds") { hold in
                    guard hold >= 0, hold <= ResponseDelay.maximumMilliseconds || hold <= holdMs,
                          ResponseDelay.isWithinLimit(globalMs: model.serverConfiguration.globalDelayMs,
                                                      localMs: step.delayMs, holdMs: hold) || hold <= holdMs
                    else { return false }
                    update(JourneyStepSpec(failure: .timeout(holdMs: hold)))
                    return true
                }
            }
        }
        repeatRow
        JourneyInspectorNote("Clients often retry dropped requests. Raise Repeat if the failure must survive a retry.")
    }

    private var repeatRow: some View {
        JourneyInspectorFieldRow("Repeat") {
            JourneyNumberField(value: step.repeatCount, unit: step.repeatCount == 1 ? "time" : "times",
                               identifier: "inspector.journeyStep.repeat", label: "Serve count") { count in
                guard count >= 1 else { return false }
                update(JourneyStepSpec(repeatCount: count))
                return true
            }
        }
    }

    private var outcomeBinding: Binding<OutcomeKind> {
        Binding(
            get: {
                if case .respond = step.outcome { return .response }
                return .failure
            },
            set: { kind in
                switch (kind, step.outcome) {
                case (.response, .networkFailure):
                    update(JourneyStepSpec(statusCode: 200))
                case (.failure, .respond):
                    update(JourneyStepSpec(failure: .connectionDrop))
                default:
                    break
                }
            }
        )
    }

    /// A wait may always be kept or shortened; lengthening it must stay inside the server's limit.
    private func isWait(_ value: Int, allowedAgainst existing: Int, holdMs: Int) -> Bool {
        guard value >= 0 else { return false }
        if value <= existing { return true }
        return value <= ResponseDelay.maximumMilliseconds
            && ResponseDelay.isWithinLimit(globalMs: model.serverConfiguration.globalDelayMs,
                                           localMs: value, holdMs: holdMs)
    }

    /// A field committing as it disappears may outlive its step; a removed one takes no edits.
    private func update(_ spec: JourneyStepSpec) {
        guard model.journeys.first(where: { $0.id == journey.id })?.steps.contains(where: { $0.id == step.id }) == true
        else { return }
        model.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(DSTypography.captionSemibold)
            .foregroundStyle(DSColors.labelTertiary)
            .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, DSInspectorMetrics.inset)
            .padding(.top, DSSpacing.xs)
            .padding(.bottom, DSSpacing.xs)
    }
}

// MARK: - Shared rows

/// The journeys design's inspector grid: a 96pt label column, 12pt short of the endpoint inspector's,
/// so a step's longer values ("Matches POST /payments") fit their column on one line.
private enum JourneyInspectorMetrics {
    static let labelColumn: CGFloat = 96
}

/// A label column beside an editable control, on the inspector's rhythm.
private struct JourneyInspectorFieldRow<Field: View>: View {
    let label: String
    let field: Field

    init(_ label: String, @ViewBuilder field: () -> Field) {
        self.label = label
        self.field = field()
    }

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: JourneyInspectorMetrics.labelColumn, alignment: .leading)
                .accessibilityHidden(true)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, DSInspectorMetrics.inset)
        .frame(minHeight: 30)
        // The design leaves 2pt between rows.
        .padding(.vertical, 1)
    }
}

/// Explanatory text, aligned with the value column.
private struct JourneyInspectorNote: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelTertiary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DSInspectorMetrics.inset + JourneyInspectorMetrics.labelColumn + DSSpacing.md)
            .padding(.trailing, DSInspectorMetrics.inset)
            .padding(.top, DSSpacing.xs)
    }
}

/// A text field that commits on Return or when it loses focus, and puts the saved value back when
/// `onCommit` refuses the draft.
private struct JourneyTextField: View {
    let value: String
    let placeholder: String
    let identifier: String
    let label: String
    var monospaced = false
    let onCommit: (String) -> Bool

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(value: String, placeholder: String, identifier: String, label: String, monospaced: Bool = false,
         onCommit: @escaping (String) -> Bool) {
        self.value = value
        self.placeholder = placeholder
        self.identifier = identifier
        self.label = label
        self.monospaced = monospaced
        self.onCommit = onCommit
        _draft = State(initialValue: value)
    }

    var body: some View {
        TextField(placeholder, text: $draft)
            .textFieldStyle(.plain)
            .font(monospaced ? DSTypography.code : DSTypography.callout)
            .focused($isFocused)
            .dsFieldChrome(isFocused: isFocused)
            .onSubmit { commit() }
            .onChange(of: isFocused) { _, focused in if !focused { commit() } }
            .onChange(of: value) { _, newValue in if !isFocused { draft = newValue } }
            .onDisappear { commit() }
            .accessibilityIdentifier(identifier)
            .accessibilityLabel(label)
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != value else { return }
        if !onCommit(trimmed) { draft = value }
    }
}

/// A whole-number field with a trailing unit, committing like ``JourneyTextField``.
private struct JourneyNumberField: View {
    let value: Int
    let unit: String?
    let identifier: String
    let label: String
    let onCommit: (Int) -> Bool

    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(value: Int, unit: String?, identifier: String, label: String, onCommit: @escaping (Int) -> Bool) {
        self.value = value
        self.unit = unit
        self.identifier = identifier
        self.label = label
        self.onCommit = onCommit
        _draft = State(initialValue: String(value))
    }

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            TextField("0", text: $draft)
                .textFieldStyle(.plain)
                .font(DSTypography.Figure.regular)
                .focused($isFocused)
                .onSubmit { commit() }
                .accessibilityIdentifier(identifier)
                .accessibilityLabel(label)
            if let unit {
                Text(unit)
                    .font(DSTypography.callout)
                    .foregroundStyle(DSColors.labelTertiary)
                    .accessibilityHidden(true)
            }
        }
        .dsFieldChrome(isFocused: isFocused)
        .onChange(of: isFocused) { _, focused in if !focused { commit() } }
        .onChange(of: value) { _, newValue in if !isFocused { draft = String(newValue) } }
        .onDisappear { commit() }
    }

    private func commit() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let number = Int(text) else {
            draft = String(value)
            return
        }
        guard number != value else { return }
        if !onCommit(number) { draft = String(value) }
    }
}
