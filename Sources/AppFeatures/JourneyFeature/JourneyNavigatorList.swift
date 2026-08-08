import DesignSystem
import Domain
import SwiftUI

/// The journeys navigator: every journey in the project, and the controls for the one that is running.
///
/// A journey rewrites what *every* endpoint returns, which makes it the most consequential thing in a
/// project — and until now it was the one thing you could not see next to your endpoints, because
/// journeys lived in a window of their own. This is the list that moves into the main window's
/// sidebar as a second navigator, the way Xcode keeps nine navigators in one panel rather than nine
/// windows. The separate window keeps working; this is the surface you reach for.
///
/// **This view carries no chrome of its own.** The navigator's `DSTabStrip` is the panel header, and
/// the selected tab already says which list you are looking at — a `DSPanelHeader` under it would be
/// a second 30pt row of chrome answering a question the strip has already answered.
///
/// The view owns no state beyond the selection binding. Every mutation leaves through a closure, so
/// the rules stay in `ProjectCommandExecutor` where the CLI and the control API can reach them too.
struct JourneyNavigatorList: View {
    let journeys: [Journey]
    /// The journey currently overriding endpoint responses, if any.
    let activeJourneyID: UUID?
    /// Live progress for the active journey, so its row can show what it has served rather than only
    /// that it is running. `nil` when nothing is active.
    var activeJourneyStatus: JourneyStatus?
    /// Progress for the active journey, e.g. "Step 2 of 5" or "Complete". Nil when none is running.
    let activeProgress: String?
    /// What the centre pane is editing. Selecting is *not* activating — see ``JourneyNavigatorRow``.
    @Binding var selectedJourneyID: UUID?
    /// Pass `nil` to deactivate whatever is running.
    let onActivate: (UUID?) -> Void
    let onAdd: () -> Void
    let onDuplicate: (UUID) -> Void
    let onDelete: (UUID) -> Void

    /// Deleting a journey takes its steps with it and there is no undo anywhere in `AppState`, so
    /// the navigator asks first — as `SidebarView`
    /// does for endpoints. The confirmation lives here rather than at the call site because the
    /// context menu that offers the action lives here.
    @State private var deleteTarget: Journey?
    let onRestart: () -> Void
    let onAdvance: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            // The banner exists only while something is overriding the endpoints, so its absence is
            // information too: no strip means your endpoints are answering for themselves.
            if let activeJourney {
                JourneyNavigatorRunStrip(
                    journeyName: activeJourney.name,
                    progress: activeProgress,
                    onRestart: onRestart,
                    onAdvance: onAdvance,
                    onDeactivate: { onActivate(nil) }
                )
            }

            if journeys.isEmpty {
                // The navigator's tab strip stays put above this, so the panel keeps its chrome and
                // its height whichever branch renders. Chrome that disappears with its content reads
                // as a rendering glitch, and it would leave this navigator a row shorter than the
                // endpoint one.
                DSEmptyState(
                    systemImage: NavigatorTab.journeys.systemImage,
                    heading: "No journeys",
                    // Points at the gallery rather than describing the feature at length, because
                    // the centre pane is now showing nine worked examples of it. Two surfaces
                    // explaining the same idea in different words is how they drift; this one names
                    // where the answer already is.
                    message: "A journey scripts an ordered sequence of responses, so one endpoint "
                        + "can fail and then succeed on the retry. Pick a template from the gallery, "
                        + "or start an empty one.",
                    actionTitle: "Add journey",
                    identifier: "journeys.empty",
                    action: onAdd
                )
            } else {
                List(selection: $selectedJourneyID) {
                    ForEach(journeys) { journey in
                        let isActive = journey.id == activeJourneyID

                        JourneyNavigatorRow(
                            journey: journey,
                            isActive: isActive,
                            status: isActive ? activeJourneyStatus : nil,
                            onToggleActivation: { onActivate(isActive ? nil : journey.id) },
                            onDuplicate: { onDuplicate(journey.id) },
                            onDelete: { deleteTarget = journey }
                        )
                        .tag(journey.id)
                    }
                }
                .listStyle(.sidebar)
                // `.contain` keeps the rows addressable by their own identifiers; a bare identifier
                // on a container renames every descendant to match it.
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("journeys.list")
            }
        }
        .alert(
            "Delete \"\(deleteTarget?.name ?? "")\"?",
            isPresented: Binding(
                get: { deleteTarget != nil },
                set: { if !$0 { deleteTarget = nil } }
            ),
            presenting: deleteTarget
        ) { journey in
            Button("Delete", role: .destructive) { onDelete(journey.id) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This removes the journey and all of its steps. This can't be undone.")
        }
    }

    /// The active journey, when it is one this list actually holds.
    private var activeJourney: Journey? {
        guard let activeJourneyID else { return nil }
        return journeys.first { $0.id == activeJourneyID }
    }
}

// MARK: - Run strip

/// The "a journey is overriding your mocks" banner, with the controls for the run.
///
/// It sits under the navigator's tab strip rather than in it because it is state, not chrome: it
/// appears only while a journey is answering. The accent wash is deliberately quiet — this has to be
/// legible every time you glance at the sidebar, which rules out anything loud enough to compete with
/// the list below it.
struct JourneyNavigatorRunStrip: View {
    let journeyName: String
    let progress: String?
    let onRestart: () -> Void
    let onAdvance: () -> Void
    let onDeactivate: () -> Void

    var body: some View {
        HStack(spacing: DSSpacing.xs) {
            VStack(alignment: .leading, spacing: 1) {
                // Medium, like every other bar title in this window. Accent at regular weight was the
                // one 11pt title here drawn lighter than the rest, and on a tinted wash that reads as
                // a bar someone forgot to finish. The colour stays: this bar is only on screen while a
                // journey is answering, and that is what the accent is saying.
                Text(journeyName)
                    .font(DSTypography.label)
                    .fontWeight(.medium)
                    .foregroundStyle(DSColors.accentText)
                    .lineLimit(1)

                if let progress {
                    Text(progress)
                        .font(DSTypography.caption)
                        .foregroundStyle(DSColors.labelSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: DSSpacing.xs)

            // One geometry for all three: `DSPanelHeaderButton` is a 22pt target around an 11pt
            // glyph wherever it appears, so these line up with the tab strip's accessory directly
            // above them instead of introducing a third button size into the same column.
            DSPanelHeaderButton(
                systemImage: "arrow.counterclockwise",
                help: "Restart journey",
                identifier: "journeys.restartButton",
                action: onRestart
            )

            DSPanelHeaderButton(
                systemImage: "forward.end",
                help: "Advance journey",
                identifier: "journeys.advanceButton",
                action: onAdvance
            )

            // Restart and advance move the run along; the next one ends it. A hairline is how that
            // difference gets said here — a red control in a strip you glance at every few seconds
            // would read as something having gone wrong rather than as the way out of a run.
            DSDivider(style: .standard, axis: .vertical, identifier: "journeys.runControls")
                .frame(height: 12)
                .padding(.horizontal, DSSpacing.xxs)
                .accessibilityHidden(true)

            // `stop.circle`, the glyph this action already wears in the row's context menu, in the
            // journeys window's context menu, and in `JourneyRunControls`. `stop.fill` made this the
            // one surface out of four that spelled "deactivate" differently.
            DSPanelHeaderButton(
                systemImage: "stop.circle",
                help: "Deactivate journey",
                identifier: "journeys.deactivateButton",
                action: onDeactivate
            )
        }
        .padding(.horizontal, DSSpacing.md)
        // Pinned for real this time. The note here already said the strip must not change height
        // when the progress line appears — but it said so over a `minHeight`, which is a floor and
        // lets the bar grow to whatever its content wants. Rendered both ways it measured 30 with no
        // progress and **36** with it, so the whole journey list still stepped down 6pt the moment a
        // run started, which is every activation: `activeProgress` is nil until the engine's cursor
        // has been read back, and that read is a `Task`.
        //
        // `controlRow` rather than `panelHeader`, and both bounds rather than one. 32 is the rung
        // `DSBarHeight` already assigns to journey run controls, and it is the smaller of the two
        // rungs that clears the 28pt the two-line stack occupies — `panelHeader` would clear it by a
        // single point top and bottom, which is the sort of margin that starts clipping the day a
        // font metric moves.
        .frame(
            maxWidth: .infinity,
            minHeight: DSBarHeight.controlRow,
            maxHeight: DSBarHeight.controlRow,
            alignment: .leading
        )
        .background(DSColors.accentSubtle)
        // The same 0.5pt hairline every other band in this window closes with, so the wash ends on a
        // line instead of bleeding into the first row of the list.
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DSColors.separator)
                .frame(height: 0.5)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeys.runControls")
        .accessibilityLabel(accessibilityDescription)
    }

    private var accessibilityDescription: String {
        guard let progress else { return "Running journey \(journeyName)" }
        return "Running journey \(journeyName), \(progress)"
    }
}

// MARK: - Row

/// One journey: whether it is answering, what it is called, how many steps it scripts.
///
/// Selecting a row and activating a journey are deliberately different acts. Selection opens the
/// journey for editing in the centre pane; activation changes what every endpoint returns. A click
/// that did both would mean reading a journey silently rewrote the mocks under whatever you were
/// testing — so activation is the indicator, or the context menu, and nothing else.
struct JourneyNavigatorRow: View {
    let journey: Journey
    let isActive: Bool
    var status: JourneyStatus?
    let onToggleActivation: () -> Void
    let onDuplicate: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DSSpacing.xs) {
            identityRow

            // Only while it is running, and only when there is something to report. A journey that
            // is active but has served nothing does not need a bar of empty segments to say so.
            if isActive, let status, status.totalSteps > 0 {
                HStack(spacing: DSSpacing.sm) {
                    DSProgressSegments(
                        states: status.steps.map(\.isExhausted),
                        identifier: "journeys.progress.\(journey.id.uuidString)"
                    )

                    Text(progressSummary(status))
                        .font(DSTypography.metaSmall)
                        .foregroundStyle(DSColors.labelSecondary)
                        .lineLimit(1)
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, isActive ? DSSpacing.sm : 0)
        .padding(.vertical, isActive ? DSSpacing.xs : 0)
        .background {
            // A card, but only for the one that is answering. An active journey rewrites what every
            // endpoint returns, so it is the rare piece of state that has earned a fill — and it has
            // to be findable in a list without reading every row.
            if isActive {
                RoundedRectangle(cornerRadius: DSCornerRadius.mdPlus)
                    .fill(DSColors.accent.opacity(0.11))
                    .overlay {
                        RoundedRectangle(cornerRadius: DSCornerRadius.mdPlus)
                            .stroke(DSColors.accent.opacity(0.32), lineWidth: 0.5)
                    }
            }
        }
    }

    /// Reads per-step `isExhausted`, never the cursor — see `DSProgressSegments` for why.
    private func progressSummary(_ status: JourneyStatus) -> String {
        let served = status.steps.filter(\.isExhausted).count
        let step = min(served + 1, status.totalSteps)
        return "Step \(step) of \(status.totalSteps) · \(status.totalServed) served"
    }

    private var identityRow: some View {
        HStack(spacing: DSSpacing.sm) {
            JourneyActivationToggle(
                journey: journey,
                isActive: isActive,
                onToggleActivation: onToggleActivation
            )

            // Names stay at full contrast whether or not a journey is running: dimming the rest of
            // the list to mark one row would make the other journeys harder to read for no reason.
            Text(journey.name)
                .font(isActive ? DSTypography.bodyMedium : DSTypography.body)
                .foregroundStyle(DSColors.labelPrimary)
                .lineLimit(1)

            Spacer(minLength: DSSpacing.sm)

            // `labelSecondary`, not `labelTertiary`. This is the only number the list gives you about
            // a journey, and at 36% alpha a column of them read as a smudge down the trailing edge.
            // Monospaced digits so the column does not shuffle as counts change width.
            Text(stepCountText)
                .font(DSTypography.caption)
                .foregroundStyle(DSColors.labelSecondary)
                .monospacedDigit()
        }
        .padding(.vertical, DSSpacing.xs)
        .contentShape(Rectangle())
        .dsHoverHighlight(cornerRadius: DSCornerRadius.mdPlus)
        .contextMenu {
            Button(action: onToggleActivation) {
                Label(
                    isActive ? "Deactivate" : "Activate",
                    systemImage: isActive ? "stop.circle" : "play.circle"
                )
            }

            Button(action: onDuplicate) {
                Label("Duplicate", systemImage: "doc.on.doc")
            }

            Divider()

            // The ellipsis is honest now: `JourneyNavigatorList` presents a confirmation before it
            // calls through. It used to hand `appState.deleteJourney` straight to this button, so a
            // journey and every step in it went in one click, with no undo — while the identical
            // command in the journeys window asked first.
            Button(role: .destructive, action: onDelete) {
                Label("Delete journey\u{2026}", systemImage: "trash")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("journeys.row.\(journey.id.uuidString)")
        .accessibilityLabel(accessibilityDescription)
    }

    private var stepCountText: String {
        "\(journey.steps.count) \(journey.steps.count == 1 ? "step" : "steps")"
    }

    /// Spoken as "Session expiry, 4 steps, active" — the activation state is in the label so a test
    /// can assert that selecting a row did *not* start it.
    private var accessibilityDescription: String {
        "\(journey.name), \(stepCountText), \(isActive ? "active" : "not active")"
    }
}

// MARK: - Activation indicator

/// The dot that says whether a journey is answering, which is also the control that makes it answer.
///
/// The hard part is that it lives inside a selectable row, and selecting is not activating. Two
/// things keep the click unambiguous:
///
/// - **Its own hover well.** Every other icon button in this window lights up under the pointer, so a
///   ring that stayed inert read as a status dot that happened to be clickable — and a click on it
///   looked, before it landed, exactly like a click on the row.
/// - **A 20pt target around a 14pt ring.** Comfortably over the 16pt floor a pointer target needs,
///   and still small enough to sit inside a sidebar row.
///
/// Its own view so the hover state stays local: held on the row, one pointer crossing the list would
/// re-evaluate every row's text as well as its indicator.
private struct JourneyActivationToggle: View {
    let journey: Journey
    let isActive: Bool
    var status: JourneyStatus?
    let onToggleActivation: () -> Void

    @State private var isHovered = false

    private static let ringSize: CGFloat = 14
    private static let targetSize: CGFloat = 20

    var body: some View {
        Button(action: onToggleActivation) {
            Circle()
                .fill(isActive ? DSColors.accent : .clear)
                .stroke(ringColor, lineWidth: 1.5)
                .frame(width: Self.ringSize, height: Self.ringSize)
                .overlay {
                    if isActive {
                        // 8pt, not 7. Below 8 an SF Symbol stops resolving into a shape you can read
                        // and turns into a mark inside the ring that you take for a rendering fault.
                        Image(systemName: "play.fill")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                    }
                }
                .frame(width: Self.targetSize, height: Self.targetSize)
                .background(Circle().fill(isHovered ? DSColors.accentSubtle : .clear))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: DSAnimation.micro), value: isHovered)
        .help(isActive ? "Deactivate this journey" : "Activate this journey")
        .accessibilityIdentifier("journeys.activate.\(journey.id.uuidString)")
        .accessibilityLabel(isActive ? "Deactivate \(journey.name)" : "Activate \(journey.name)")
    }

    /// An idle control is still a control you are meant to find. `labelTertiary` is 36% alpha, which
    /// is where the ring was: on a sidebar surface it read as an artefact rather than as the thing
    /// that starts a journey.
    private var ringColor: Color {
        if isActive { return DSColors.accent }
        return isHovered ? DSColors.labelPrimary : DSColors.labelSecondary
    }
}

#if DEBUG
#Preview("Journeys") {
    @Previewable @State var selectedJourneyID: UUID? = nil

    let retry = Journey(
        name: "Retry after failure",
        steps: [
            JourneyStep(
                name: "Login",
                method: .post,
                path: "/login",
                outcome: .respond(JourneyResponse(statusCode: 200))
            ),
            JourneyStep(
                name: "Fails",
                path: "/account-summary",
                outcome: .respond(JourneyResponse(statusCode: 500))
            ),
            JourneyStep(
                name: "Recovers",
                path: "/account-summary",
                outcome: .respond(JourneyResponse(statusCode: 200))
            )
        ]
    )
    let expiry = Journey(
        name: "Session expiry",
        steps: [
            JourneyStep(name: "Stale token", path: "/me", outcome: .respond(JourneyResponse(statusCode: 401)))
        ]
    )
    let scratch = Journey(name: "Scratch flow")

    JourneyNavigatorList(
        journeys: [retry, expiry, scratch],
        activeJourneyID: retry.id,
        activeProgress: "Step 2 of 3",
        selectedJourneyID: $selectedJourneyID,
        onActivate: { _ in },
        onAdd: {},
        onDuplicate: { _ in },
        onDelete: { _ in },
        onRestart: {},
        onAdvance: {}
    )
    .frame(width: 260, height: 340)
}

#Preview("Journeys — empty") {
    @Previewable @State var selectedJourneyID: UUID? = nil

    JourneyNavigatorList(
        journeys: [],
        activeJourneyID: nil,
        activeProgress: nil,
        selectedJourneyID: $selectedJourneyID,
        onActivate: { _ in },
        onAdd: {},
        onDuplicate: { _ in },
        onDelete: { _ in },
        onRestart: {},
        onAdvance: {}
    )
    .frame(width: 260, height: 340)
}
#endif
