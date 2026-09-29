import DesignSystem
import Domain
import SwiftUI

/// Scripts one journey and shows its run in the same list.
///
/// The step list is both the editor and the progress view: the run marks the current step in place.
/// Title, run controls, progress and behaviour sit above the list. Clicking a step shows it in the
/// inspector; double-clicking it opens the step sheet. Description, group and auto-advance live in
/// the inspector while no step is selected.
struct JourneyEditorView: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    @State private var showNewStepSheet = false
    @State private var showCaptureSheet = false
    @State private var overviewContentHeight: CGFloat = .infinity

    /// Two steps and the list's margins: the least of the list a short pane keeps on screen.
    static let minimumStepListHeight: CGFloat = DSRowHeight.step * 2 + DSSpacing.sm * 2 + DSSpacing.xs

    var body: some View {
        editorStack
            // `.contain` keeps descendants such as `journeyEditor.name` and `journeyStep-n`
            // addressable when the centre pane names this container.
            .accessibilityElement(children: .contain)
            .sheet(isPresented: $showNewStepSheet) {
                JourneyStepSheet(step: nil, backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                    globalDelayMs: appState.serverConfiguration.globalDelayMs,
                    endpoints: appState.currentProject?.endpoints ?? []) { spec in
                    appState.addJourneyStep(journeyID: journey.id, spec: spec)
                }
            }
            .sheet(item: editingStep) { step in
                JourneyStepSheet(
                    step: step,
                    stepNumber: (journey.steps.firstIndex { $0.id == step.id } ?? 0) + 1,
                    backends: appState.currentProject?.serverConfiguration.listeners ?? [],
                    globalDelayMs: appState.serverConfiguration.globalDelayMs,
                    endpoints: appState.currentProject?.endpoints ?? [],
                    onCommit: { spec in
                        appState.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
                    },
                    onRemove: {
                        appState.removeJourneyStep(journeyID: journey.id, stepID: step.id)
                    }
                )
            }
            .sheet(isPresented: $showCaptureSheet) {
                CaptureFromLogSheet(journeyName: journey.name, logs: appState.requestLogs) { logs in
                    appState.addJourneySteps(journeyID: journey.id, capturing: logs)
                }
            }
    }

    private var editorStack: some View {
        VStack(spacing: 0) {
            // Title, run and behaviour, in one scroll view that takes its natural height in a tall
            // pane and gives way in a short one. The steps are what the editor is for, so they keep
            // `minimumStepListHeight` whatever the pane: without it a narrow window laid the list out
            // at zero height with every step in the tree and none of them clickable.
            ScrollView {
                VStack(alignment: .leading, spacing: DSSpacing.lg) {
                    header
                    JourneyRunProgress(journey: journey, isActive: isActive, status: status)
                    behaviorRow
                }
                .padding(.top, DSSpacing.xl)
                .padding(.horizontal, DSSpacing.xxl)
                .padding(.bottom, DSSpacing.lg)
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

    /// Binding shim so a step can be presented as a sheet item by id. The id lives in the window's
    /// presentation state, so the inspector's "Edit step…" opens the same sheet.
    private var editingStep: Binding<JourneyStep?> {
        Binding(
            get: { journey.steps.first { $0.id == appState.editingJourneyStepID } },
            set: { appState.editingJourneyStepID = $0?.id }
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
            JourneyRunControls(journey: journey, isActive: isActive, status: status, showsTitles: showsTitles)
        }
        .fixedSize()
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
            Capsule()
                .strokeBorder(tint, lineWidth: DSStroke.hairline)
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

    private var matchModePicker: some View {
        Picker("Order", selection: matchModeBinding) {
            Text(JourneyEditorView.title(for: .orderedPerEndpoint)).tag(JourneyMatchMode.orderedPerEndpoint)
            Text(JourneyEditorView.title(for: .strictSequence)).tag(JourneyMatchMode.strictSequence)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .help("Per endpoint: the next step for each route can answer. Strict sequence: only the current step can.")
        .accessibilityIdentifier("journeyEditor.matchModePicker")
        .accessibilityLabel("Match mode")
    }

    private var completionPicker: some View {
        Picker("At the end", selection: completionBinding) {
            Text("Stop").tag(JourneyCompletion.stop)
            Text("Restart").tag(JourneyCompletion.restart)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("journeyEditor.completionPicker")
        .accessibilityLabel("On completion")
    }

    private var unmatchedPicker: some View {
        Picker("Unscripted requests", selection: unmatchedBinding) {
            Text(JourneyEditorView.title(for: .fallThroughToEndpoints)).tag(JourneyUnmatchedBehavior.fallThroughToEndpoints)
            Text(JourneyEditorView.title(for: .notFound)).tag(JourneyUnmatchedBehavior.notFound)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .accessibilityIdentifier("journeyEditor.unmatchedPicker")
        .accessibilityLabel("Unscripted requests")
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
        .padding(.horizontal, DSSpacing.xxl)
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

    @ViewBuilder
    private var stepList: some View {
        if journey.steps.isEmpty {
            DSEmptyState(
                heading: "No steps yet",
                message: "Add the requests this flow makes, in order. The same route can appear more "
                    + "than once \u{2014} that is how a call fails and then succeeds.",
                identifier: "journeyEditor.steps"
            )
        } else {
            List {
                ForEach(Array(journey.steps.enumerated()), id: \.element.id) { index, step in
                    JourneyStepRow(
                        step: step,
                        index: index,
                        progress: status?.steps.first { $0.id == step.id },
                        isSelected: appState.selectedJourneyStepID == step.id
                    )
                    .contentShape(Rectangle())
                    // One click shows the step in the inspector; a second opens the sheet, as a
                    // double-click opens a file from Finder's selection.
                    .onTapGesture(count: 2) {
                        appState.selectedJourneyStepID = step.id
                        appState.editingJourneyStepID = step.id
                    }
                    .onTapGesture {
                        appState.selectedJourneyStepID = appState.selectedJourneyStepID == step.id ? nil : step.id
                    }
                    // A tap gesture carries no trait, so restore the button trait for VoiceOver.
                    .accessibilityAddTraits(.isButton)
                    .accessibilityAction(named: "Edit step") { appState.editingJourneyStepID = step.id }
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
        JourneyStepMenuItems(journey: journey, step: step, index: index) {
            appState.editingJourneyStepID = step.id
        }
    }
}

/// Edit, move and remove: the step's actions, shared by the row's context menu and the inspector's
/// "…" menu so the two can never offer different things.
struct JourneyStepMenuItems: View {
    @Environment(AppState.self) private var appState

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
            if appState.selectedJourneyStepID == step.id { appState.selectedJourneyStepID = nil }
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
