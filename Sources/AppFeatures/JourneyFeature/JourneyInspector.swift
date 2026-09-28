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
                DSInspectorSectionHeader("Journey", identifier: "journey.summary")
                DSInspectorValueRow("Steps", value: "\(context.selected.steps.count)",
                                    identifier: "inspector.journey.steps")
                DSInspectorValueRow("Group", value: context.selected.groupTag ?? "Ungrouped",
                                    color: context.selected.groupTag == nil ? DSColors.labelSecondary : DSColors.labelPrimary,
                                    identifier: "inspector.journey.group")

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
                    note("No journey active. Endpoints answer directly.")
                        .accessibilityIdentifier("inspector.journey.noActiveRun")
                } else if isSelectedActive, context.serverState.runningPort == nil {
                    note("Restart and Next step set the step for the next server run.")
                }

                DSInspectorSectionHeader("Matching", identifier: "journey.matching")
                DSInspectorValueRow("Order", value: matchTitle, identifier: "inspector.journey.matchMode")
                DSInspectorValueRow("Unscripted", value: unmatchedTitle, identifier: "inspector.journey.unmatched")
                note(matchExplanation)
            }
            .padding(.bottom, DSSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Inspector for \(context.selected.name)")
        .accessibilityIdentifier("inspector.journey")
    }

    /// Explanatory text, aligned with the value column.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(DSTypography.caption)
            .foregroundStyle(DSColors.labelTertiary)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, DSInspectorMetrics.inset + DSInspectorMetrics.labelColumn + DSSpacing.md)
            .padding(.trailing, DSInspectorMetrics.inset)
            .padding(.top, DSSpacing.xs)
    }

    private var isSelectedActive: Bool { context.selected.id == context.active?.id }

    private var runState: String {
        guard isSelectedActive else { return "Inactive journey" }
        return context.serverState.runningPort == nil ? "Prepared for next server run" : "Active journey"
    }

    private var matchTitle: String {
        switch context.selected.matchMode {
        case .orderedPerEndpoint: "Ordered per route"
        case .strictSequence: "Strict sequence"
        }
    }

    private var unmatchedTitle: String {
        context.selected.unmatchedBehavior == .fallThroughToEndpoints ? "Use endpoints" : "404"
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

    private var serverColor: Color {
        switch context.serverState {
        case .running: DSColors.success
        case .error: DSColors.error
        default: DSColors.labelSecondary
        }
    }
}
