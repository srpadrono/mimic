import DesignSystem
import Domain
import SwiftUI

/// Selection describes the journey being edited; the live run may belong to another journey.
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
                    Text(context.selected.name)
                        .font(DSTypography.controlLabel)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("inspector.journey.name")
                    Text(context.selected.id == context.active?.id ? "Active journey" : "Inactive journey")
                        .font(DSTypography.label)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("inspector.journey.state")
                    if let summary = context.selected.summary, !summary.isEmpty {
                        Text(summary)
                            .font(DSTypography.label)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(DSInspectorMetrics.inset)

                DSInspectorSectionHeader("Configuration", identifier: "journey.configuration")
                row("Group", context.selected.groupTag ?? "None", id: "group")
                row("Steps", "\(context.selected.steps.count)", id: "steps")
                row("Match", context.selected.matchMode == .orderedPerEndpoint ? "Ordered per route" : "Strict sequence", id: "match")
                row("Completion", context.selected.completion == .stop ? "Stop" : "Restart", id: "completion")
                row("Unscripted", context.selected.unmatchedBehavior == .fallThroughToEndpoints ? "Fall through" : "404", id: "unmatched")
                row("Auto-advance", context.selected.autoAdvance ? "On" : "Off", id: "autoAdvance")

                DSInspectorSectionHeader("Active journey", identifier: "journey.active")
                if let active = context.active {
                    row("Name", active.name, id: "activeName")
                    if let progress = context.progress { row("Progress", progress, id: "progress") }
                } else {
                    Text("None — endpoints answer directly.")
                        .font(DSTypography.label)
                        .foregroundStyle(.secondary)
                        .padding(DSInspectorMetrics.inset)
                        .accessibilityIdentifier("inspector.journey.noActiveRun")
                }
                row("Server", serverStatus, id: "server")
            }
            .padding(.bottom, DSSpacing.md)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("inspector.journey")
    }

    private func row(_ label: String, _ value: String, id: String) -> some View {
        DSInspectorValueRow(label, value: value, identifier: "inspector.journey.\(id)")
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
