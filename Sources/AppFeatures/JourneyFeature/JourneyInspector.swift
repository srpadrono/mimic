import DesignSystem
import Domain
import SwiftUI

/// Context for the selected journey's run; editing controls stay with the script in the centre pane.
struct JourneyInspector: View {
    struct Context {
        let selected: Journey
        let active: Journey?
        let progress: String?
        let serverState: ServerState
    }

    let context: Context

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: DSSpacing.xs) {
                    Text("\(context.selected.steps.count) \(context.selected.steps.count == 1 ? "step" : "steps")")
                        .font(DSTypography.heading)
                        .foregroundStyle(DSColors.labelPrimary)
                        .accessibilityIdentifier("inspector.journey.steps")
                    Text(context.selected.groupTag.map { "In \($0)" } ?? "Ungrouped journey")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.labelSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSInspectorMetrics.inset)

                DSInspectorSectionHeader("Run", identifier: "journey.run")
                VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
                    Text(runState)
                        .font(DSTypography.bodyMedium)
                        .foregroundStyle(context.selected.id == context.active?.id
                                         ? DSColors.accentText : DSColors.labelPrimary)
                        .accessibilityIdentifier("inspector.journey.state")
                    if let active = context.active {
                        if active.id != context.selected.id {
                            Text("Active journey: \(active.name)")
                                .font(DSTypography.label)
                                .foregroundStyle(DSColors.labelSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("inspector.journey.activeName")
                        }
                        if let progress = context.progress {
                            Text(progress)
                                .font(DSTypography.label)
                                .foregroundStyle(DSColors.labelPrimary)
                                .accessibilityIdentifier("inspector.journey.progress")
                        }
                    } else {
                        Text("No journey active. Endpoints answer directly.")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("inspector.journey.noActiveRun")
                    }
                    Text("Server: \(serverStatus)")
                        .font(DSTypography.label)
                        .foregroundStyle(DSColors.labelSecondary)
                        .accessibilityIdentifier("inspector.journey.server")
                    if context.selected.id == context.active?.id,
                       context.serverState.runningPort == nil {
                        Text("Restart and Advance set the step for the next server run.")
                            .font(DSTypography.label)
                            .foregroundStyle(DSColors.labelSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSInspectorMetrics.inset)

                DSInspectorSectionHeader("Matching", identifier: "journey.matching")
                VStack(alignment: .leading, spacing: DSSpacing.smPlus) {
                    Text(matchExplanation)
                    Text(context.selected.unmatchedBehavior == .fallThroughToEndpoints
                         ? "Other requests use endpoint mocks."
                         : "Other requests return 404.")
                }
                .font(DSTypography.label)
                .foregroundStyle(DSColors.labelSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(DSInspectorMetrics.inset)
            }
            .padding(.bottom, DSSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(context.selected.name)")
        .accessibilityIdentifier("inspector.journey")
    }

    private var runState: String {
        guard context.selected.id == context.active?.id else { return "Inactive journey" }
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
        case .starting: "Starting…"
        case .running: "Running"
        case .stopping: "Stopping…"
        case .error: "Error"
        }
    }
}
