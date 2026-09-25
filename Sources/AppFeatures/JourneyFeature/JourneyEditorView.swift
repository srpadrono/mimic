import DesignSystem
import Domain
import SwiftUI

/// Scripts one journey and shows its run in the same list.
///
/// The step list is the editor *and* the progress view. A journey is defined by its order, so the
/// order is what you see; the run marks the current step in place rather than in a second panel you
/// would have to correlate by eye.
///
/// It renders at two very different widths — the journeys window's detail column, and the main
/// window's centre pane, which is a few hundred points narrower with both drawers open. The title
/// can wrap, while the settings stay collapsed until requested so the steps remain primary.
struct JourneyEditorView: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    @State private var editingStepID: UUID?
    @State private var showNewStepSheet = false
    @State private var settingsExpanded = false

    var body: some View {
        VStack(spacing: 0) {
            header
            JourneyRunControls(journey: journey, isActive: isActive, status: status)
                .fixedSize(horizontal: false, vertical: true)
            DSDivider(identifier: "journeyEditor.run")
            settingsDisclosure
            if settingsExpanded { settingsContent }
            DSSectionHeader("Steps", identifier: "journeyEditor.stepsHeader") {
                DSButton("Add step\u{2026}", variant: .secondary, size: .small,
                         identifier: "journeyEditor.addStep") {
                    showNewStepSheet = true
                }
                .accessibilityIdentifier("journeyEditor.addStepButton")
                .accessibilityLabel("Add step")
            }
            stepList
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        // The centre pane tags this view with an identifier of its own, and a bare
        // `.accessibilityIdentifier` on a container renames every descendant to match it — which
        // would take `journeyEditor.name`, `journeyEditor.addStepButton` and every `journeyStep-n`
        // out of the tree. Declaring the container here keeps them addressable whoever wraps it.
        .accessibilityElement(children: .contain)
        .onChange(of: journey.id) { _, _ in settingsExpanded = false }
        .sheet(isPresented: $showNewStepSheet) {
            JourneyStepSheet(step: nil, backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                globalDelayMs: appState.serverConfiguration.globalDelayMs) { spec in
                appState.addJourneyStep(journeyID: journey.id, spec: spec)
            }
        }
        .sheet(item: editingStep) { step in
            JourneyStepSheet(step: step, backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                globalDelayMs: appState.serverConfiguration.globalDelayMs) { spec in
                appState.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
            }
        }
    }

    @ViewBuilder
    private var settingsContent: some View {
        JourneyGroupField(journey: journey).id(journey.id)
        DSSectionHeader("Behavior", identifier: "journeyEditor.behavior")
        behaviorControls
            .fixedSize(horizontal: false, vertical: true)
        DSDivider(style: .standard, identifier: "journeyEditor.behavior")
    }

    private var settingsDisclosure: some View {
        Button {
            settingsExpanded.toggle()
        } label: {
            HStack(spacing: DSSpacing.sm) {
                Text("Journey settings")
                    .font(DSTypography.controlLabel)
                Spacer(minLength: DSSpacing.xs)
                Text("\(journey.groupTag ?? "Ungrouped") · \(journey.matchMode == .orderedPerEndpoint ? "Ordered per route" : "Strict sequence")")
                    .font(DSTypography.meta)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(DSColors.labelSecondary)
                Image(systemName: settingsExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: DSGlyph.indicator, weight: .semibold))
                    .frame(width: DSGlyph.control)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DSColors.labelPrimary)
            .padding(.horizontal, DSSpacing.md)
            .frame(minHeight: DSBarHeight.controlRow)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .background(DSColors.band)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
        }
        .accessibilityIdentifier("journeyEditor.settingsDisclosure")
        .accessibilityLabel("Journey settings")
        .accessibilityValue(settingsExpanded ? "Expanded" : "Collapsed")
    }

    /// Binding shim so a step can be presented as a sheet item by id.
    private var editingStep: Binding<JourneyStep?> {
        Binding(
            get: { journey.steps.first { $0.id == editingStepID } },
            set: { editingStepID = $0?.id }
        )
    }

    // MARK: - Header

    /// Give the script a readable identity; the step action belongs with the Steps heading below.
    private var header: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            HStack {
                Text("Journey")
                    .font(DSTypography.labelMedium)
                    .foregroundStyle(DSColors.labelSecondary)
                Spacer(minLength: 0)
                if isActive {
                    DSStateBadge(appState.serverState.runningPort == nil ? "Selected" : "Active",
                                 tone: .accent, identifier: "journeyEditor.activeBadge")
                }
            }
            Text(journey.name)
                .font(DSTypography.heading)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(journey.name)
                .accessibilityIdentifier("journeyEditor.name")
            if let summary = journey.summary, !summary.isEmpty {
                Text(summary)
                    .font(DSTypography.body)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(2)
                    .lineSpacing(DSSpacing.xxs)
                    .help(summary)
                    .accessibilityIdentifier("journeyEditor.summary")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSSpacing.lg)
        .padding(.vertical, DSSpacing.md)
        .background(DSColors.secondary)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DSColors.separator).frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.header")
    }

    // MARK: - Behaviour

    /// The four options that change how a journey behaves at run time. Inline rather than behind a
    /// settings sheet, because they change what a test observes and should be visible while reading it.
    ///
    /// One row when there is room for one, two when there is not. The row used to be four pickers
    /// capped at 200, 170 and 180 points, which needs about 700 points of window — at centre-pane
    /// width the labels themselves truncated, and "On comp…" is not a label.
    @ViewBuilder
    private var behaviorControls: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.md) {
                matchModePicker
                completionPicker
                unmatchedPicker
                autoAdvanceToggle
            }

            Grid(alignment: .leading, horizontalSpacing: DSSpacing.md, verticalSpacing: DSSpacing.sm) {
                GridRow {
                    matchModePicker
                    completionPicker
                }
                GridRow {
                    unmatchedPicker
                    autoAdvanceToggle
                }
            }

            // Labels move above their controls when two inline label/value pairs no longer fit.
            // This preserves the same four controls without making the entire editor overflow or
            // consuming four rows of the height needed by the steps below.
            Grid(alignment: .leading, horizontalSpacing: DSSpacing.md, verticalSpacing: DSSpacing.sm) {
                GridRow {
                    compactBehaviorControl("Match") { matchModePicker.labelsHidden() }
                    compactBehaviorControl("On completion") { completionPicker.labelsHidden() }
                }
                GridRow {
                    compactBehaviorControl("Unscripted") { unmatchedPicker.labelsHidden() }
                    autoAdvanceToggle
                }
            }
        }
        .font(DSTypography.label)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, DSSpacing.md)
        .padding(.vertical, DSSpacing.sm)
        // The control-row rung, as a floor. On one line this already measures exactly 32, and stating
        // it stops the row drifting under the rung if AppKit ever changes what a small popup measures.
        // It has to be a floor and not a height because of the `ViewThatFits` above: the folded
        // candidate is two rows of pickers and needs about 56, and a fixed 32 would hold the container
        // at one row's worth of space while the grid drew straight over the step list below it.
        .frame(minHeight: DSBarHeight.controlRow)
    }

    private func compactBehaviorControl<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(title)
                .font(DSTypography.meta)
                .foregroundStyle(DSColors.labelSecondary)
                .accessibilityHidden(true)
            control()
        }
    }

    /// `.small` and `.fixedSize()` on all four: one height down the row, and a control that reports
    /// the width it actually needs, which is what lets `ViewThatFits` know when to fold.
    private var matchModePicker: some View {
        Picker("Match", selection: matchModeBinding) {
            Text("Ordered per route").tag(JourneyMatchMode.orderedPerEndpoint)
            Text("Strict sequence").tag(JourneyMatchMode.strictSequence)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("journeyEditor.matchModePicker")
        .accessibilityLabel("Match mode")
    }

    private var completionPicker: some View {
        Picker("On completion", selection: completionBinding) {
            Text("Stop").tag(JourneyCompletion.stop)
            Text("Restart").tag(JourneyCompletion.restart)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("journeyEditor.completionPicker")
        .accessibilityLabel("On completion")
    }

    private var unmatchedPicker: some View {
        Picker("Unscripted", selection: unmatchedBinding) {
            Text("Fall through").tag(JourneyUnmatchedBehavior.fallThroughToEndpoints)
            Text("404").tag(JourneyUnmatchedBehavior.notFound)
        }
        .pickerStyle(.menu)
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("journeyEditor.unmatchedPicker")
        .accessibilityLabel("Unscripted requests")
    }

    private var autoAdvanceToggle: some View {
        Toggle("Auto-advance", isOn: autoAdvanceBinding)
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("journeyEditor.autoAdvanceToggle")
            .accessibilityLabel("Advance automatically")
    }

    private var matchModeBinding: Binding<JourneyMatchMode> {
        Binding(
            get: { journey.matchMode },
            set: { appState.updateJourney(id: journey.id, spec: JourneySpec(matchMode: $0)) }
        )
    }

    private var completionBinding: Binding<JourneyCompletion> {
        Binding(
            get: { journey.completion },
            set: { appState.updateJourney(id: journey.id, spec: JourneySpec(completion: $0)) }
        )
    }

    private var unmatchedBinding: Binding<JourneyUnmatchedBehavior> {
        Binding(
            get: { journey.unmatchedBehavior },
            set: { appState.updateJourney(id: journey.id, spec: JourneySpec(unmatchedBehavior: $0)) }
        )
    }

    private var autoAdvanceBinding: Binding<Bool> {
        Binding(
            get: { journey.autoAdvance },
            set: { appState.updateJourney(id: journey.id, spec: JourneySpec(autoAdvance: $0)) }
        )
    }

    // MARK: - Steps

    @ViewBuilder
    private var stepList: some View {
        if journey.steps.isEmpty {
            DSEmptyState(
                heading: "No steps yet",
                message: "Add the requests this flow makes, in order. The same route can appear more "
                    + "than once — that is how a call fails and then succeeds.",
                identifier: "journeyEditor.steps"
            )
        } else {
            List {
                ForEach(Array(journey.steps.enumerated()), id: \.element.id) { index, step in
                    JourneyStepRow(
                        step: step,
                        index: index,
                        progress: status?.steps.first { $0.id == step.id }
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { editingStepID = step.id }
                    // A tap gesture carries no trait, so the row that opens the step editor was
                    // announced as static text with no hint that it could be pressed.
                    // `RequestLogTableRow` and `EndpointTrafficRow` restore it the same way; this row
                    // and the inspector's scenario row were the two that did not.
                    .accessibilityAddTraits(.isButton)
                    .contextMenu {
                        Button {
                            editingStepID = step.id
                        } label: {
                            Label("Edit step\u{2026}", systemImage: "pencil")
                        }
                        .accessibilityIdentifier("journeyEditor.step.contextMenu.edit")

                        if index > 0 {
                            Button {
                                appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index - 1)
                            } label: {
                                Label("Move up", systemImage: "arrow.up")
                            }
                            .accessibilityIdentifier("journeyEditor.step.contextMenu.moveUp")
                        }
                        if index < journey.steps.count - 1 {
                            Button {
                                appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index + 1)
                            } label: {
                                Label("Move down", systemImage: "arrow.down")
                            }
                            .accessibilityIdentifier("journeyEditor.step.contextMenu.moveDown")
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.removeJourneyStep(journeyID: journey.id, stepID: step.id)
                        } label: {
                            Label("Remove step", systemImage: "trash")
                        }
                        .accessibilityIdentifier("journeyEditor.step.contextMenu.remove")
                    }
                }
                .onMove { source, destination in
                    // A single drag is the natural way to reorder a sequence; SwiftUI reports the
                    // destination as an insertion index, which is what the command expects.
                    guard let from = source.first else { return }
                    let step = journey.steps[from]
                    let target = destination > from ? destination - 1 : destination
                    appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: target)
                }
            }
            .listStyle(.inset)
            // `.contain` before the identifier: naming a container without it renames every row to
            // match, and the rows are what `journeyStep-n` addresses.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("journeyEditor.stepList")
        }
    }
}

/// Presents an optional item as a sheet. Kept local because it is only useful for editing a step
/// selected by id out of a value-typed array.
private extension View {
    func sheet<Item: Identifiable, Content: View>(
        item: Binding<Item?>,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        sheet(isPresented: Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}

private struct JourneyGroupField: View {
    @Environment(AppState.self) private var appState
    let journey: Journey
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(journey: Journey) {
        self.journey = journey
        _draft = State(initialValue: journey.groupTag ?? "")
    }

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("Group").foregroundStyle(DSColors.labelSecondary)
            TextField("None", text: $draft)
                .textFieldStyle(.plain)
                .font(DSTypography.label)
                .dsFieldWell()
                .focused($isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .accessibilityIdentifier("journeyEditor.groupTag")
                .accessibilityLabel("Journey group")
                .help("Journeys with the same group appear together. Clear to leave ungrouped.")
        }
        .font(DSTypography.label)
        .padding(.horizontal, DSSpacing.md)
        .frame(height: DSBarHeight.controlRow)
        .onChange(of: journey.groupTag) { _, value in
            if !isFocused { draft = value ?? "" }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        let group = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard group != (journey.groupTag ?? ""), appState.journeys.contains(where: { $0.id == journey.id }) else { return }
        appState.updateJourney(id: journey.id, spec: JourneySpec(groupTag: group))
    }
}
