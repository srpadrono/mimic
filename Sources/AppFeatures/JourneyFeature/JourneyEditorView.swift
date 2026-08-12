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
/// window's centre pane, which is a few hundred points narrower with both drawers open. So nothing
/// above the step list may assume the wide one: the header truncates rather than wraps, and the
/// behaviour controls fold from one row into two rather than shaving characters off their own labels.
struct JourneyEditorView: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    @State private var editingStepID: UUID?
    @State private var showNewStepSheet = false

    var body: some View {
        VStack(spacing: 0) {
            header
            DSSectionHeader("Behavior", identifier: "journeyEditor.behavior")
            behaviorControls
            // `.standard`, matching the rule below the run strip. The band was bracketed by a 9% rule
            // above and a 12% one below, so its two edges did not read as a pair.
            DSDivider(style: .standard, identifier: "journeyEditor.behavior")
            JourneyRunControls(journey: journey, isActive: isActive, status: status)
            DSDivider(identifier: "journeyEditor.run")
            // Allowed to compress to nothing, and that is the whole point.
            //
            // Everything above this is a fixed height — the name row carrying "Add step", the
            // behaviour controls, the run strip. The step area is not: with no steps it draws a
            // `DSEmptyState`, which is tall and, without this, refuses to give any of it back. In a
            // short window the stack then needed more room than the pane had and SwiftUI centred the
            // overflow, which pushes the *top* row out of sight under the toolbar. "Add step" was
            // drawn nowhere and could not be clicked, on CI and on any small window alike.
            //
            // Yielding here means the fixed rows keep their space and the step area takes what is
            // left, which is the order that matters: you can always scroll a list, and you cannot
            // reach a button that is not on screen.
            stepList
                .frame(minHeight: 0, maxHeight: .infinity)
        }
        .background(DSColors.dominant)
        // The centre pane tags this view with an identifier of its own, and a bare
        // `.accessibilityIdentifier` on a container renames every descendant to match it — which
        // would take `journeyEditor.name`, `journeyEditor.addStepButton` and every `journeyStep-n`
        // out of the tree. Declaring the container here keeps them addressable whoever wraps it.
        .accessibilityElement(children: .contain)
        .sheet(isPresented: $showNewStepSheet) {
            JourneyStepSheet(step: nil) { spec in
                appState.addJourneyStep(journeyID: journey.id, spec: spec)
            }
        }
        .sheet(item: editingStep) { step in
            JourneyStepSheet(step: step) { spec in
                appState.updateJourneyStep(journeyID: journey.id, stepID: step.id, spec: spec)
            }
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

    /// The editor's one row of chrome: what this journey is, whether it is answering, and the single
    /// action that belongs to the list rather than to any step in it.
    ///
    /// One row, at the same height as every panel header in the window. It used to be three stacked
    /// ones — a 20pt title, then the summary, then the behaviour controls — which spent ~90pt before
    /// the first step and, at centre-pane width, was not even a fixed height: the title had no line
    /// limit, so a long journey name wrapped and pushed everything below it down.
    @ViewBuilder
    private var header: some View {
        HStack(spacing: DSSpacing.sm) {
            // 13, matching the endpoint editor's header in the same slot at the same 30pt height.
            // This was `subheading` (14 medium) against that one's `codeLarge` (13 regular), so
            // switching navigator tabs changed the size *and* the weight of the title in the same
            // rectangle. The families still differ, and only because the content does: a route is a
            // path and reads as one, a journey has a name.
            Text(journey.name)
                .font(DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)
                // The name outranks the summary for the space that is left. Without this the two
                // compress in proportion to their ideal widths, so a one-line summary would squeeze
                // the name — the identity of the thing you are editing — down to a few characters.
                .layoutPriority(1)
                .accessibilityIdentifier("journeyEditor.name")

            if isActive {
                // The one filled pill in this view. A journey that is answering rewrites what *every*
                // endpoint returns, so it is the rare piece of state that has earned a fill — and the
                // word carries it, so the pill is not the only thing saying so.
                //
                // `.fixedSize()` is safe on this one and only this one: the string is a literal, so
                // it cannot grow the way a name or a summary can. The two variable strings either
                // side of it are the ones that have to stay compressible — see below.
                Text("Active")
                    .font(DSTypography.caption)
                    .foregroundStyle(DSColors.accentText)
                    .padding(.horizontal, DSSpacing.xs + 1)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(DSColors.accentSubtle))
                    .fixedSize()
                    .accessibilityIdentifier("journeyEditor.activeBadge")
            }

            if let summary = journey.summary, !summary.isEmpty {
                // The subtitle yields first: it is prose, and prose is the one thing in this row that
                // can afford to lose characters. Neither it nor the name is `.fixedSize()` — that is
                // what made a long string push a header's leading edge out of view.
                Text(summary)
                    .font(DSTypography.label)
                    .foregroundStyle(DSColors.labelSecondary)
                    .lineLimit(1)
                    .help(summary)
                    .accessibilityIdentifier("journeyEditor.summary")
            }

            Spacer(minLength: DSSpacing.sm)

            // `DSButton`, like the import review's header actions — the app's other worded action in
            // a 30pt header. As a bordered *system* button this drew AppKit's shape at ≈19pt beside
            // 20pt and 22pt siblings elsewhere, and picked up the system accent rather than
            // `DSColors.accent`.
            //
            // It was not, as this note used to claim, the only one: `JourneyRunControls` renders four
            // more a few lines below this header, in the same view, and they were left behind when
            // this one was moved across. They are `DSButton`s now too.
            //
            // The ellipsis is the HIG's, and the same one this view's own empty state has always
            // carried: the button opens `JourneyStepSheet` rather than adding anything, and the two
            // controls that open that identical sheet were spelling it two different ways 150 lines
            // apart. The spoken label stays plain — an ellipsis is punctuation for the eye.
            DSButton(
                "Add step\u{2026}",
                variant: .secondary,
                size: .small,
                identifier: "journeyEditor.addStep"
            ) {
                showNewStepSheet = true
            }
            .accessibilityIdentifier("journeyEditor.addStepButton")
            .accessibilityLabel("Add step")
        }
        .padding(.horizontal, DSSpacing.md)
        // The shared panel-header height, so this bar lines up with the sidebar's and the
        // inspector's across the window instead of being a private number.
        .frame(height: DSBarHeight.panelHeader)
        .background(DSColors.secondary)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: DSStroke.hairline)
        }
        .accessibilityElement(children: .contain)
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
                systemImage: "arrow.down.to.line",
                heading: "No steps yet",
                message: "Add the requests this flow makes, in order. The same route can appear more "
                    + "than once — that is how a call fails and then succeeds.",
                actionTitle: "Add step\u{2026}",
                identifier: "journeyEditor.steps",
                action: { showNewStepSheet = true }
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
                    .contextMenu {
                        Button {
                            editingStepID = step.id
                        } label: {
                            Label("Edit step\u{2026}", systemImage: "pencil")
                        }

                        if index > 0 {
                            Button {
                                appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index - 1)
                            } label: {
                                Label("Move up", systemImage: "arrow.up")
                            }
                        }
                        if index < journey.steps.count - 1 {
                            Button {
                                appState.moveJourneyStep(journeyID: journey.id, stepID: step.id, to: index + 1)
                            } label: {
                                Label("Move down", systemImage: "arrow.down")
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.removeJourneyStep(journeyID: journey.id, stepID: step.id)
                        } label: {
                            Label("Remove step", systemImage: "trash")
                        }
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
