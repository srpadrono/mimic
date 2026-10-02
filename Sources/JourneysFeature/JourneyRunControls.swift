import DesignSystem
import Domain
import SwiftUI

/// Activate, rewind, and step a journey while it is serving.
///
/// These act on the run, not the definition, so they sit to the right of the journey's title. An
/// inactive journey offers Activate in that slot; an active one offers Restart and Next step. The
/// "Active" badge before them is the way out of the run (see ``JourneyActiveBadge``).
struct JourneyRunControls: View {
    let model: any JourneyEditingModel

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?
    /// False draws the symbols alone, for a pane too narrow for the titled row. The titles stay
    /// the buttons' accessibility labels and tooltips.
    var showsTitles = true

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            if isActive {
                DSButton(
                    "Restart",
                    systemImage: "arrow.counterclockwise",
                    variant: .secondary,
                    size: .medium,
                    showsTitle: showsTitles,
                    identifier: "journeyRun.restart"
                ) {
                    model.restartActiveJourney()
                }
                .help(isPrepared
                      ? "Set the next run to start at the first step."
                      : "Rewind the run to the first step.")
                .accessibilityIdentifier("journeyRun.restartButton")
                .accessibilityLabel(isPrepared ? "Restart next journey run" : "Restart journey")

                DSButton(
                    "Next step",
                    systemImage: "forward.end",
                    variant: .secondary,
                    size: .medium,
                    showsTitle: showsTitles,
                    identifier: "journeyRun.advance"
                ) {
                    model.advanceActiveJourney()
                }
                .disabled(status?.isComplete == true)
                .help(isPrepared
                      ? "Set the next run to start at the following step."
                      : "Retire the current step without serving it.")
                .accessibilityIdentifier("journeyRun.advanceButton")
                .accessibilityLabel(isPrepared ? "Advance next journey run" : "Advance journey")
            } else {
                DSButton(
                    "Activate",
                    systemImage: "play.fill",
                    variant: .primary,
                    size: .medium,
                    showsTitle: showsTitles,
                    identifier: "journeyRun.activate"
                ) {
                    model.activateJourney(id: journey.id)
                }
                .disabled(journey.steps.isEmpty)
                .help(journey.steps.isEmpty
                      ? "Add a step before activating this journey."
                      : "Serve this journey's steps instead of the endpoints' own responses.")
                .accessibilityIdentifier("journeyRun.activateButton")
                .accessibilityLabel("Activate journey")
            }
        }
    }

    /// Active, but the server is stopped: the controls set up the next run.
    private var isPrepared: Bool {
        model.serverState.runningPort == nil
    }
}

/// The "Active" badge that ends the run: green "Active" while the server runs, grey "Selected" while
/// the journey waits for the next run. Hovering turns it into "Deactivate" and a click deactivates,
/// so leaving a run stays one click away without a stop button the design does not draw.
struct JourneyActiveBadge: View {
    let isServing: Bool
    let onDeactivate: () -> Void

    @State private var isHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: onDeactivate) {
            // Both wordings share one box, sized to the wider, so hovering never moves the buttons.
            ZStack {
                state.hidden()
                deactivate.hidden()
                if isHovered { deactivate } else { state }
            }
            .padding(.horizontal, 7)
            .frame(height: 18)
            .foregroundStyle(tint)
            .overlay {
                Capsule().strokeBorder(tint, lineWidth: DSStroke.hairline)
            }
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(reduceMotion ? nil : .easeOut(duration: DSAnimation.fast)) { isHovered = hovering }
        }
        .help("Deactivate the journey. Endpoints answer for themselves again.")
        .accessibilityIdentifier("journeyRun.deactivateButton")
        .accessibilityLabel("Deactivate journey")
        .accessibilityValue(title)
    }

    private var title: String { isServing ? "Active" : "Selected" }

    private var tint: Color {
        if isHovered { return DSColors.labelSecondary }
        return isServing ? DSColors.success : DSColors.labelSecondary
    }

    private var state: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(isServing ? DSColors.success : DSColors.labelSecondary)
                .frame(width: 7, height: 7)
            Text(title)
                .font(DSTypography.caption.weight(.medium))
        }
    }

    private var deactivate: some View {
        HStack(spacing: DSSpacing.xs) {
            Image(systemName: "stop.fill")
                .font(.system(size: DSGlyph.minimum, weight: .semibold))
            Text("Deactivate")
                .font(DSTypography.caption.weight(.medium))
        }
    }
}

/// Where the run has got to: one segment per step across the editor, green once served, blue at
/// the current step, grey ahead of it. The words live in the strip's accessibility label and
/// tooltip, so the strip is the whole readout, as the design draws it.
struct JourneyRunProgress: View {
    let model: any JourneyEditingModel

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    var body: some View {
        HStack(spacing: 6) {
            if journey.steps.isEmpty {
                Capsule().fill(DSColors.field).frame(height: 4)
            } else {
                ForEach(journey.steps) { step in
                    Capsule()
                        .fill(segmentColor(for: step))
                        .frame(height: 4)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: DSSpacing.sm)
        .contentShape(Rectangle())
        .help(progressText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(progressText)
        .accessibilityIdentifier("journeyRun.progress")
    }

    private func segmentColor(for step: JourneyStep) -> Color {
        guard isActive, let progress = status?.steps.first(where: { $0.id == step.id }) else {
            return DSColors.field
        }
        if progress.isExhausted { return DSColors.success }
        if progress.isCurrent { return DSColors.accent }
        return DSColors.field
    }

    /// Never vague: this answers "is something overriding my endpoints right now".
    private var progressText: String {
        guard isActive else { return "Not active \u{2014} endpoints answer directly" }
        guard model.serverState.runningPort != nil else {
            guard let status else { return "Ready for next server run" }
            if status.isComplete { return "Next run complete \u{2014} restart to serve" }
            guard let index = status.currentStepIndex else { return "Ready for next server run" }
            return "Next run starts at step \(index + 1) of \(status.totalSteps)"
        }
        guard let status else { return "Not started" }
        if status.isComplete {
            return "Complete \u{2014} \(status.totalServed) served"
        }
        guard let index = status.currentStepIndex else {
            return "\(status.totalServed) served"
        }
        return "Step \(index + 1) of \(status.totalSteps) \u{2014} \(status.totalServed) served"
    }
}

#if DEBUG
#Preview("Run controls — wide") {
    let journey = Journey(
        name: "Retry after failure",
        steps: [
            JourneyStep(name: "Fails", path: "/account", outcome: .respond(JourneyResponse(statusCode: 500))),
            JourneyStep(name: "Recovers", path: "/account", outcome: .respond(JourneyResponse(statusCode: 200)))
        ]
    )
    let status = JourneyStatus.make(journey: journey, state: nil)

    let model = JourneyPreviewModel(journeys: [journey])
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        JourneyRunControls(model: model, journey: journey, isActive: true, status: status)
        JourneyRunProgress(model: model, journey: journey, isActive: true, status: status)
    }
    .padding()
    .frame(width: 640)
}

#Preview("Run controls — 300pt") {
    let model = JourneyPreviewModel()
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        JourneyRunControls(model: model, journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
        JourneyRunProgress(model: model, journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
    }
    .padding()
    .frame(width: 300)
}
#endif
