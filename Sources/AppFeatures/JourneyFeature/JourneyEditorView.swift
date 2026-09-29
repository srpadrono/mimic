import DesignSystem
import Domain
import SwiftUI

/// Scripts one journey and shows its run in the same list.
///
/// The step list is both the editor and the progress view: the run marks the current step in place.
/// Title, run controls, progress and behaviour sit above the list; description and group stay behind
/// a disclosure so the steps remain primary in a short pane.
struct JourneyEditorView: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    @State private var editingStepID: UUID?
    @State private var showNewStepSheet = false
    @State private var settingsExpanded = false
    @State private var overviewContentHeight: CGFloat = .infinity

    /// Two steps and the list's margins: the least of the list a short pane keeps on screen.
    static let minimumStepListHeight: CGFloat = DSRowHeight.step * 2 + DSSpacing.sm * 2 + DSSpacing.xs

    /// The scroll anchor on the disclosed details.
    private static let detailsAnchor = "journeyEditor.details"

    var body: some View {
        ScrollViewReader { overview in
            editorStack
                // Disclosing the details reveals them. In a short pane the overview scroll view is
                // already at its limit, so the details open below its visible edge, where a click
                // on the group field lands on the steps instead. Deferred a turn so the details are
                // laid out before the scroll view is asked to reach them; no animation, so Reduce
                // Motion has nothing to honour.
                .onChange(of: settingsExpanded) { _, expanded in
                    guard expanded else { return }
                    Task { @MainActor in
                        // Top, and the scroll view clamps: the whole of the details when they fit,
                        // the description first when they do not.
                        overview.scrollTo(Self.detailsAnchor, anchor: .top)
                    }
                }
        }
        // `.contain` keeps descendants such as `journeyEditor.name` and `journeyStep-n` addressable
        // when the centre pane names this container.
        .accessibilityElement(children: .contain)
        .onChange(of: journey.id) { _, _ in settingsExpanded = false }
        .sheet(isPresented: $showNewStepSheet) {
            JourneyStepSheet(step: nil, backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                globalDelayMs: appState.serverConfiguration.globalDelayMs) { spec in
                appState.addJourneyStep(journeyID: journey.id, spec: spec)
            }
        }
        .sheet(item: editingStep) { step in
            JourneyStepSheet(
                step: step,
                backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                globalDelayMs: appState.serverConfiguration.globalDelayMs,
                onCommit: { spec in
                    appState.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
                },
                onRemove: {
                    appState.removeJourneyStep(journeyID: journey.id, stepID: step.id)
                }
            )
        }
    }

    private var editorStack: some View {
        VStack(spacing: 0) {
            // Title, run, behaviour and — when disclosed — the details, in one scroll view that
            // takes its natural height in a tall pane and gives way in a short one. The steps are
            // what the editor is for, so they keep `minimumStepListHeight` whatever the pane: a
            // narrow window stacks the header and the behaviour grid, and without this the list was
            // laid out at zero height with every step in the tree and none of them clickable.
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    VStack(alignment: .leading, spacing: DSSpacing.lg) {
                        header
                        JourneyRunProgress(journey: journey, isActive: isActive, status: status)
                        behaviorRow
                    }
                    .padding(.top, DSSpacing.xl)
                    .padding(.horizontal, DSSpacing.xxl)
                    .padding(.bottom, settingsExpanded ? DSSpacing.md : DSSpacing.lg)

                    if settingsExpanded {
                        settingsContent
                            .id(Self.detailsAnchor)
                    }
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height in
                    overviewContentHeight = height
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(minHeight: 0, maxHeight: overviewContentHeight)
            // Offered everything the step list's minimum leaves, before the list takes the rest.
            .layoutPriority(1)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("journeyEditor.settingsScroll")

            DSDivider(identifier: "journeyEditor.run")
                .padding(.horizontal, DSSpacing.xxl)
            stepsHeader
            stepList
                .frame(minHeight: Self.minimumStepListHeight, maxHeight: .infinity)
        }
    }

    /// Binding shim so a step can be presented as a sheet item by id.
    private var editingStep: Binding<JourneyStep?> {
        Binding(
            get: { journey.steps.first { $0.id == editingStepID } },
            set: { editingStepID = $0?.id }
        )
    }

    // MARK: - Header

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: DSSpacing.md) {
                titleBlock
                runCluster
            }
            VStack(alignment: .leading, spacing: DSSpacing.md) {
                titleBlock
                runCluster
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

    /// The state badge and the run controls, in the first arrangement that fits: one row; the
    /// badge above the titled controls; the badge above symbol-only controls. A fixed-size row wider
    /// than a narrow pane is drawn past the pane's edge, where the pointer cannot reach it — that
    /// was Deactivate, beside Restart, Next step and the badge in a 1024pt window.
    private var runCluster: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.sm) {
                if isActive {
                    activeState
                }
                JourneyRunControls(journey: journey, isActive: isActive, status: status)
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                if isActive {
                    activeState
                }
                JourneyRunControls(journey: journey, isActive: isActive, status: status)
            }
            .fixedSize()

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                if isActive {
                    activeState
                }
                JourneyRunControls(journey: journey, isActive: isActive, status: status, showsTitles: false)
            }
            .fixedSize()
        }
    }

    /// "Active" while the server runs, "Selected" when it will apply to the next run.
    private var activeState: some View {
        let title = appState.serverState.runningPort == nil ? "Selected" : "Active"
        let tint = appState.serverState.runningPort == nil ? DSColors.labelSecondary : DSColors.success
        return HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(title)
                .font(DSTypography.caption.weight(.medium))
                .accessibilityIdentifier("journeyEditor.activeBadge")
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .frame(height: 18)
        .overlay {
            RoundedRectangle(cornerRadius: DSCornerRadius.card)
                .strokeBorder(tint, lineWidth: DSStroke.hairline)
        }
    }

    // MARK: - Behaviour

    /// The run-time options, inline so they are visible while reading the steps. One row when it
    /// fits, a two-column grid when it does not.
    private var behaviorRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: DSSpacing.xl) {
                behaviorControl("Order") { matchModePicker }
                behaviorControl("Unscripted requests") { unmatchedPicker }
                behaviorControl("At the end") { completionPicker }
                autoAdvanceToggle
                Spacer(minLength: DSSpacing.sm)
                settingsDisclosure
            }

            VStack(alignment: .leading, spacing: DSSpacing.sm) {
                Grid(alignment: .leading, horizontalSpacing: DSSpacing.lg, verticalSpacing: DSSpacing.sm) {
                    GridRow {
                        behaviorLabel("Order")
                        matchModePicker
                    }
                    GridRow {
                        behaviorLabel("Unscripted requests")
                        unmatchedPicker
                    }
                    GridRow {
                        behaviorLabel("At the end")
                        completionPicker
                    }
                }
                HStack(spacing: DSSpacing.md) {
                    autoAdvanceToggle
                    Spacer(minLength: DSSpacing.sm)
                    settingsDisclosure
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

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

    private var matchModePicker: some View {
        Picker("Match", selection: matchModeBinding) {
            Text("Ordered per route").tag(JourneyMatchMode.orderedPerEndpoint)
            Text("Strict sequence").tag(JourneyMatchMode.strictSequence)
        }
        .pickerStyle(.menu)
        .labelsHidden()
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
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("journeyEditor.completionPicker")
        .accessibilityLabel("On completion")
    }

    private var unmatchedPicker: some View {
        Picker("Unscripted", selection: unmatchedBinding) {
            Text("Use endpoints").tag(JourneyUnmatchedBehavior.fallThroughToEndpoints)
            Text("404").tag(JourneyUnmatchedBehavior.notFound)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .accessibilityIdentifier("journeyEditor.unmatchedPicker")
        .accessibilityLabel("Unscripted requests")
    }

    private var autoAdvanceToggle: some View {
        Toggle("Auto-advance", isOn: autoAdvanceBinding)
            .toggleStyle(.checkbox)
            .font(DSTypography.callout)
            .controlSize(.small)
            .fixedSize()
            .accessibilityIdentifier("journeyEditor.autoAdvanceToggle")
            .accessibilityLabel("Advance automatically")
    }

    private var settingsDisclosure: some View {
        Button {
            settingsExpanded.toggle()
        } label: {
            HStack(spacing: DSSpacing.xs) {
                Text("Details")
                    .font(DSTypography.callout)
                Image(systemName: "chevron.down")
                    .font(.system(size: DSGlyph.minimum, weight: .semibold))
                    .rotationEffect(.degrees(settingsExpanded ? 0 : -90))
                    .accessibilityHidden(true)
            }
            .foregroundStyle(DSColors.labelSecondary)
            .padding(.horizontal, 6)
            .frame(height: DSControlHeight.regular)
            .contentShape(Rectangle())
        }
        .buttonStyle(.dsPlain)
        .fixedSize()
        .help("Description and group")
        .accessibilityIdentifier("journeyEditor.settingsDisclosure")
        .accessibilityLabel("Journey settings")
        .accessibilityValue(settingsExpanded ? "Expanded" : "Collapsed")
    }

    private var settingsContent: some View {
        VStack(alignment: .leading, spacing: DSSpacing.sm) {
            JourneySummaryField(journey: journey).id(journey.id)
            JourneyGroupField(journey: journey).id(journey.id)
        }
        .padding(.horizontal, DSSpacing.xxl)
        .padding(.bottom, DSSpacing.lg)
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
            Button {
                showNewStepSheet = true
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: "plus")
                        .font(.system(size: DSGlyph.field, weight: .medium))
                        .accessibilityHidden(true)
                    Text("Add step")
                        .font(DSTypography.callout)
                }
                .foregroundStyle(DSColors.labelSecondary)
                .padding(.horizontal, 6)
                .frame(height: DSControlHeight.regular)
                .contentShape(Rectangle())
            }
            .buttonStyle(.dsPlain)
            .help("Add a step to the end of this journey")
            .accessibilityIdentifier("journeyEditor.addStepButton")
            .accessibilityLabel("Add step")
        }
        .padding(.horizontal, DSSpacing.xxl)
        .padding(.top, DSSpacing.lg)
        .padding(.bottom, DSSpacing.xs)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeyEditor.stepsHeader")
    }

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
                    // A tap gesture carries no trait, so restore the button trait for VoiceOver.
                    .accessibilityAddTraits(.isButton)
                    .listRowInsets(EdgeInsets(top: 1, leading: DSSpacing.lg, bottom: 1, trailing: DSSpacing.lg))
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .contextMenu { stepContextMenu(step: step, index: index) }
                }
                .onMove { source, destination in
                    // SwiftUI reports the destination as an insertion index.
                    guard let from = source.first else { return }
                    let step = journey.steps[from]
                    let target = destination > from ? destination - 1 : destination
                    appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: target)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .environment(\.defaultMinListRowHeight, DSRowHeight.step)
            .contentMargins(.vertical, DSSpacing.sm, for: .scrollContent)
            // `.contain` before the identifier so rows keep their own `journeyStep-n` names.
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("journeyEditor.stepList")
        }
    }

    @ViewBuilder
    private func stepContextMenu(step: JourneyStep, index: Int) -> some View {
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

/// One label/field row in the details disclosure, on the inspector's 88pt label column.
private struct JourneyDetailRow<Field: View>: View {
    let label: String
    @ViewBuilder let field: Field

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            Text(label)
                .font(DSTypography.callout)
                .foregroundStyle(DSColors.labelSecondary)
                .lineLimit(1)
                .frame(width: DSLayout.inspectorLabelWidth, alignment: .leading)
                .accessibilityHidden(true)
            field
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct JourneySummaryField: View {
    @Environment(AppState.self) private var appState
    let journey: Journey
    @State private var draft: String
    @FocusState private var isFocused: Bool

    init(journey: Journey) {
        self.journey = journey
        _draft = State(initialValue: journey.summary ?? "")
    }

    var body: some View {
        JourneyDetailRow(label: "Description") {
            TextField("What this journey tests", text: $draft)
                .textFieldStyle(.plain)
                .font(DSTypography.body)
                .focused($isFocused)
                .dsFieldChrome(isFocused: isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .accessibilityIdentifier("journeyEditor.summaryField")
                .accessibilityLabel("Journey description")
        }
        .onChange(of: journey.summary) { _, value in
            if !isFocused { draft = value ?? "" }
        }
        .onDisappear { commit() }
    }

    private func commit() {
        let summary = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard summary != (journey.summary ?? ""), appState.journeys.contains(where: { $0.id == journey.id }) else { return }
        appState.updateJourney(id: journey.id, spec: JourneySpec(summary: summary))
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
        JourneyDetailRow(label: "Group") {
            TextField("None", text: $draft)
                .textFieldStyle(.plain)
                .font(DSTypography.body)
                .focused($isFocused)
                .dsFieldChrome(isFocused: isFocused)
                .onSubmit { commit() }
                .onChange(of: isFocused) { _, focused in if !focused { commit() } }
                .accessibilityIdentifier("journeyEditor.groupTag")
                .accessibilityLabel("Journey group")
                .help("Journeys with the same group appear together. Clear to leave ungrouped.")
        }
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
