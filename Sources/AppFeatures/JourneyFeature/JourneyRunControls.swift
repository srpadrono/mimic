import DesignSystem
import Domain
import SwiftUI

/// Activate, rewind, and step a journey while it is serving.
///
/// These act on the run, not the definition, so they sit beside the journey's title. Restart and
/// Next step are always present and disabled until the journey is active.
struct JourneyRunControls: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?
    /// False draws the symbols alone, for a pane too narrow for the titled row. The titles stay
    /// the buttons' accessibility labels and tooltips.
    var showsTitles = true

    var body: some View {
        HStack(spacing: DSSpacing.sm) {
            DSButton(
                "Restart",
                systemImage: "arrow.counterclockwise",
                variant: .secondary,
                size: .medium,
                showsTitle: showsTitles,
                identifier: "journeyRun.restart"
            ) {
                appState.restartActiveJourney()
            }
            .disabled(!isActive)
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
                appState.advanceActiveJourney()
            }
            .disabled(!isActive || status?.isComplete == true)
            .help(isPrepared
                  ? "Set the next run to start at the following step."
                  : "Retire the current step without serving it.")
            .accessibilityIdentifier("journeyRun.advanceButton")
            .accessibilityLabel(isPrepared ? "Advance next journey run" : "Advance journey")

            if isActive {
                // Secondary rather than destructive: this is the everyday way out of a run.
                DSButton(
                    "Deactivate",
                    systemImage: "stop.fill",
                    variant: .secondary,
                    size: .medium,
                    showsTitle: showsTitles,
                    identifier: "journeyRun.deactivate"
                ) {
                    appState.activateJourney(id: nil)
                }
                .help("Stop the journey. Endpoints answer for themselves again.")
                .accessibilityIdentifier("journeyRun.deactivateButton")
                .accessibilityLabel("Deactivate journey")
            } else {
                DSButton(
                    "Activate",
                    systemImage: "play.fill",
                    variant: .primary,
                    size: .medium,
                    showsTitle: showsTitles,
                    identifier: "journeyRun.activate"
                ) {
                    appState.activateJourney(id: journey.id)
                }
                .disabled(journey.steps.isEmpty)
                .help("Serve this journey's steps instead of the endpoints' own responses.")
                .accessibilityIdentifier("journeyRun.activateButton")
                .accessibilityLabel("Activate journey")
            }
        }
    }

    /// Active, but the server is stopped: the controls set up the next run.
    private var isPrepared: Bool {
        appState.serverState.runningPort == nil
    }
}

/// Where the run has got to: one segment per step, then a short readout.
struct JourneyRunProgress: View {
    @Environment(AppState.self) private var appState

    let journey: Journey
    let isActive: Bool
    let status: JourneyStatus?

    var body: some View {
        HStack(spacing: DSSpacing.md) {
            if !journey.steps.isEmpty {
                segments
                    .frame(minWidth: 40, maxWidth: .infinity)
            }
            ViewThatFits(in: .horizontal) {
                readout(progressText)
                readout(compactProgressText)
            }
            .layoutPriority(1)
            .frame(maxWidth: journey.steps.isEmpty ? .infinity : nil, alignment: .leading)
        }
    }

    private var segments: some View {
        HStack(spacing: 6) {
            ForEach(journey.steps) { step in
                Capsule()
                    .fill(segmentColor(for: step))
                    .frame(height: 4)
            }
        }
        .accessibilityHidden(true)
    }

    private func segmentColor(for step: JourneyStep) -> Color {
        guard isActive, let progress = status?.steps.first(where: { $0.id == step.id }) else {
            return DSColors.field
        }
        if progress.isExhausted { return DSColors.success }
        if progress.isCurrent { return DSColors.accent }
        return DSColors.field
    }

    private func readout(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.callout)
            .monospacedDigit()
            // Never tertiary: this answers "is something overriding my endpoints right now".
            .foregroundStyle(isActive ? DSColors.labelPrimary : DSColors.labelSecondary)
            .lineLimit(1)
            .help(progressText)
            .accessibilityLabel(progressText)
            .accessibilityIdentifier("journeyRun.progress")
    }

    private var progressText: String {
        guard isActive else { return "Not active — endpoints answer directly" }
        guard appState.serverState.runningPort != nil else {
            guard let status else { return "Ready for next server run" }
            if status.isComplete { return "Next run complete — restart to serve" }
            guard let index = status.currentStepIndex else { return "Ready for next server run" }
            return "Next run starts at step \(index + 1) of \(status.totalSteps)"
        }
        guard let status else { return "Not started" }
        if status.isComplete {
            return "Complete — \(status.totalServed) served"
        }
        guard let index = status.currentStepIndex else {
            return "\(status.totalServed) served"
        }
        return "Step \(index + 1) of \(status.totalSteps) — \(status.totalServed) served"
    }

    private var compactProgressText: String {
        guard isActive else { return "Inactive" }
        guard appState.serverState.runningPort != nil else {
            guard let status else { return "Next run ready" }
            if status.isComplete { return "Restart to serve" }
            guard let index = status.currentStepIndex else { return "Next run ready" }
            return "Next run: \(index + 1)/\(status.totalSteps)"
        }
        guard let status else { return "Not started" }
        if status.isComplete { return "Complete" }
        guard let index = status.currentStepIndex else { return "\(status.totalServed) served" }
        return "Step \(index + 1) of \(status.totalSteps)"
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

    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        JourneyRunControls(journey: journey, isActive: true, status: status)
        JourneyRunProgress(journey: journey, isActive: true, status: status)
    }
    .environment(AppState.preview())
    .padding()
    .frame(width: 640)
}

#Preview("Run controls — 300pt") {
    VStack(alignment: .leading, spacing: DSSpacing.lg) {
        JourneyRunControls(journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
        JourneyRunProgress(journey: Journey(name: "Scratch flow"), isActive: false, status: nil)
    }
    .environment(AppState.preview())
    .padding()
    .frame(width: 300)
}
#endif
