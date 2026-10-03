import DesignSystem
import Domain
import SwiftUI

/// Scripts one journey and shows its run in the same list.
///
/// The step list is both the editor and the progress view: the run marks the current step in place.
/// Title, run controls, progress and behaviour sit above the list. Clicking a step shows it in the
/// inspector; double-clicking it opens the step sheet. Description, group and auto-advance live in
/// the inspector while no step is selected.
public struct JourneyEditorView: View {
    let model: any JourneyEditingModel

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    public init(model: any JourneyEditingModel, journey: Journey, isActive: Bool, status: JourneyStatus?) {
        self.model = model
        self.journey = journey
        self.isActive = isActive
        self.status = status
    }

    @State private var showNewStepSheet = false
    @State private var showCaptureSheet = false

    public var body: some View {
        editorStack
            // `.contain` keeps descendants such as `journeyEditor.name` and `journeyStep-n`
            // addressable when the centre pane names this container.
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showNewStepSheet) {
                JourneyStepSheet(step: nil, backends: model.currentProject?.serverConfiguration.listeners ?? [],
                    globalDelayMs: model.serverConfiguration.globalDelayMs,
                    endpoints: model.currentProject?.endpoints ?? []) { spec in
                    model.addJourneyStep(journeyID: journey.id, spec: spec, at: nil)
                }
            }
            .sheet(item: editingStep) { step in
                JourneyStepSheet(
                    step: step,
                    stepNumber: (journey.steps.firstIndex { $0.id == step.id } ?? 0) + 1,
                    backends: model.currentProject?.serverConfiguration.listeners ?? [],
                    globalDelayMs: model.serverConfiguration.globalDelayMs,
                    endpoints: model.currentProject?.endpoints ?? [],
                    onCommit: { spec in
                        model.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
                    },
                    onRemove: {
                        model.removeJourneyStep(journeyID: journey.id, stepID: step.id)
                    }
                )
            }
            .sheet(isPresented: $showCaptureSheet) {
                CaptureFromLogSheet(journeyName: journey.name, logs: model.requestLogs) { logs in
                    model.addJourneySteps(journeyID: journey.id, capturing: logs)
                }
            }
    }

    /// Everything scrolls as one: the title, run and behaviour, then the steps.
    ///
    /// This used to be two scroll views stacked — the overview at its natural height above a step
    /// list that kept a two-step minimum. In a pane shortened by the request log the overview's
    /// scroll view was cut wherever its share ended, so a row of controls showed as a two-point
    /// sliver above "Steps", and each half carried its own scroller. One list has one scroller and
    /// clips nothing it cannot scroll to. It is a list with or without steps: a plain `ScrollView`
    /// took its content's minimum width, so a pane narrower than the behaviour row was drawn under
    /// the inspector, with "Add step" beneath the scroller. A list fits the pane and clips instead.
    ///
    /// Wrapped so the list keeps its own identifier: as the pane's outermost view it took the
    /// centre pane's name instead, and the steps lost the container that tests and VoiceOver use.
    private var editorStack: some View {
        VStack(spacing: 0) {
            stepList
        }
    }

    /// Title, run, behaviour and the Steps header: the part above the steps.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: DSSpacing.lg) {
                header
                JourneyRunProgress(model: model, journey: journey, isActive: isActive, status: status)
                behaviorRow
            }
            .padding(.top, DSSpacing.xl)
            .padding(.horizontal, Self.horizontalInset)
            .padding(.bottom, DSSpacing.lg)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("journeyEditor.settings")

            DSDivider(identifier: "journeyEditor.run")
                .padding(.horizontal, Self.horizontalInset)
            stepsHeader
                // The list's old top margin, now that the header is inside the list.
                .padding(.bottom, DSSpacing.sm)
        }
    }

    /// The editor's side inset: the same 20pt as the endpoint editor and the request detail, so
    /// switching tabs does not move the content's edge.
    static let horizontalInset: CGFloat = DSSpacing.xl

    /// Binding shim so a step can be presented as a sheet item by id. The id lives in the window's
    /// presentation state, so the inspector's "Edit step…" opens the same sheet.
    private var editingStep: Binding<JourneyStep?> {
        Binding(
            get: { journey.steps.first { $0.id == model.editingJourneyStepID } },
            set: { model.editingJourneyStepID = $0?.id }
        )
    }

    // MARK: - Header

    /// Title and description on the left, the run's state and controls on the right. A narrow pane
    /// keeps the controls beside the title as glyphs before it gives up and stacks them.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                titleBlock
                runCluster(showsTitles: true)
            }
            HStack(alignment: .top, spacing: DSSpacing.md) {
                titleBlock
                runCluster(showsTitles: false)
            }
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                titleBlock
                runCluster(showsTitles: false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.header")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            Text(journey.name)
                .font(DSTypography.title)
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
                    .help(summary)
                    .accessibilityIdentifier("journeyEditor.summary")
            }
        }
        // A modest ideal width lets a long name wrap beside the run controls instead of pushing
        // them below it.
        .frame(minWidth: 160, idealWidth: 200, maxWidth: .infinity, alignment: .leading)
    }

    /// The "Active" badge, then Restart and Next step; Activate alone while the journey is inactive.
    private func runCluster(showsTitles: Bool) -> some View {
        HStack(spacing: DSSpacing.sm) {
            if isActive {
                activeState
            }
            JourneyRunControls(model: model, journey: journey, isActive: isActive, status: status,
                               showsTitles: showsTitles)
        }
        .fixedSize()
    }

    /// "Active" while the server runs, "Selected" when it will apply to the next run. The badge is
    /// also the way out of the run, so the header stays the design's badge and two buttons: on hover
    /// it reads "Deactivate", and a click hands the endpoints back.
    private var activeState: some View {
        JourneyActiveBadge(isServing: model.serverState.runningPort != nil) {
            model.activateJourney(id: nil)
        }
        // Centred on the 24pt buttons beside it.
        .frame(height: DSControlHeight.regular)
    }

    // MARK: - Behaviour

    /// Order, unscripted requests and the end of the run: three labelled pop-up menus on one row,
    /// wrapping onto a second row only when the pane is too narrow for three.
    private var behaviorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.xl) {
                behaviorControl("Order") { matchModePicker.frame(width: Self.wideMenuWidth) }
                behaviorControl("Unscripted requests") { unmatchedPicker.frame(width: Self.wideMenuWidth) }
                behaviorControl("At the end") { completionPicker.frame(width: Self.narrowMenuWidth) }
            }

            Grid(alignment: .leading, horizontalSpacing: DSSpacing.sm, verticalSpacing: DSSpacing.sm) {
                GridRow {
                    behaviorLabel("Order")
                    matchModePicker.frame(width: Self.wideMenuWidth)
                }
                GridRow {
                    behaviorLabel("Unscripted requests")
                    unmatchedPicker.frame(width: Self.wideMenuWidth)
                }
                GridRow {
                    behaviorLabel("At the end")
                    completionPicker.frame(width: Self.narrowMenuWidth)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.behavior")
    }

    /// The design's pop-up widths: 176pt for the two with longer choices, 140pt for the end.
    private static let wideMenuWidth: CGFloat = 176
    private static let narrowMenuWidth: CGFloat = 140

    private func behaviorControl<Control: View>(
        _ title: String,
        @ViewBuilder control: () -> Control
    ) -> some View {
        HStack(spacing: DSSpacing.sm) {
            behaviorLabel(title)
            control()
        }
    }

    private func behaviorLabel(_ title: String) -> some View {
        Text(title)
            .font(DSTypography.callout)
            .foregroundStyle(DSColors.labelSecondary)
            .lineLimit(1)
            .fixedSize()
            .accessibilityHidden(true)
    }

    // Field-style menus, as the design draws them: the choice in a quiet field with one up-and-down
    // chevron, not AppKit's bezelled pop-up button.

    private var matchModePicker: some View {
        DSMenuField(
            "Match mode",
            selection: matchModeBinding,
            options: [JourneyMatchMode.orderedPerEndpoint, .strictSequence].map { DSMenuOption(Self.title(for: $0), value: $0) },
            identifier: "journeyEditor.matchModePicker"
        )
        .help("Per endpoint: the next step for each route can answer. Strict sequence: only the current step can.")
    }

    private var completionPicker: some View {
        DSMenuField(
            "On completion",
            selection: completionBinding,
            options: [DSMenuOption("Stop", value: JourneyCompletion.stop), DSMenuOption("Restart", value: .restart)],
            identifier: "journeyEditor.completionPicker"
        )
    }

    private var unmatchedPicker: some View {
        DSMenuField(
            "Unscripted requests",
            selection: unmatchedBinding,
            options: [JourneyUnmatchedBehavior.fallThroughToEndpoints, .notFound].map {
                DSMenuOption(Self.title(for: $0), value: $0)
            },
            identifier: "journeyEditor.unmatchedPicker"
        )
    }

    /// The design's names for the behaviours, shared with the inspector.
    static func title(for mode: JourneyMatchMode) -> String {
        switch mode {
        case .orderedPerEndpoint: "Per endpoint"
        case .strictSequence: "Strict sequence"
        }
    }

    static func title(for behavior: JourneyUnmatchedBehavior) -> String {
        switch behavior {
        case .fallThroughToEndpoints: "Use endpoints"
        case .notFound: "404"
        }
    }

    private var matchModeBinding: Binding<JourneyMatchMode> {
        Binding(
            get: { journey.matchMode },
            set: { model.updateJourney(id: journey.id, spec: JourneySpec(matchMode: $0)) }
        )
    }

    private var completionBinding: Binding<JourneyCompletion> {
        Binding(
            get: { journey.completion },
            set: { model.updateJourney(id: journey.id, spec: JourneySpec(completion: $0)) }
        )
    }

    private var unmatchedBinding: Binding<JourneyUnmatchedBehavior> {
        Binding(
            get: { journey.unmatchedBehavior },
            set: { model.updateJourney(id: journey.id, spec: JourneySpec(unmatchedBehavior: $0)) }
        )
    }

    // MARK: - Steps

    private var stepsHeader: some View {
        HStack(spacing: DSSpacing.sm) {
            Text("Steps")
                .font(DSTypography.bodySemibold)
                .foregroundStyle(DSColors.labelPrimary)
                .accessibilityAddTraits(.isHeader)
            Text("\(journey.steps.count)")
                .font(DSTypography.callout)
                .monospacedDigit()
                .foregroundStyle(DSColors.labelTertiary)
                .accessibilityHidden(true)
            Spacer(minLength: DSSpacing.sm)
            quietButton("Capture from log", systemImage: "text.alignleft") {
                showCaptureSheet = true
            }
            .help("Add steps from requests the server has answered")
            .accessibilityIdentifier("journeyEditor.captureFromLogButton")
            .accessibilityLabel("Capture from log")
            quietButton("Add step", systemImage: "plus") {
                showNewStepSheet = true
            }
            .help("Add a step to the end of this journey")
            .accessibilityIdentifier("journeyEditor.addStepButton")
            .accessibilityLabel("Add step")
        }
        .padding(.horizontal, Self.horizontalInset)
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.stepsHeader")
    }

    /// A borderless secondary-label action, as the design draws the Steps header's two.
    private func quietButton(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                    .font(.system(size: DSGlyph.field, weight: .medium))
                    .accessibilityHidden(true)
                Text(title)
                    .font(DSTypography.callout)
            }
            .foregroundStyle(DSColors.labelSecondary)
            .padding(.horizontal, 6)
            .frame(height: DSControlHeight.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
    }

    private var stepList: some View {
        List {
            // The overview rides in the list as its first row, so it scrolls with the steps. It
            // sits outside the `ForEach` that carries `onMove`, so it can be neither dragged nor
            // dropped onto.
            overview
                .listRowInsets(EdgeInsets())
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if journey.steps.isEmpty {
                DSEmptyState(
                    heading: "No steps yet",
                    message: "Add the requests this flow makes, in order. The same route can appear more "
                        + "than once \u{2014} that is how a call fails and then succeeds.",
                    identifier: "journeyEditor.steps"
                )
                .padding(.vertical, DSSpacing.xxl)
                .listRowInsets(EdgeInsets(top: 0, leading: Self.horizontalInset, bottom: 0, trailing: Self.horizontalInset))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            ForEach(Array(journey.steps.enumerated()), id: \.element.id) { index, step in
                JourneyStepRow(
                    step: step,
                    index: index,
                    progress: status?.steps.first { $0.id == step.id },
                    isSelected: model.selectedJourneyStepID == step.id
                )
                .contentShape(Rectangle())
                // One click shows the step in the inspector; a second opens the sheet, as a
                // double-click opens a file from Finder's selection.
                .onTapGesture(count: 2) {
                    model.selectedJourneyStepID = step.id
                    model.editingJourneyStepID = step.id
                }
                .onTapGesture {
                    model.selectedJourneyStepID = model.selectedJourneyStepID == step.id ? nil : step.id
                }
                // A tap gesture carries no trait, so restore the button trait for VoiceOver.
                .accessibilityAddTraits(.isButton)
                .accessibilityAction(named: "Edit step") { model.editingJourneyStepID = step.id }
                .listRowInsets(EdgeInsets(top: 1, leading: Self.horizontalInset, bottom: 1, trailing: Self.horizontalInset))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .contextMenu { stepContextMenu(step: step, index: index) }
            }
            .onMove { source, destination in
                // SwiftUI reports the destination as an insertion index.
                guard let from = source.first else { return }
                let step = journey.steps[from]
                let target = destination > from ? destination - 1 : destination
                model.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: target)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, DSRowHeight.step)
        // No side margin of the list's own: the overview row and the steps set their insets, so
        // the editor's content starts on the same 20pt line as the endpoint editor's.
        .contentMargins(.horizontal, 0, for: .scrollContent)
        .contentMargins(.bottom, DSSpacing.sm, for: .scrollContent)
        // `.contain` before the identifier so rows keep their own `journeyStep-n` names.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.stepList")
    }

    @ViewBuilder
    private func stepContextMenu(step: JourneyStep, index: Int) -> some View {
        JourneyStepMenuItems(model: model, journey: journey, step: step, index: index) {
            model.editingJourneyStepID = step.id
        }
    }
}

/// Edit, move and remove: the step's actions, shared by the row's context menu and the inspector's
/// "…" menu so the two can never offer different things.
struct JourneyStepMenuItems: View {
    let model: any JourneyEditingModel

    let journey: Journey
    let step: JourneyStep
    let index: Int
    let onEdit: () -> Void

    var body: some View {
        Button(action: onEdit) {
            Label("Edit step\u{2026}", systemImage: "pencil")
        }
        .accessibilityIdentifier("journeyEditor.step.contextMenu.edit")

        if index > 0 {
            Button {
                model.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index - 1)
            } label: {
                Label("Move up", systemImage: "arrow.up")
            }
            .accessibilityIdentifier("journeyEditor.step.contextMenu.moveUp")
        }
        if index < journey.steps.count - 1 {
            Button {
                model.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index + 1)
            } label: {
                Label("Move down", systemImage: "arrow.down")
            }
            .accessibilityIdentifier("journeyEditor.step.contextMenu.moveDown")
        }

        Divider()

        Button(role: .destructive) {
            if model.selectedJourneyStepID == step.id { model.selectedJourneyStepID = nil }
            model.removeJourneyStep(journeyID: journey.id, stepID: step.id)
        } label: {
            Label("Remove step", systemImage: "trash")
        }
        .accessibilityIdentifier("journeyEditor.step.contextMenu.remove")
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
